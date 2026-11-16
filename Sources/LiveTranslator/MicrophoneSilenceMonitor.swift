import Foundation

/// Notices when the microphone keeps delivering buffers that carry no sound.
///
/// A capture can come up with the microphone wired to nothing: the stream reports the
/// source as ready and keeps handing over buffers on time, but every sample is zero.
/// That happens when recording starts within seconds of opening the lid, before the
/// built-in microphone has come back. The arrival-based watchdog cannot see it, and the
/// whole meeting is recorded as silence. A real microphone never reads as digital
/// silence: even a quiet room keeps 10-second peaks in the hundreds (16-bit scale),
/// so a peak below `silenceThreshold` that lasts is treated as a dead capture.
///
/// Headsets that gate their own noise can also read as zero while the wearer listens,
/// so the monitor only asks for a limited number of capture restarts per silent
/// stretch and leaves the decision to notify to the caller.
struct MicrophoneSilenceMonitor {
    enum Action: Equatable {
        case none
        /// Tear the capture down and start it again. `attempt` counts from 1 within
        /// the current silent stretch.
        case restartCapture(attempt: Int)
        /// Sound came back after a silent stretch that lasted `silentSeconds`.
        case recovered(silentSeconds: Int, restarts: Int)
    }

    /// About 40 on the 16-bit scale. Normal recordings never stay below it for 10 seconds.
    static let silenceThreshold: Float = 0.0012
    /// Seconds of silence before each restart, counted from the start of the stretch.
    static let restartAfter: [TimeInterval] = [15, 75, 255]

    private(set) var silentSince: Date?
    private var restartsInStretch = 0

    /// Seconds the current silent stretch has lasted, or nil while sound is arriving.
    func silentSeconds(at now: Date) -> TimeInterval? {
        silentSince.map { now.timeIntervalSince($0) }
    }

    mutating func observe(peak: Float, at now: Date) -> Action {
        if peak >= Self.silenceThreshold {
            defer {
                silentSince = nil
                restartsInStretch = 0
            }
            guard let since = silentSince, restartsInStretch > 0 else { return .none }
            return .recovered(
                silentSeconds: Int(now.timeIntervalSince(since)),
                restarts: restartsInStretch
            )
        }

        let since = silentSince ?? now
        silentSince = since
        guard restartsInStretch < Self.restartAfter.count else { return .none }
        let due = Self.restartAfter[restartsInStretch]
        guard now.timeIntervalSince(since) >= due else { return .none }
        restartsInStretch += 1
        return .restartCapture(attempt: restartsInStretch)
    }

    /// Forget the current stretch, for a new recording.
    mutating func reset() {
        silentSince = nil
        restartsInStretch = 0
    }

    /// The loudest sample in a mono float buffer.
    static func peak(of samples: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        for index in 0..<count {
            let value = abs(samples[index])
            if value > peak { peak = value }
        }
        return peak
    }
}
