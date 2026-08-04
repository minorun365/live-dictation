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
        logger.updateTranscript(
            english: "Hello",
            japanese: "こんにちは",
            summary: "直近の挨拶について話しています。"
        )
        logger.appendTranslation(source: "Hello", target: "こんにちは")
        logger.appendSummary("直近の挨拶について話しています。")
        logger.close()

        let transcriptURL = logger.directoryURL.appendingPathComponent("transcript.md")
        let eventsURL = logger.directoryURL.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: transcriptURL.path),
              FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw SelfTestError.missingLogFiles
        }

        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard transcript.contains("Hello"),
              transcript.contains("こんにちは"),
              transcript.contains("直近の挨拶について話しています。") else {
            throw SelfTestError.invalidTranscript
        }

        let events = try String(contentsOf: eventsURL, encoding: .utf8)
        guard events.contains("translation"),
              events.contains("summary"),
              events.contains("直近の挨拶について話しています。") else {
            throw SelfTestError.invalidEvents
        }

        let now = Date(timeIntervalSince1970: 1_000)
        var recentWindow = RecentTranscriptWindow(duration: 300)
        recentWindow.append("古い内容", at: now.addingTimeInterval(-301))
        recentWindow.append("直近の内容", at: now.addingTimeInterval(-30))
        guard recentWindow.text(at: now) == "直近の内容" else {
            throw SelfTestError.invalidRecentWindow
        }

        let formattedSummary = SummaryTextFormatter.format(
            overview: "全体の概要です。",
            keyPoints: ["最初の要点", "2つ目の要点"]
        )
        guard formattedSummary == "全体の概要です。\n\n• 最初の要点\n• 2つ目の要点" else {
            throw SelfTestError.invalidSummaryFormat
        }

        let parsedSummary = SummaryTextFormatter.format(
            rawResponse: "<overview> 講義の概要です。 </overview>\n<point> 論点A </point>\n<point>論点B</point>"
        )
        guard parsedSummary == "講義の概要です。\n\n• 論点A\n• 論点B" else {
            throw SelfTestError.invalidSummaryFormat
        }

        print("SessionLogger self-test passed")
    }
}

private enum SelfTestError: Error {
    case missingLogFiles
    case invalidTranscript
    case invalidEvents
    case invalidRecentWindow
    case invalidSummaryFormat
}
