import Foundation

/// Tracks how far one recognizer has fallen behind the live audio.
///
/// Silence produces no results, so the gap is only measured when a result arrives. The
/// smallest gap seen so far stands in for "keeping up", which also absorbs the unknown
/// offset between the recognizer's timeline and the wall clock.
struct RecognitionLagMonitor {
    struct Observation: Equatable {
        let lagSeconds: Double
        let shouldReport: Bool
        let shouldCatchUp: Bool
    }

    static let catchUpThreshold: TimeInterval = 60
    static let catchUpCooldown: TimeInterval = 60
    static let reportInterval: TimeInterval = 60

    private var smallestGap: TimeInterval?
    private var lastReportAt: Date?
    private var lastCatchUpAt: Date?

    mutating func observe(audioEndSeconds: Double, at now: Date) -> Observation {
        let gap = now.timeIntervalSinceReferenceDate - audioEndSeconds
        let baseline = min(smallestGap ?? gap, gap)
        smallestGap = baseline
        let lag = gap - baseline

        let shouldReport = lastReportAt.map {
            now.timeIntervalSince($0) >= Self.reportInterval
        } ?? true
        if shouldReport {
            lastReportAt = now
        }

        let cooledDown = lastCatchUpAt.map {
            now.timeIntervalSince($0) >= Self.catchUpCooldown
        } ?? true
        let shouldCatchUp = lag >= Self.catchUpThreshold && cooledDown
        if shouldCatchUp {
            lastCatchUpAt = now
        }

        return Observation(
            lagSeconds: lag,
            shouldReport: shouldReport,
            shouldCatchUp: shouldCatchUp
        )
    }
}

/// Keeps macOS from throttling the app for as long as a recording session is alive,
/// including the time its recognizers need to finish after capture stops.
final class RecordingActivity {
    private let token: NSObjectProtocol

    init() {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "会議の文字起こしを遅らせないため"
        )
    }

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}
