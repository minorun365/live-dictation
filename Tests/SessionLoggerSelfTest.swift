import Foundation

@main
struct SessionLoggerSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logger = try SessionLogger(
            now: Date(timeIntervalSince1970: 0),
            rootURL: root,
            mode: .japanese
        )
        logger.updateTranscript(
            english: "Hello",
            japanese: "こんにちは",
            summary: "直近の挨拶について話しています。"
        )
        logger.appendTranslation(source: "Hello", target: "こんにちは")
        logger.appendSummary("直近の挨拶について話しています。")
        logger.updateTitle(
            "ローカル翻訳の説明",
            version: SessionHistoryStore.currentTitleVersion
        )
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

        guard MeetingTitleFormatter.format(topic: "履歴タイトル") == "履歴タイトルの検討",
              MeetingTitleFormatter.format(topic: "認証権限の見直し") == "認証権限の見直し",
              MeetingTitleFormatter.format(topic: "会議") == nil,
              MeetingTitleFormatter.format(topic: "会議の要約") == nil,
              MeetingTitleFormatter.format(topic: "会議要約作成方針") == nil else {
            throw SelfTestError.invalidMeetingTitleFormat
        }

        let olderLogger = try SessionLogger(
            now: Date(timeIntervalSince1970: -60),
            rootURL: root
        )
        olderLogger.updateTranscript(
            english: "Older",
            japanese: "古いセッションです。",
            summary: "古い内容を説明しました。"
        )
        olderLogger.updateTitle("古い内容の説明")
        olderLogger.close()

        let history = try SessionHistoryStore.loadItems(rootURL: root)
        guard history.count == 2,
              history[0].title == "ローカル翻訳の説明",
              history[0].mode == .japanese,
              !history[0].needsTitleUpgrade,
              history[1].title == "古い内容の説明",
              history[1].needsTitleUpgrade else {
            throw SelfTestError.invalidSessionHistory
        }

        let savedTranscript = try SessionHistoryStore.loadTranscript(for: history[0])
        guard savedTranscript.english == "Hello",
              savedTranscript.japanese == "こんにちは",
              savedTranscript.summary == "直近の挨拶について話しています。",
              savedTranscript.mode == .japanese else {
            throw SelfTestError.invalidSavedSession
        }

        let titleSource = try SessionHistoryStore.loadTitleSource(for: history[0])
        guard titleSource.japanese == "こんにちは",
              titleSource.timelineSummaries == ["直近の挨拶について話しています。"] else {
            throw SelfTestError.invalidTitleSource
        }

        try SessionHistoryStore.saveGeneratedTitle("更新後の会議タイトル", for: history[1])
        let updatedHistory = try SessionHistoryStore.loadItems(rootURL: root)
        guard updatedHistory[1].title == "更新後の会議タイトル",
              !updatedHistory[1].needsTitleUpgrade else {
            throw SelfTestError.invalidTitleUpgrade
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
    case invalidMeetingTitleFormat
    case invalidSessionHistory
    case invalidSavedSession
    case invalidTitleSource
    case invalidTitleUpgrade
}
