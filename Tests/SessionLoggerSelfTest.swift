import CoreGraphics
import Foundation

@main
struct SessionLoggerSelfTest {
    static func main() async throws {
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

        let screenshotStartedAt = Date(timeIntervalSince1970: 100)
        let screenshotStore = try ScreenshotSessionStore(
            sessionDirectoryURL: logger.directoryURL,
            startedAt: screenshotStartedAt
        )
        let darkImage = try makeSolidImage(gray: 0)
        let lightImage = try makeSolidImage(gray: 255)
        try await screenshotStore.save(darkImage, capturedAt: screenshotStartedAt)
        try await screenshotStore.save(
            darkImage,
            capturedAt: screenshotStartedAt.addingTimeInterval(1)
        )
        try await screenshotStore.save(
            lightImage,
            capturedAt: screenshotStartedAt.addingTimeInterval(2)
        )
        try await screenshotStore.save(
            darkImage,
            capturedAt: screenshotStartedAt.addingTimeInterval(3)
        )
        try await screenshotStore.finish()

        let screenshotsURL = logger.directoryURL.appendingPathComponent("screenshots")
        let screenshotIndex = try String(
            contentsOf: screenshotsURL.appendingPathComponent("index.jsonl"),
            encoding: .utf8
        )
        let representativeIndex = try String(
            contentsOf: screenshotsURL.appendingPathComponent("representatives.jsonl"),
            encoding: .utf8
        )
        let timeline = try String(
            contentsOf: screenshotsURL.appendingPathComponent("timeline.md"),
            encoding: .utf8
        )
        guard screenshotIndex.split(separator: "\n").count == 4,
              representativeIndex.split(separator: "\n").count == 3,
              timeline.contains("00:00:00"),
              timeline.contains("000003_0000002000ms.jpg"),
              timeline.contains("000004_0000003000ms.jpg") else {
            throw SelfTestError.invalidScreenshotLog
        }

        let transcriptURL = logger.directoryURL.appendingPathComponent("transcript.md")
        let eventsURL = logger.directoryURL.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: transcriptURL.path),
              FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw SelfTestError.missingLogFiles
        }

        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
        guard transcript.contains("Hello"),
              transcript.contains("こんにちは"),
              transcript.contains("# 文字起こしちゃん"),
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

    private static func makeSolidImage(gray: UInt8) throws -> CGImage {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: gray, count: width * height)
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return nil
            }
            return context.makeImage()
        }
        guard let image else { throw SelfTestError.invalidScreenshotLog }
        return image
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
    case invalidScreenshotLog
}
