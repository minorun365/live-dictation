import Foundation

@main
struct SessionLoggerSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = try SessionLogger(
            now: Date(timeIntervalSince1970: 0),
            rootURL: root
        )
        logger.updateTranscript(english: "Hello", japanese: "こんにちは")
        logger.appendTranslation(source: "Hello", target: "こんにちは")
        logger.close()

        let transcriptURL = logger.directoryURL.appendingPathComponent("transcript.md")
        let eventsURL = logger.directoryURL.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: transcriptURL.path),
              FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw SelfTestError.missingLogFiles
        }

        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard transcript.contains("Hello"), transcript.contains("こんにちは") else {
            throw SelfTestError.invalidTranscript
        }

        let events = try String(contentsOf: eventsURL, encoding: .utf8)
        guard events.contains("translation"), events.contains("こんにちは") else {
            throw SelfTestError.invalidEvents
        }

        print("SessionLogger self-test passed")
    }
}

private enum SelfTestError: Error {
    case missingLogFiles
    case invalidTranscript
    case invalidEvents
}
