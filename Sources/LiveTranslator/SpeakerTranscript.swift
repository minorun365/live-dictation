import CoreMedia
import Foundation
import Speech

@available(macOS 26.0, *)
extension AttributedString {
    /// Where this phrase starts inside the recording, as reported by the recognizer.
    /// The two recognizers run independently, so this is what puts their results back
    /// into conversational order.
    var audioStartSeconds: Double? {
        for run in runs {
            if let timeRange = run.audioTimeRange {
                return CMTimeGetSeconds(timeRange.start)
            }
        }
        return nil
    }
}

/// Which side of the meeting a phrase came from.
/// ScreenCaptureKit delivers the microphone and the system audio on separate streams,
/// so the speaker is observed directly instead of being inferred from voice characteristics.
enum Speaker: String, CaseIterable, Sendable {
    case me
    case others

    var label: String {
        switch self {
        case .me: "自分"
        case .others: "相手"
        }
    }
}

/// One finalized phrase, positioned by where it starts inside the recording.
struct TranscriptSegment: Equatable {
    let speaker: Speaker
    let startSeconds: Double
    let text: String
}

/// Merges the two independent recognizers back into a single chronological conversation.
/// Results arrive per speaker and out of order, so segments are placed by audio time
/// rather than by the order the recognizers happen to report them.
struct SpeakerTranscript {
    /// In-person recordings put everyone on one microphone, so the speaker cannot be
    /// observed. Labelling those phrases "自分" would be wrong rather than unknown, so
    /// they are rendered without a label.
    var labelsSpeakers = true

    private var segments: [TranscriptSegment] = []
    private var volatileText: [Speaker: String] = [:]
    private var lastKnownStart: Double = 0

    var isEmpty: Bool {
        segments.isEmpty && volatileText.values.allSatisfy(\String.isEmpty)
    }

    /// Adds a finalized phrase. `startSeconds` comes from the recognizer's audio time range;
    /// when it is missing the phrase is appended after everything seen so far.
    mutating func commit(speaker: Speaker, text: String, startSeconds: Double?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let start = startSeconds ?? lastKnownStart
        lastKnownStart = max(lastKnownStart, start)

        let segment = TranscriptSegment(speaker: speaker, startSeconds: start, text: trimmed)
        var index = segments.count
        while index > 0, segments[index - 1].startSeconds > start {
            index -= 1
        }
        segments.insert(segment, at: index)
        volatileText[speaker] = ""
    }

    mutating func setVolatile(speaker: Speaker, text: String) {
        volatileText[speaker] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func takeVolatile(for speaker: Speaker) -> String {
        let text = volatileText[speaker] ?? ""
        volatileText[speaker] = ""
        return text
    }

    mutating func removeAll() {
        segments.removeAll(keepingCapacity: true)
        volatileText.removeAll(keepingCapacity: true)
        lastKnownStart = 0
    }

    /// Confirmed conversation only. Used for saving and for summarization.
    var finalizedText: String {
        render(lines: speakerLines(from: segments))
    }

    /// Confirmed conversation plus the phrases still being recognized. Used for the live view.
    var displayText: String {
        var lines = speakerLines(from: segments)

        for speaker in Speaker.allCases {
            let pending = volatileText[speaker] ?? ""
            guard !pending.isEmpty else { continue }

            if let last = lines.indices.last, lines[last].speaker == speaker {
                lines[last].text += pending
            } else {
                lines.append(SpeakerLine(speaker: speaker, text: pending))
            }
        }

        return render(lines: lines)
    }

    private struct SpeakerLine {
        let speaker: Speaker
        var text: String
    }

    /// Consecutive phrases from the same speaker read as one turn, so they share a line.
    private func speakerLines(from segments: [TranscriptSegment]) -> [SpeakerLine] {
        var lines: [SpeakerLine] = []
        for segment in segments {
            if let last = lines.indices.last, lines[last].speaker == segment.speaker {
                lines[last].text += segment.text
            } else {
                lines.append(SpeakerLine(speaker: segment.speaker, text: segment.text))
            }
        }
        return lines
    }

    private func render(lines: [SpeakerLine]) -> String {
        lines
            .filter { !$0.text.isEmpty }
            .map { labelsSpeakers ? "\($0.speaker.label)：\($0.text)" : $0.text }
            .joined(separator: "\n")
    }
}
