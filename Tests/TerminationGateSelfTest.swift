import Foundation

@main
struct TerminationGateSelfTest {
    @MainActor
    static func main() async {
        // 録音も停止処理もなければ、すぐ終了してよい
        let idle = TerminationGate()
        var idleReplies: [Bool] = []
        let idleNow = idle.shouldTerminateNow(timeout: .seconds(1)) { idleReplies.append($0) }
        expect(idleNow, "待つものがなければすぐ終了")
        expect(idleReplies.isEmpty, "すぐ終了するときは後から返事をしない")

        // 停止処理が残っていれば、終わるまで待ってから終了を許す
        let pending = TerminationGate()
        var finished = false
        var pendingReplies: [Bool] = []
        pending.hasPendingWork = { !finished }
        pending.finishPendingWork = {
            try? await Task.sleep(for: .milliseconds(100))
            finished = true
        }
        let pendingNow = pending.shouldTerminateNow(timeout: .seconds(5)) { pendingReplies.append($0) }
        expect(!pendingNow, "停止処理が残っていればすぐには終了しない")
        expect(pendingReplies.isEmpty, "停止処理が終わる前に返事をしない")
        await waitUntil { !pendingReplies.isEmpty }
        expect(finished, "停止処理を終えてから返事をする")
        expect(pendingReplies == [true], "停止処理のあと終了を許す")

        // 停止処理が固まっても、上限を過ぎたら終了を許す
        let stuck = TerminationGate()
        var stuckReplies: [Bool] = []
        stuck.hasPendingWork = { true }
        stuck.finishPendingWork = {
            try? await Task.sleep(for: .seconds(60))
        }
        let startedAt = ContinuousClock.now
        let stuckNow = stuck.shouldTerminateNow(timeout: .milliseconds(200)) { stuckReplies.append($0) }
        expect(!stuckNow, "固まっていてもまずは待つ")
        await waitUntil { !stuckReplies.isEmpty }
        expect(stuckReplies == [true], "上限を過ぎたら終了を許す")
        expect(ContinuousClock.now - startedAt < .seconds(5), "上限で打ち切る")

        // 待っている間に重ねて終了を頼まれても、返事は 1 回だけ
        let twice = TerminationGate()
        var done = false
        var twiceReplies: [Bool] = []
        twice.hasPendingWork = { !done }
        twice.finishPendingWork = {
            try? await Task.sleep(for: .milliseconds(100))
            done = true
        }
        _ = twice.shouldTerminateNow(timeout: .seconds(5)) { twiceReplies.append($0) }
        let secondNow = twice.shouldTerminateNow(timeout: .seconds(5)) { twiceReplies.append($0) }
        expect(!secondNow, "待っている間の重ねての終了もすぐには終了しない")
        await waitUntil { done }
        try? await Task.sleep(for: .milliseconds(200))
        expect(twiceReplies == [true], "返事は 1 回だけ")

        print("TerminationGateSelfTest passed")
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fatalError("失敗: \(message)")
        }
    }
}
