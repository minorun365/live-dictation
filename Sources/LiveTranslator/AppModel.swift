import AVFoundation
import AppKit
import Combine
import Speech
@preconcurrency import Translation

@MainActor
@available(macOS 26.4, *)
final class AppModel: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var englishText = ""
    @Published private(set) var japaneseText = ""
    @Published private(set) var statusMessage = "録音を開始すると、英語を日本語へ翻訳します"
    @Published private(set) var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    private var finalizedEnglish = ""
    private var volatileEnglish = ""
    private var finalizedJapanese = ""
    private var volatileJapanese = ""
    private var volatileRevision = UUID()

    private var sessionFinalizedEnglish = ""
    private var sessionFinalizedJapanese = ""
    private var currentSessionID = UUID()
    private var pendingFinalTranslations: [TranslationWork] = []

    private var logger: SessionLogger?
    private var audioFile: AVAudioFile?
    private let captureBridge = AnalyzerCaptureBridge()

    private let translationStream: AsyncStream<TranslationWork>
    private let translationContinuation: AsyncStream<TranslationWork>.Continuation

    override init() {
        var continuation: AsyncStream<TranslationWork>.Continuation!
        translationStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        translationContinuation = continuation
        super.init()
    }

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    func runTranslationLoop(with session: TranslationSession) async {
        do {
            statusMessage = "翻訳モデルを準備しています…"
            try await session.prepareTranslation()
            if !isRecording {
                statusMessage = "録音を開始すると、英語を日本語へ翻訳します"
            }

            for await work in translationStream {
                guard !Task.isCancelled else { return }

                while !pendingFinalTranslations.isEmpty {
                    let finalWork = pendingFinalTranslations.removeFirst()
                    let response = try await session.translate(finalWork.sourceText)
                    guard !Task.isCancelled else { return }

                    finalizedJapanese = joinJapanese(finalizedJapanese, response.targetText)
                    japaneseText = joinJapanese(finalizedJapanese, volatileJapanese)

                    if finalWork.sessionID == currentSessionID {
                        sessionFinalizedJapanese = joinJapanese(
                            sessionFinalizedJapanese,
                            response.targetText
                        )
                        updateSavedTranscript()
                        logger?.appendTranslation(
                            source: finalWork.sourceText,
                            target: response.targetText
                        )
                    }
                }

                guard !work.isFinal else { continue }
                try await Task.sleep(for: .milliseconds(220))
                guard work.revision == volatileRevision else { continue }
                guard work.sourceText == volatileEnglish else { continue }

                let response = try await session.translate(work.sourceText)
                guard !Task.isCancelled else { return }
                guard work.revision == volatileRevision else { continue }
                guard work.sourceText == volatileEnglish else { continue }

                volatileJapanese = response.targetText
                japaneseText = joinJapanese(finalizedJapanese, volatileJapanese)
                updateSavedTranscript()
                logger?.appendTranslation(source: work.sourceText, target: response.targetText)

                if isRecording {
                    statusMessage = "録音・翻訳中"
                }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "翻訳を開始できません: \(error.localizedDescription)"
            statusMessage = isRecording ? "録音中（翻訳エラー）" : "翻訳を利用できません"
        }
    }

    func openSessionsFolder() {
        do {
            let url = try SessionLogger.sessionsRootURL()
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            errorMessage = "保存先を開けません: \(error.localizedDescription)"
        }
    }

    func stopRecordingIfNeeded() {
        Task { @MainActor [weak self] in
            await self?.stopRecording()
        }
    }

    #if DEBUG
    func loadPreviewTranscript(english: String, japanese: String) {
        finalizedEnglish = english
        finalizedJapanese = japanese
        englishText = english
        japaneseText = japanese
    }
    #endif

    private func startRecording() async {
        errorMessage = nil

        guard await requestMicrophonePermission() else { return }
        guard SpeechTranscriber.isAvailable else {
            errorMessage = "このMacでAppleの長時間音声認識を利用できません。"
            return
        }

        do {
            statusMessage = "英語の音声認識を準備中…"

            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "en-US")
            ) else {
                throw AppError.englishUnsupported
            }

            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [.audioTimeRange]
            )
            let modules: [any SpeechModule] = [transcriber]

            let installedLocales = await SpeechTranscriber.installedLocales
            let modelIsInstalled = installedLocales.contains {
                $0.language.languageCode == locale.language.languageCode
            }
            if !modelIsInstalled,
               await AssetInventory.status(forModules: modules) != .installed {
                statusMessage = "英語の音声認識モデルを取得中…"
                guard let request = try await AssetInventory.assetInstallationRequest(
                    supporting: modules
                ) else {
                    throw AppError.modelUnavailable
                }
                try await request.downloadAndInstall()
            }

            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .processLifetime)
            )

            let inputNode = audioEngine.inputNode
            let sourceFormat = inputNode.outputFormat(forBus: 0)
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
                throw AppError.microphoneUnavailable
            }
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: sourceFormat
            ) else {
                throw AppError.audioFormatUnavailable
            }

            try await analyzer.prepareToAnalyze(in: analyzerFormat)

            var continuation: AsyncStream<AnalyzerInput>.Continuation!
            let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(64)) {
                continuation = $0
            }

            currentSessionID = UUID()
            sessionFinalizedEnglish = ""
            sessionFinalizedJapanese = ""
            volatileEnglish = ""
            volatileJapanese = ""
            englishText = finalizedEnglish
            japaneseText = finalizedJapanese

            let logger = try SessionLogger()
            self.logger = logger
            let audioFile = try AVAudioFile(
                forWriting: logger.audioURL,
                settings: sourceFormat.settings
            )
            self.audioFile = audioFile

            captureBridge.configure(
                audioFile: audioFile,
                continuation: continuation,
                sourceFormat: sourceFormat,
                analyzerFormat: analyzerFormat
            )
            inputNode.removeTap(onBus: 0)
            captureBridge.installTap(on: inputNode, format: sourceFormat)

            self.transcriber = transcriber
            self.analyzer = analyzer
            inputContinuation = continuation
            startResultTask(for: transcriber)
            startAnalyzerTask(analyzer: analyzer, inputStream: inputStream)

            isRecording = true
            statusMessage = "録音・翻訳中"
            logger.appendEvent(
                type: "session_started",
                payload: ["recognizer": "apple-speech-analyzer"]
            )

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            await cleanUpAudio()
            isRecording = false
            statusMessage = "録音を開始できません"
            errorMessage = "録音を開始できません: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        guard isRecording else { return }

        isRecording = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        captureBridge.clear()

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            logger?.appendEvent(
                type: "recognizer_finalize_error",
                payload: ["message": error.localizedDescription]
            )
        }

        _ = await resultsTask?.result
        analyzerTask?.cancel()
        resultsTask?.cancel()

        if !volatileEnglish.isEmpty {
            commitFinalEnglish(volatileEnglish)
            volatileEnglish = ""
            volatileJapanese = ""
        }

        englishText = finalizedEnglish
        japaneseText = finalizedJapanese
        updateSavedTranscript()
        logger?.appendEvent(type: "session_stopped", payload: [:])
        logger?.close()

        analyzer = nil
        transcriber = nil
        analyzerTask = nil
        resultsTask = nil
        inputContinuation = nil
        audioFile = nil
        logger = nil
        statusMessage = "停止しました。ログはMac内に保存済みです"
    }

    private func startResultTask(for transcriber: SpeechTranscriber) {
        resultsTask?.cancel()
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.handleTranscription(text: text, isFinal: result.isFinal)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.handleRecognitionFailure(error)
            }
        }
    }

    private func startAnalyzerTask(
        analyzer: SpeechAnalyzer,
        inputStream: AsyncStream<AnalyzerInput>
    ) {
        analyzerTask?.cancel()
        analyzerTask = Task { @MainActor [weak self] in
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch is CancellationError {
                return
            } catch {
                self?.handleRecognitionFailure(error)
            }
        }
    }

    private func handleTranscription(text: String, isFinal: Bool) {
        guard analyzer != nil, !text.isEmpty else { return }

        if isFinal {
            volatileEnglish = ""
            volatileJapanese = ""
            commitFinalEnglish(text)
            enqueueTranslation(sourceText: text, isFinal: true)
        } else {
            volatileEnglish = text
            volatileJapanese = ""
            volatileRevision = UUID()
            englishText = joinEnglish(finalizedEnglish, volatileEnglish)
            japaneseText = finalizedJapanese
            enqueueTranslation(sourceText: text, isFinal: false)
        }

        logger?.appendRecognition(text: sessionEnglishText(), isFinal: isFinal)
        updateSavedTranscript()
    }

    private func handleRecognitionFailure(_ error: any Error) {
        logger?.appendEvent(
            type: "recognizer_error",
            payload: ["message": error.localizedDescription]
        )
        errorMessage = "音声認識エラー: \(error.localizedDescription)"
        statusMessage = "録音中（音声認識エラー）"
    }

    private func commitFinalEnglish(_ text: String) {
        finalizedEnglish = joinEnglish(finalizedEnglish, text)
        sessionFinalizedEnglish = joinEnglish(sessionFinalizedEnglish, text)
        englishText = joinEnglish(finalizedEnglish, volatileEnglish)
    }

    private func enqueueTranslation(sourceText: String, isFinal: Bool) {
        let work = TranslationWork(
            revision: volatileRevision,
            sessionID: currentSessionID,
            sourceText: sourceText,
            isFinal: isFinal
        )
        if isFinal {
            pendingFinalTranslations.append(work)
        }
        translationContinuation.yield(work)
    }

    private func requestMicrophonePermission() async -> Bool {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            allowed = true
        case .notDetermined:
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            allowed = false
        }

        guard allowed else {
            errorMessage = "マイクの許可が必要です。システム設定の「プライバシーとセキュリティ」で許可してください。"
            return false
        }
        return true
    }

    private func cleanUpAudio() async {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        captureBridge.clear()
        analyzerTask?.cancel()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        analyzerTask = nil
        resultsTask = nil
        inputContinuation = nil
        audioFile = nil
        logger?.close()
        logger = nil
    }

    private func joinEnglish(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    private func joinJapanese(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + second
    }

    private func sessionEnglishText() -> String {
        joinEnglish(sessionFinalizedEnglish, volatileEnglish)
    }

    private func sessionJapaneseText() -> String {
        joinJapanese(sessionFinalizedJapanese, volatileJapanese)
    }

    private func updateSavedTranscript() {
        logger?.updateTranscript(
            english: sessionEnglishText(),
            japanese: sessionJapaneseText()
        )
    }
}

private struct TranslationWork: Sendable {
    let revision: UUID
    let sessionID: UUID
    let sourceText: String
    let isFinal: Bool
}

private final class AnalyzerCaptureBridge: @unchecked Sendable {
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

    @inline(never)
    func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) {
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [self] buffer, _ in
            consume(buffer)
        }
    }

    @inline(never)
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            try? audioFile?.write(from: buffer)
            guard let continuation, let converter, let analyzerFormat else { return }
            guard let converted = convert(
                buffer,
                using: converter,
                to: analyzerFormat
            ) else { return }
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

        let inputProvider = ConverterInputProvider(input)
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

private final class ConverterInputProvider: @unchecked Sendable {
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

private enum AppError: LocalizedError {
    case microphoneUnavailable
    case englishUnsupported
    case modelUnavailable
    case audioFormatUnavailable

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            "マイクから音声を取得できません。"
        case .englishUnsupported:
            "英語の長時間音声認識を利用できません。"
        case .modelUnavailable:
            "英語の音声認識モデルを準備できません。"
        case .audioFormatUnavailable:
            "音声認識用の音声形式を利用できません。"
        }
    }
}
