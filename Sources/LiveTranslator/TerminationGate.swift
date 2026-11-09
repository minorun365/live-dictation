import Foundation

/// アプリの終了を、録音の保存が終わるまで待たせる。
///
/// 停止処理（音声ファイルを閉じる・タイトルを付ける・ログを閉じる）は非同期で進む。
/// その途中でプロセスが終わると、音声ファイルに再生用の目次（moov）が書かれず開けなくなる。
/// AppDelegate の `applicationShouldTerminate` からこれを呼び、片づくまで終了を保留する。
@MainActor
final class TerminationGate {
    static let shared = TerminationGate()

    /// 録音中、または停止処理の途中のセッションがあるか。
    var hasPendingWork: () -> Bool = { false }
    /// 録音を止め、停止処理の途中のものも含めて全部終わるまで待つ。
    var finishPendingWork: () async -> Void = {}

    private var isWaiting = false

    /// - Returns: すぐ終了してよければ `true`。`false` のときは、片づいたあとか
    ///   `timeout` を過ぎたあとに `reply(true)` を 1 回だけ呼ぶ。
    func shouldTerminateNow(
        timeout: Duration,
        reply: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        if isWaiting { return false }
        guard hasPendingWork() else { return true }

        isWaiting = true
        var hasReplied = false
        let replyOnce = {
            guard !hasReplied else { return }
            hasReplied = true
            reply(true)
        }
        let finish = finishPendingWork
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            replyOnce()
        }
        Task { @MainActor in
            await finish()
            timeoutTask.cancel()
            replyOnce()
        }
        return false
    }
}
