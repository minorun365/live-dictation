import Foundation

final class SessionLogger {
    let directoryURL: URL
    let audioURL: URL

    private let transcriptURL: URL
    private let eventsURL: URL
    private var eventsHandle: FileHandle?
    private let startedAt = Date()
    private let encoder = JSONEncoder()

    init(now: Date = Date(), rootURL: URL? = nil) throws {
        encoder.dateEncodingStrategy = .iso8601

        let root = try rootURL ?? Self.sessionsRootURL()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        directoryURL = root.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        audioURL = directoryURL.appendingPathComponent("audio.caf")
        transcriptURL = directoryURL.appendingPathComponent("transcript.md")
        eventsURL = directoryURL.appendingPathComponent("events.jsonl")

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        eventsHandle = try FileHandle(forWritingTo: eventsURL)
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
        # Live Translator

        - Started: \(startedAt.ISO8601Format())
        - Updated: \(Date().ISO8601Format())
        - Processing: On-device speech recognition, Apple Translation, and Apple Foundation Models

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

    func appendRecognition(text: String, isFinal: Bool) {
        appendEvent(
            type: "recognition",
            payload: ["text": text, "final": String(isFinal)]
        )
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
