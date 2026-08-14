import AVFoundation
import CoreMedia
import Foundation
import Speech
@preconcurrency import ScreenCaptureKit

/// Captures both sides of a meeting: the selected microphone and audio played by macOS.
/// ScreenCaptureKit supplies the two sources independently. Japanese mode keeps them apart
/// all the way to two recognizers so every phrase carries a speaker, while English mode
/// mixes them into a single signal before recognition.
/// When the sources stay separate they are also recorded separately, which keeps a session
/// re-analyzable per speaker afterwards.
final class MeetingAudioCaptureManager: NSObject, @unchecked Sendable {
    /// One captured signal: where its audio is recognized, and where it is recorded.
    struct Destination {
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let audioURL: URL
    }

    enum Routing {
        case separated(microphone: Destination, systemAudio: Destination)
        case mixed(Destination)
    }

    private static let monoFormat = AVAudioFormat(
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
    private let microphoneMixer = AVAudioMixerNode()
    private let systemAudioMixer = AVAudioMixerNode()
    private let recordingMixer = AVAudioMixerNode()

    private let microphoneFeed = AnalyzerFeed()
    private let systemAudioFeed = AnalyzerFeed()
    private let mixedFeed = AnalyzerFeed()
    private let microphoneSink = RecordingSink()
    private let systemAudioSink = RecordingSink()
    private let mixedSink = RecordingSink()

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
    private var attachedNodes: [AVAudioNode] = []
    private var tappedNodes: [AVAudioNode] = []

    var inputFormat: AVAudioFormat { Self.monoFormat }

    func start(
        analyzerFormat: AVAudioFormat,
        routing: Routing,
        onSourceReady: @escaping @MainActor @Sendable (String) -> Void,
        onRuntimeFailure: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        await stop()
        sourceReadyHandler = onSourceReady
        runtimeFailureHandler = onRuntimeFailure

        do {
            try buildGraph(analyzerFormat: analyzerFormat, routing: routing)
            try await startCapture()
        } catch {
            await stop()
            throw error
        }
    }

    /// Wires the engine for the requested routing, then starts it.
    ///
    /// Each signal is recorded from the same tap that feeds its recognizer, so what is
    /// written to disk is exactly what was recognized. Writing both sides into one stereo
    /// file was tried first, but `pan` on an intermediate mixer only takes effect at the
    /// engine's final mixer, so a tap placed before it still receives the unpanned signal.
    private func buildGraph(analyzerFormat: AVAudioFormat, routing: Routing) throws {
        attach(microphonePlayer)
        attach(systemAudioPlayer)
        attach(recordingMixer)

        switch routing {
        case .separated(let microphone, let systemAudio):
            attach(microphoneMixer)
            attach(systemAudioMixer)

            audioEngine.connect(microphonePlayer, to: microphoneMixer, format: Self.monoFormat)
            audioEngine.connect(systemAudioPlayer, to: systemAudioMixer, format: Self.monoFormat)
            audioEngine.connect(microphoneMixer, to: recordingMixer, format: Self.monoFormat)
            audioEngine.connect(systemAudioMixer, to: recordingMixer, format: Self.monoFormat)
            audioEngine.connect(
                recordingMixer,
                to: audioEngine.mainMixerNode,
                format: Self.monoFormat
            )

            configure(
                feed: microphoneFeed,
                node: microphoneMixer,
                continuation: microphone.continuation,
                analyzerFormat: analyzerFormat
            )
            configure(
                feed: systemAudioFeed,
                node: systemAudioMixer,
                continuation: systemAudio.continuation,
                analyzerFormat: analyzerFormat
            )
            try configure(
                sink: microphoneSink,
                node: microphoneMixer,
                audioURL: microphone.audioURL
            )
            try configure(
                sink: systemAudioSink,
                node: systemAudioMixer,
                audioURL: systemAudio.audioURL
            )

            installTap(on: microphoneMixer, feed: microphoneFeed, sink: microphoneSink)
            installTap(on: systemAudioMixer, feed: systemAudioFeed, sink: systemAudioSink)

        case .mixed(let destination):
            audioEngine.connect(microphonePlayer, to: recordingMixer, format: Self.monoFormat)
            audioEngine.connect(systemAudioPlayer, to: recordingMixer, format: Self.monoFormat)
            audioEngine.connect(
                recordingMixer,
                to: audioEngine.mainMixerNode,
                format: Self.monoFormat
            )

            configure(
                feed: mixedFeed,
                node: recordingMixer,
                continuation: destination.continuation,
                analyzerFormat: analyzerFormat
            )
            try configure(sink: mixedSink, node: recordingMixer, audioURL: destination.audioURL)

            installTap(on: recordingMixer, feed: mixedFeed, sink: mixedSink)
        }

        // The taps are the only consumers. Muting the main mixer prevents captured
        // meeting audio from being played back and causing feedback.
        audioEngine.mainMixerNode.outputVolume = 0
        audioEngine.prepare()
        try audioEngine.start()
        microphonePlayer.play()
        systemAudioPlayer.play()
    }

    private func startCapture() async throws {
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
        configuration.sampleRate = Int(Self.monoFormat.sampleRate)
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    private func attach(_ node: AVAudioNode) {
        audioEngine.attach(node)
        attachedNodes.append(node)
    }

    /// Formats are read back from the node after connecting, because a mixer settles its
    /// output format when it is connected; assuming one here would desync the tap,
    /// the converter and the recording file.
    private func configure(
        feed: AnalyzerFeed,
        node: AVAudioNode,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat
    ) {
        feed.configure(
            continuation: continuation,
            sourceFormat: node.outputFormat(forBus: 0),
            analyzerFormat: analyzerFormat
        )
    }

    private func configure(sink: RecordingSink, node: AVAudioNode, audioURL: URL) throws {
        let format = node.outputFormat(forBus: 0)
        sink.configure(audioFile: try AVAudioFile(forWriting: audioURL, settings: format.settings))
    }

    /// A node carries at most one tap, so recording and recognition share one callback.
    private func installTap(on node: AVAudioNode, feed: AnalyzerFeed?, sink: RecordingSink?) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            sink?.write(buffer)
            feed?.send(buffer)
        }
        tappedNodes.append(node)
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
            for node in tappedNodes {
                node.removeTap(onBus: 0)
            }
            tappedNodes.removeAll()
            for node in attachedNodes {
                audioEngine.disconnectNodeOutput(node)
            }
            for node in attachedNodes {
                audioEngine.detach(node)
            }
            attachedNodes.removeAll()
            microphoneFeed.clear()
            systemAudioFeed.clear()
            mixedFeed.clear()
            microphoneSink.clear()
            systemAudioSink.clear()
            mixedSink.clear()
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
        return copyAndConvert(borrowedBuffer, type: type, to: Self.monoFormat)
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
        return MeetingAudioConverterInputProvider.convert(
            input,
            using: converter,
            to: outputFormat
        )
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

/// Feeds one captured signal into one recognizer.
private final class AnalyzerFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    func configure(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat
    ) {
        lock.withLock {
            self.continuation = continuation
            self.analyzerFormat = analyzerFormat
            converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        }
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let continuation, let converter, let analyzerFormat else { return }
            guard let converted = MeetingAudioConverterInputProvider.convert(
                buffer,
                using: converter,
                to: analyzerFormat
            ) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    func clear() {
        lock.withLock {
            continuation = nil
            converter = nil
            analyzerFormat = nil
        }
    }
}

/// Writes one captured signal to disk.
private final class RecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?

    func configure(audioFile: AVAudioFile) {
        lock.withLock { self.audioFile = audioFile }
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            try? audioFile?.write(from: buffer)
        }
    }

    func clear() {
        lock.withLock { audioFile = nil }
    }
}

private final class MeetingAudioConverterInputProvider: @unchecked Sendable {
    private let input: AVAudioPCMBuffer
    private var supplied = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    static func convert(
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
