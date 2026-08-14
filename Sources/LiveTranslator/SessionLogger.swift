import Foundation

final class SessionLogger {
    let directoryURL: URL
    /// Used when both sides share one recognizer, as in English mode.
    let audioURL: URL
    /// Used when the two sides are recognized separately, so each keeps its own file.
    let microphoneAudioURL: URL
    let systemAudioURL: URL

    private let transcriptURL: URL
    private let eventsURL: URL
    private let titleURL: URL
    private let titleVersionURL: URL
    private let modeURL: URL
    private let mode: TranscriptionMode
    private var eventsHandle: FileHandle?
    private let startedAt = Date()
    private let encoder = JSONEncoder()

    init(
        now: Date = Date(),
        rootURL: URL? = nil,
        mode: TranscriptionMode = .englishTranslation
    ) throws {
        self.mode = mode
        encoder.dateEncodingStrategy = .iso8601

        let root = try rootURL ?? Self.sessionsRootURL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        directoryURL = root.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        audioURL = directoryURL.appendingPathComponent("audio.m4a")
        microphoneAudioURL = directoryURL.appendingPathComponent("audio-self.m4a")
        systemAudioURL = directoryURL.appendingPathComponent("audio-others.m4a")
        transcriptURL = directoryURL.appendingPathComponent("transcript.md")
        eventsURL = directoryURL.appendingPathComponent("events.jsonl")
        titleURL = directoryURL.appendingPathComponent("title.txt")
        titleVersionURL = directoryURL.appendingPathComponent("title-version.txt")
        modeURL = directoryURL.appendingPathComponent("mode.txt")

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        eventsHandle = try FileHandle(forWritingTo: eventsURL)
        try mode.rawValue.write(to: modeURL, atomically: true, encoding: .utf8)
        updateTitle("音声セッション")
        updateTranscript(english: "", japanese: "", summary: "")
    }

    static func sessionsRootURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("LiveTranslator", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    func updateTranscript(english: String, japanese: String, summary: String) {
        let markdown = """
        # 文字起こしちゃん

        - Started: \(startedAt.ISO8601Format())
        - Updated: \(Date().ISO8601Format())
        - Mode: \(mode.rawValue)
        - Processing: On-device Apple Speech, Translation (English mode), and Foundation Models

        ## English

        \(english)

        ## 日本語

        \(japanese)

        ## 直近5分の要約

        \(summary)
        """

        do {
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        } catch {
            // Recording must continue even if a single log write fails.
        }
    }

    func appendRecognition(speaker: Speaker? = nil, text: String, isFinal: Bool) {
        var payload = ["text": text, "final": String(isFinal)]
        if let speaker {
            payload["speaker"] = speaker.rawValue
        }
        appendEvent(type: "recognition", payload: payload)
    }

    func appendTranslation(source: String, target: String) {
        appendEvent(
            type: "translation",
            payload: ["source": source, "target": target]
        )
    }

    func appendSummary(_ summary: String) {
        appendEvent(type: "summary", payload: ["text": summary])
    }

    func updateTitle(_ title: String, version: Int? = nil) {
        do {
            try title.write(to: titleURL, atomically: true, encoding: .utf8)
            if let version {
                try String(version).write(
                    to: titleVersionURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
        } catch {
            // Recording must continue even if a single metadata write fails.
        }
    }

    func appendEvent(type: String, payload: [String: String]) {
        let event = LogEvent(timestamp: Date(), type: type, payload: payload)
        guard let data = try? encoder.encode(event) else { return }
        eventsHandle?.write(data)
        eventsHandle?.write(Data([0x0A]))
    }

    func close() {
        try? eventsHandle?.synchronize()
        try? eventsHandle?.close()
        eventsHandle = nil
    }

    deinit {
        close()
    }
}

private struct LogEvent: Codable {
    let timestamp: Date
    let type: String
    let payload: [String: String]
}
