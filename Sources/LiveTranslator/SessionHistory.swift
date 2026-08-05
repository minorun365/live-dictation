import Foundation

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case japanese
    case englishTranslation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .japanese: "日本語"
        case .englishTranslation: "英語→日本語"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .japanese: "ja-JP"
        case .englishTranslation: "en-US"
        }
    }
}

struct SessionHistoryItem: Identifiable, Hashable {
    let id: String
    let directoryURL: URL
    let startedAt: Date
    let title: String
    let mode: TranscriptionMode

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

enum SessionHistoryStore {
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
            let startedAt = date(fromDirectoryName: directory.lastPathComponent)
                ?? (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast

            return SessionHistoryItem(
                id: directory.path,
                directoryURL: directory,
                startedAt: startedAt,
                title: title,
                mode: mode
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func loadTranscript(for item: SessionHistoryItem) throws -> SavedSessionTranscript {
        try loadTranscript(from: item.directoryURL)
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
