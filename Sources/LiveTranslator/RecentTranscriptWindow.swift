import Foundation

struct RecentTranscriptWindow {
    private struct Segment {
        let recordedAt: Date
        let text: String
    }

    private let duration: TimeInterval
    private var segments: [Segment] = []

    init(duration: TimeInterval = 5 * 60) {
        self.duration = duration
    }

    mutating func append(_ text: String, at recordedAt: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        segments.append(Segment(recordedAt: recordedAt, text: trimmed))
        removeExpiredSegments(at: recordedAt)
    }

    mutating func text(at now: Date = Date()) -> String {
        removeExpiredSegments(at: now)
        return segments.map(\.text).joined(separator: " ")
    }

    mutating func removeAll() {
        segments.removeAll(keepingCapacity: true)
    }

    private mutating func removeExpiredSegments(at now: Date) {
        let cutoff = now.addingTimeInterval(-duration)
        segments.removeAll { $0.recordedAt < cutoff }
    }
}

enum SummaryTextFormatter {
    static func format(rawResponse: String) -> String {
        let overview = values(in: rawResponse, tag: "overview").first ?? ""
        let keyPoints = Array(values(in: rawResponse, tag: "point").prefix(5))

        if !overview.isEmpty || !keyPoints.isEmpty {
            return format(overview: overview, keyPoints: keyPoints)
        }

        return fallbackFormat(rawResponse)
    }

    static func format(overview: String, keyPoints: [String]) -> String {
        let overview = clean(overview)
        let bullets = keyPoints
            .map(clean)
            .filter { !$0.isEmpty }
            .map { "• \($0)" }
            .joined(separator: "\n")

        if overview.isEmpty { return bullets }
        if bullets.isEmpty { return overview }
        return overview + "\n\n" + bullets
    }

    private static func values(in source: String, tag: String) -> [String] {
        let opening = "<\(tag)>"
        let closing = "</\(tag)>"
        var remainder = source[...]
        var results: [String] = []

        while let openingRange = remainder.range(of: opening),
              let closingRange = remainder[openingRange.upperBound...].range(of: closing) {
            results.append(String(remainder[openingRange.upperBound..<closingRange.lowerBound]))
            remainder = remainder[closingRange.upperBound...]
        }

        return results
    }

    private static func fallbackFormat(_ source: String) -> String {
        let lines = source
            .split(whereSeparator: \Character.isNewline)
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }

        let bulletPrefixes = ["• ", "- ", "* ", "・"]
        let points = lines.compactMap { line -> String? in
            guard let prefix = bulletPrefixes.first(where: { line.hasPrefix($0) }) else { return nil }
            return clean(String(line.dropFirst(prefix.count)))
        }
        let overviewLines = lines.filter { line in
            !bulletPrefixes.contains(where: { line.hasPrefix($0) })
                && line != "概要"
                && line != "要点"
                && line != "概要:"
                && line != "要点:"
                && line != "概要："
                && line != "要点："
        }

        return format(
            overview: overviewLines.joined(separator: " "),
            keyPoints: Array(points.prefix(5))
        )
    }

    private static func clean(_ text: String) -> String {
        text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
