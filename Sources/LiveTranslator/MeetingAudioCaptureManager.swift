import AVFoundation
import CoreMedia
import Foundation
import Speech
@preconcurrency import ScreenCaptureKit

/// Captures both sides of a meeting: the selected microphone and audio played by macOS.
/// ScreenCaptureKit supplies the two sources independently, so AVAudioEngine mixes them
/// before the combined signal is saved and handed to SpeechAnalyzer.
final class MeetingAudioCaptureManager: NSObject, @unchecked Sendable {
    private static let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    private let audioQueue = DispatchQueue(
        label: "com.minorun365.LiveDictation.meeting-audio",
        qos: .userInitiated
    )
    private let audioEngine = AVAudioEngine()
    private let microphonePlayer = AVAudioPlayerNode()
    private let systemAudioPlayer = AVAudioPlayerNode()
    private let captureMixer = AVAudioMixerNode()
    private let analyzerBridge = MixedAudioAnalyzerBridge()

    private let stateLock = NSLock()
    private var stream: SCStream?
    private var microphoneConverter: AVAudioConverter?
    private var microphoneSourceFormat: AVAudioFormat?
    private var systemConverter: AVAudioConverter?
    private var systemSourceFormat: AVAudioFormat?
    private var runtimeFailureHandler: (@MainActor @Sendable (String) -> Void)?
    private var sourceReadyHandler: (@MainActor @Sendable (String) -> Void)?
    private var reportedMicrophoneReady = false
    private var reportedSystemAudioReady = false
    private var graphIsConfigured = false

    var inputFormat: AVAudioFormat { Self.captureFormat }

    func start(
        audioURL: URL,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        onSourceReady: @escaping @MainActor @Sendable (String) -> Void,
        onRuntimeFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        await stop()
        sourceReadyHandler = onSourceReady
        runtimeFailureHandler = onRuntimeFailure

        let audioFile = try AVAudioFile(
            forWriting: audioURL,
            settings: Self.captureFormat.settings
        )
        analyzerBridge.configure(
            audioFile: audioFile,
            continuation: continuation,
            sourceFormat: Self.captureFormat,
            analyzerFormat: analyzerFormat
        )

        audioEngine.attach(microphonePlayer)
        audioEngine.attach(systemAudioPlayer)
        audioEngine.attach(captureMixer)
        audioEngine.connect(microphonePlayer, to: captureMixer, format: Self.captureFormat)
        audioEngine.connect(systemAudioPlayer, to: captureMixer, format: Self.captureFormat)
        audioEngine.connect(captureMixer, to: audioEngine.mainMixerNode, format: Self.captureFormat)
        graphIsConfigured = true

        // The mixer output is consumed by the tap only. Muting the main mixer prevents
        // captured meeting audio from being played back and causing feedback.
        audioEngine.mainMixerNode.outputVolume = 0
        analyzerBridge.installTap(on: captureMixer, format: Self.captureFormat)
        audioEngine.prepare()
        try audioEngine.start()
        microphonePlayer.play()
        systemAudioPlayer.play()

        do {
            let content = try await SCShareableContent.current
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
                throw MeetingAudioCaptureError.mainDisplayUnavailable
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 3
            configuration.capturesAudio = true
            configuration.sampleRate = Int(Self.captureFormat.sampleRate)
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            self.stream = stream
            try await stream.startCapture()
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        audioQueue.sync {
            microphonePlayer.stop()
            systemAudioPlayer.stop()
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            if graphIsConfigured {
                captureMixer.removeTap(onBus: 0)
                audioEngine.disconnectNodeOutput(microphonePlayer)
                audioEngine.disconnectNodeOutput(systemAudioPlayer)
                audioEngine.disconnectNodeOutput(captureMixer)
                audioEngine.detach(microphonePlayer)
                audioEngine.detach(systemAudioPlayer)
                audioEngine.detach(captureMixer)
                graphIsConfigured = false
            }
            analyzerBridge.clear()
            stateLock.withLock {
                microphoneConverter = nil
                microphoneSourceFormat = nil
                systemConverter = nil
                systemSourceFormat = nil
            }
        }
        runtimeFailureHandler = nil
        sourceReadyHandler = nil
        reportedMicrophoneReady = false
        reportedSystemAudioReady = false
    }

    private func consume(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let converted = pcmBuffer(from: sampleBuffer, type: type) else {
            return
        }

        switch type {
        case .microphone:
            microphonePlayer.scheduleBuffer(converted)
            reportSourceReadyIfNeeded(type: type)
        case .audio:
            systemAudioPlayer.scheduleBuffer(converted)
            reportSourceReadyIfNeeded(type: type)
        default:
            break
        }
    }

    private func reportSourceReadyIfNeeded(type: SCStreamOutputType) {
        let source: String?
        switch type {
        case .microphone where !reportedMicrophoneReady:
            reportedMicrophoneReady = true
            source = "microphone"
        case .audio where !reportedSystemAudioReady:
            reportedSystemAudioReady = true
            source = "system_audio"
        default:
            source = nil
        }
        guard let source, let sourceReadyHandler else { return }
        Task { @MainActor in
            sourceReadyHandler(source)
        }
    }

    private func pcmBuffer(
        from sampleBuffer: CMSampleBuffer,
        type: SCStreamOutputType
    ) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription
              ),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        var requiredSize = 0
        var blockBuffer: CMBlockBuffer?
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard sizeStatus == noErr, requiredSize > 0 else { return nil }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let audioBufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
        let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard listStatus == noErr,
              let borrowedBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: audioBufferList,
                deallocator: nil
              ) else {
            return nil
        }
        borrowedBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        return copyAndConvert(borrowedBuffer, type: type, to: Self.captureFormat)
    }

    private func copyAndConvert(
        _ input: AVAudioPCMBuffer,
        type: SCStreamOutputType,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let converter: AVAudioConverter? = stateLock.withLock {
            if type == .microphone {
                if input.format == microphoneSourceFormat, let microphoneConverter {
                    return microphoneConverter
                }
                let converter = AVAudioConverter(from: input.format, to: outputFormat)
                microphoneSourceFormat = input.format
                microphoneConverter = converter
                return converter
            }

            if input.format == systemSourceFormat, let systemConverter {
                return systemConverter
            }
            let converter = AVAudioConverter(from: input.format, to: outputFormat)
            if type == .audio {
                systemSourceFormat = input.format
                systemConverter = converter
            }
            return converter
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        let inputProvider = MeetingAudioConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}

extension MeetingAudioCaptureManager: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio || type == .microphone else { return }
        consume(sampleBuffer, type: type)
    }
}

extension MeetingAudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard let runtimeFailureHandler else { return }
        Task { @MainActor in
            runtimeFailureHandler(error.localizedDescription)
        }
    }
}

private final class MixedAudioAnalyzerBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var audioFile: AVAudioFile?

    func configure(
        audioFile: AVAudioFile,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat
    ) {
        lock.withLock {
            self.audioFile = audioFile
            self.continuation = continuation
            self.analyzerFormat = analyzerFormat
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        }
    }

    func installTap(on node: AVAudioNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 2_048, format: format) { [self] buffer, _ in
            consume(buffer)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            try? audioFile?.write(from: buffer)
            guard let continuation, let converter, let analyzerFormat else { return }
            guard let converted = convert(buffer, using: converter, to: analyzerFormat) else {
                return
            }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        let inputProvider = MeetingAudioConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        return output
    }

    func clear() {
        lock.withLock {
            continuation = nil
            converter = nil
            analyzerFormat = nil
            audioFile = nil
        }
    }
}

private final class MeetingAudioConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private var supplied = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        if supplied {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return input
    }
}

private enum MeetingAudioCaptureError: LocalizedError {
    case mainDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .mainDisplayUnavailable:
            "メイン画面に紐づくシステム音声を取得できません。"
        }
    }
}
