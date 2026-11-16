import Foundation

@main
struct MicrophoneSilenceMonitorSelfTest {
    static func main() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        var monitor = MicrophoneSilenceMonitor()
        try check(monitor.observe(peak: 0.05, at: at(0)) == .none, "音が入っている間は何もしない")
        try check(monitor.silentSeconds(at: at(0)) == nil, "音があれば無音の長さはない")

        // 実際の不具合：ピーク値が16bitで2〜13のまま続く
        let deadPeak: Float = 13.0 / 32_768
        try check(monitor.observe(peak: deadPeak, at: at(1)) == .none, "無音の始まりではまだ張り直さない")
        try check(monitor.observe(peak: deadPeak, at: at(15)) == .none, "15秒未満は待つ")
        try check(monitor.observe(peak: deadPeak, at: at(16)) == .restartCapture(attempt: 1), "15秒続いたら1回目の張り直し")
        try check(monitor.observe(peak: deadPeak, at: at(17)) == .none, "続けて張り直さない")
        try check(monitor.observe(peak: deadPeak, at: at(76)) == .restartCapture(attempt: 2), "75秒で2回目")
        try check(monitor.observe(peak: deadPeak, at: at(256)) == .restartCapture(attempt: 3), "255秒で3回目")
        try check(monitor.observe(peak: deadPeak, at: at(2_000)) == .none, "3回で打ち止め")
        try check(monitor.silentSeconds(at: at(2_000)) == 1_999, "無音の長さを数え続ける")

        try check(
            monitor.observe(peak: 0.02, at: at(2_001)) == .recovered(silentSeconds: 2_000, restarts: 3),
            "音が戻ったら復帰を知らせる"
        )
        try check(monitor.observe(peak: deadPeak, at: at(2_002)) == .none, "新しい無音は数え直す")
        try check(monitor.observe(peak: deadPeak, at: at(2_017)) == .restartCapture(attempt: 1), "数え直した無音でも1回目から")

        // 静かな会議室の雑音（過去の録音の10秒ピークの最小は数百）は無音とみなさない
        var quietRoom = MicrophoneSilenceMonitor()
        let roomNoise: Float = 300.0 / 32_768
        for second in 0..<600 {
            try check(quietRoom.observe(peak: roomNoise, at: at(TimeInterval(second))) == .none, "静かな部屋で張り直さない")
        }

        // 張り直す前に音が戻った短い無音は、復帰として知らせない
        var shortPause = MicrophoneSilenceMonitor()
        _ = shortPause.observe(peak: 0, at: at(0))
        try check(shortPause.observe(peak: 0.1, at: at(10)) == .none, "張り直していない無音は黙って戻す")

        let samples: [Float] = [0.01, -0.3, 0.2]
        let peak = samples.withUnsafeBufferPointer {
            MicrophoneSilenceMonitor.peak(of: $0.baseAddress!, count: $0.count)
        }
        try check(peak == 0.3, "負の振れも絶対値で拾う")

        print("MicrophoneSilenceMonitorSelfTest OK")
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TestFailure(label: label) }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let label: String
    var description: String { "失敗: \(label)" }
}
