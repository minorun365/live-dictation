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
