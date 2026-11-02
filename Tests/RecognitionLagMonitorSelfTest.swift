import Foundation

@main
struct RecognitionLagMonitorSelfTest {
    static func main() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

        var monitor = RecognitionLagMonitor()
        let first = monitor.observe(audioEndSeconds: 3, at: start.addingTimeInterval(5))
        try check(first.lagSeconds == 0, "最初の結果を基準にする")
        try check(first.shouldReport, "最初の結果は記録する")
        try check(!first.shouldCatchUp, "追いついている間は確定させない")

        let keepingUp = monitor.observe(audioEndSeconds: 33, at: start.addingTimeInterval(35))
        try check(keepingUp.lagSeconds == 0, "音声と同じ速さなら遅れは0")
        try check(!keepingUp.shouldReport, "60秒未満は記録しない")

        // 無音の間は結果が来ない。次の発話が遅れなく届けば遅れに数えない
        let afterSilence = monitor.observe(audioEndSeconds: 303, at: start.addingTimeInterval(305))
        try check(afterSilence.lagSeconds == 0, "無音を遅れに数えない")
        try check(afterSilence.shouldReport, "60秒たてば遅れ0でも記録する")

        let behind = monitor.observe(audioEndSeconds: 310, at: start.addingTimeInterval(372))
        try check(behind.lagSeconds == 60, "音声の進みが遅いと差が遅れになる")
        try check(behind.shouldCatchUp, "60秒遅れたら確定させる")

        let cooling = monitor.observe(audioEndSeconds: 311, at: start.addingTimeInterval(402))
        try check(cooling.lagSeconds == 89, "遅れは増え続ける")
        try check(!cooling.shouldCatchUp, "60秒以内に繰り返さない")

        let again = monitor.observe(audioEndSeconds: 312, at: start.addingTimeInterval(432))
        try check(again.shouldCatchUp, "60秒たっても遅れていればまた確定させる")

        let caughtUp = monitor.observe(audioEndSeconds: 500, at: start.addingTimeInterval(502))
        try check(caughtUp.lagSeconds == 0, "追いつけば遅れは0へ戻る")
        try check(!caughtUp.shouldCatchUp, "追いついたら確定させない")

        var fasterLater = RecognitionLagMonitor()
        _ = fasterLater.observe(audioEndSeconds: 0, at: start.addingTimeInterval(10))
        let smaller = fasterLater.observe(audioEndSeconds: 20, at: start.addingTimeInterval(22))
        try check(smaller.lagSeconds == 0, "より小さい差が出たら基準を更新する")
        let measured = fasterLater.observe(audioEndSeconds: 21, at: start.addingTimeInterval(33))
        try check(measured.lagSeconds == 10, "更新した基準から遅れを測る")

        print("RecognitionLagMonitorSelfTest OK")
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TestFailure(label: label) }
    }

    struct TestFailure: Error, CustomStringConvertible {
        let label: String
        var description: String { "NG: \(label)" }
    }
}
