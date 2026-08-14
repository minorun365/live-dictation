import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case japanese
    case inPerson
    case englishTranslation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .japanese: "日本語"
        case .inPerson: "対面"
        case .englishTranslation: "英語→日本語"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .japanese, .inPerson: "ja-JP"
        case .englishTranslation: "en-US"
        }
    }

    /// Whether the microphone and the system audio are recognized as separate speakers.
    ///
    /// The speaker is read from which input a phrase arrived on, not from the voice, so
    /// this only works when the other side comes out of the speakers. People sitting in
    /// the same room all land on the microphone, and labelling them "自分" would state
    /// something untrue rather than merely unknown.
    var separatesSpeakers: Bool { self == .japanese }

    /// Whether transcription runs through the speaker-aware Japanese path. In-person
    /// recordings take the same path but render without labels.
    var usesSpeakerTranscript: Bool { self != .englishTranslation }

    /// Whether the screen is recorded alongside the audio. In a meeting room the Mac's
    /// own screen shows nothing worth keeping, and it costs about 22MB per minute.
    var capturesScreen: Bool { self != .inPerson }
}

struct SessionHistoryItem: Identifiable, Hashable {
    let id: String
    let directoryURL: URL
    let startedAt: Date
    let title: String
    let mode: TranscriptionMode
    let needsTitleUpgrade: Bool

    var displayDate: String {
        Self.displayDateFormatter.string(from: startedAt)
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日 H:mm"
        return formatter
    }()
}

struct SavedSessionTranscript {
    let english: String
    let japanese: String
    let summary: String
    let mode: TranscriptionMode
}

struct SessionTitleSource {
    let japanese: String
    let timelineSummaries: [String]
}

enum SessionHistoryStore {
    static let currentTitleVersion = 3

    static func loadItems(rootURL: URL? = nil) throws -> [SessionHistoryItem] {
        let root = try rootURL ?? SessionLogger.sessionsRootURL()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        return directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            let transcript = try? loadTranscript(from: directory)
            let storedTitle = try? String(
                contentsOf: directory.appendingPathComponent("title.txt"),
                encoding: .utf8
            )
            let title = SessionTitleFormatter.make(
                storedTitle: storedTitle,
                summary: transcript?.summary ?? "",
                japanese: transcript?.japanese ?? ""
            )
            let mode = loadMode(from: directory)
            let titleVersion = loadTitleVersion(from: directory)
            let startedAt = date(fromDirectoryName: directory.lastPathComponent)
                ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast

            return SessionHistoryItem(
                id: directory.path,
                directoryURL: directory,
                startedAt: startedAt,
                title: title,
                mode: mode,
                needsTitleUpgrade: titleVersion < currentTitleVersion
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func loadTranscript(for item: SessionHistoryItem) throws -> SavedSessionTranscript {
        try loadTranscript(from: item.directoryURL)
    }

    static func loadTitleSource(for item: SessionHistoryItem) throws -> SessionTitleSource {
        let transcript = try loadTranscript(from: item.directoryURL)
        return SessionTitleSource(
            japanese: transcript.japanese,
            timelineSummaries: try loadTimelineSummaries(from: item.directoryURL)
        )
    }

    static func saveGeneratedTitle(_ title: String, for item: SessionHistoryItem) throws {
        try title.write(
            to: item.directoryURL.appendingPathComponent("title.txt"),
            atomically: true,
            encoding: .utf8
        )
        try String(currentTitleVersion).write(
            to: item.directoryURL.appendingPathComponent("title-version.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func loadTranscript(from directory: URL) throws -> SavedSessionTranscript {
        let markdown = try String(
            contentsOf: directory.appendingPathComponent("transcript.md"),
            encoding: .utf8
        )
        return SavedSessionTranscript(
            english: section(in: markdown, after: "## English", before: "## 日本語"),
            japanese: section(in: markdown, after: "## 日本語", before: "## 直近5分の要約"),
            summary: section(in: markdown, after: "## 直近5分の要約", before: nil),
            mode: loadMode(from: directory)
        )
    }

    private static func loadMode(from directory: URL) -> TranscriptionMode {
        guard let rawValue = try? String(
            contentsOf: directory.appendingPathComponent("mode.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .englishTranslation
        }
        return TranscriptionMode(rawValue: rawValue) ?? .englishTranslation
    }

    private static func loadTitleVersion(from directory: URL) -> Int {
        guard let value = try? String(
            contentsOf: directory.appendingPathComponent("title-version.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return 0
        }
        return Int(value) ?? 0
    }

    private static func loadTimelineSummaries(from directory: URL) throws -> [String] {
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [] }

        let data = try String(contentsOf: eventsURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = data
            .split(whereSeparator: \Character.isNewline)
            .compactMap { try? decoder.decode(SessionHistoryEvent.self, from: Data($0.utf8)) }
            .filter { $0.type == "summary" && !($0.payload["text"] ?? "").isEmpty }
            .sorted { $0.timestamp < $1.timestamp }

        guard let first = events.first else { return [] }
        var selected = [first.payload["text"] ?? ""]
        var lastSelectedAt = first.timestamp

        for event in events.dropFirst() where event.timestamp.timeIntervalSince(lastSelectedAt) >= 4 * 60 {
            let summary = event.payload["text"] ?? ""
            if summary != selected.last {
                selected.append(summary)
            }
            lastSelectedAt = event.timestamp
        }

        if let finalSummary = events.last?.payload["text"], finalSummary != selected.last {
            selected.append(finalSummary)
        }
        return selected.filter { !$0.isEmpty }
    }

    private static func section(in source: String, after heading: String, before nextHeading: String?) -> String {
        guard let headingRange = source.range(of: heading) else { return "" }
        let remainder = source[headingRange.upperBound...]
        let content: Substring
        if let nextHeading, let nextRange = remainder.range(of: nextHeading) {
            content = remainder[..<nextRange.lowerBound]
        } else {
            content = remainder
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func date(fromDirectoryName name: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: name)
    }
}

private struct SessionHistoryEvent: Decodable {
    let timestamp: Date
    let type: String
    let payload: [String: String]
}

enum MeetingTitleFormatter {
    static func format(topic: String) -> String? {
        var normalized = topic
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'「」『』【】#*・"))

        for prefix in ["テーマ：", "テーマ:", "題名：", "題名:"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if normalized.hasSuffix("について") {
            normalized.removeLast("について".count)
        }
        while let last = normalized.last, "。！？.!?".contains(last) {
            normalized.removeLast()
        }

        var specificity = normalized
        for genericWord in ["打ち合わせ", "会議", "内容", "要約", "作成", "方針"] {
            specificity = specificity.replacingOccurrences(of: genericWord, with: "")
        }
        specificity = specificity
            .replacingOccurrences(of: "について", with: "")
            .replacingOccurrences(of: "に関する", with: "")
            .replacingOccurrences(of: "の", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.count >= 4, specificity.count >= 2 else {
            return nil
        }

        let actionWords = [
            "改善", "見直し", "設計", "準備", "計画", "対応", "整理", "生成",
            "導入", "移行", "公開", "運用", "方針", "検討", "更新", "実装", "統合", "廃止"
        ]
        var title = normalized
        if !actionWords.contains(where: title.contains) {
            title += "の検討"
        }
        let limit = 24
        return title.count > limit ? String(title.prefix(limit)) : title
    }
}

enum SessionTitleFormatter {
    static func make(storedTitle: String? = nil, summary: String, japanese: String) -> String {
        let candidates = [storedTitle ?? "", summary, japanese]
        guard let source = candidates.lazy.compactMap(firstUsefulLine).first else {
            return "音声セッション"
        }

        let sentence = firstSentence(in: source)
        let limit = 30
        guard sentence.count > limit else { return sentence }
        return String(sentence.prefix(limit)) + "…"
    }

    private static func firstUsefulLine(in text: String) -> String? {
        text
            .split(whereSeparator: \Character.isNewline)
            .map { clean(String($0)) }
            .first { line in
                !line.isEmpty
                    && !line.hasPrefix("•")
                    && line != "要約を生成できません"
                    && line != "要約モデルを準備中です"
            }
    }

    private static func firstSentence(in text: String) -> String {
        let terminators = CharacterSet(charactersIn: "。！？")
        if let scalarIndex = text.unicodeScalars.firstIndex(where: { terminators.contains($0) }) {
            let end = text.unicodeScalars.index(after: scalarIndex)
            return String(text.unicodeScalars[..<end])
        }
        return text
    }

    private static func clean(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
