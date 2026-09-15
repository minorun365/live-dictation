import Foundation
import IOKit.pwr_mgt

/// 録音中だけ、ディスプレイが省電力で消えるのを止める。
///
/// 会議音声もマイクもScreenCaptureKitの同じストリームから届く。そのストリームは
/// メインディスプレイを対象に張られているため、画面が消えると
/// 「取り込みを行うディスプレイまたはウインドウが見つかりませんでした」で停止し、
/// マイクごと無音になる。本体のスリープを止めるだけでは防げない。macOSは
/// 「本体が寝ない」と「画面が消えない」を別のアサーションとして扱うので、
/// 後者を名指しで取る必要がある。
///
/// 解放はstop()側と必ず対にする。取りっぱなしにすると録音していない間も画面が
/// 消えなくなる。
final class DisplaySleepBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    /// すでに取得済みなら何もしない。start()が再入しても二重取得にならない。
    func begin(reason: String) {
        lock.withLock {
            guard assertionID == nil else { return }
            var identifier: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &identifier
            )
            guard result == kIOReturnSuccess else { return }
            assertionID = identifier
        }
    }

    func end() {
        lock.withLock {
            guard let identifier = assertionID else { return }
            IOPMAssertionRelease(identifier)
            assertionID = nil
        }
    }

    var isBlocking: Bool {
        lock.withLock { assertionID != nil }
    }
}
