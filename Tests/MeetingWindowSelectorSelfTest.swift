import Foundation

@main
struct MeetingWindowSelectorSelfTest {
    static func main() {
        func window(
            _ id: UInt32,
            _ bundleID: String,
            _ title: String,
            width: Double = 1_400,
            height: Double = 900,
            isOnScreen: Bool = true,
            layer: Int = 0
        ) -> CaptureWindowCandidate {
            CaptureWindowCandidate(
                id: id, bundleID: bundleID, title: title,
                width: width, height: height, isOnScreen: isOnScreen, layer: layer
            )
        }

        let slack = window(1, "com.tinyspeck.slackmacgap", "KAG（KDDI AGI…） - Slack", width: 2_000)
        let meet = window(2, "com.google.Chrome", "Meet - dsf-zmeg-ieg")
        let gmail = window(3, "com.google.Chrome", "受信トレイ - Gmail", width: 2_400)
        let zoomMain = window(4, "us.zoom.xos", "Zoom Workplace")
        let zoomCall = window(5, "us.zoom.xos", "Zoom ミーティング")

        // A Meet window is picked even when Slack is bigger and in front.
        check(MeetingWindowSelector.pick(from: [slack, gmail, meet], meetingBundleID: "com.google.Chrome.helper") == meet,
              "Meet の Chrome ウィンドウを選ぶ")
        // Chrome windows without a meeting in their title are never picked.
        check(MeetingWindowSelector.pick(from: [slack, gmail], meetingBundleID: "com.google.Chrome") == nil,
              "会議でない Chrome ウィンドウは選ばない")
        // Zoom's call window wins over its main window; the helper process maps to the app.
        check(MeetingWindowSelector.pick(from: [zoomMain, zoomCall, meet], meetingBundleID: "us.zoom.caphost") == zoomCall,
              "Zoom は会議ウィンドウを選び、マイクを持つアプリを優先する")
        // Minimized windows and tiny previews are skipped.
        let minimized = window(6, "com.google.Chrome", "Meet - abc", isOnScreen: false)
        let pip = window(7, "com.google.Chrome", "Meet - abc", width: 240, height: 160)
        check(MeetingWindowSelector.pick(from: [minimized, pip], meetingBundleID: nil) == nil,
              "最小化中と小さすぎるウィンドウは選ばない")
        // Without a detected app (a hand-started recording), any meeting window is used.
        check(MeetingWindowSelector.pick(from: [slack, meet], meetingBundleID: nil) == meet,
              "手動録音でも会議ウィンドウを探す")
        // Overlay layers such as menus are ignored.
        check(MeetingWindowSelector.pick(from: [window(8, "com.google.Chrome", "Meet - x", layer: 25)], meetingBundleID: nil) == nil,
              "通常レイヤー以外は選ばない")
        print("MeetingWindowSelectorSelfTest passed")
    }

    static func check(_ condition: Bool, _ label: String) {
        if !condition {
            print("FAILED: \(label)")
            exit(1)
        }
    }
}
