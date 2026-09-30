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
        // Teams titles the call window after the meeting subject, so the detected app's
        // newest non-main window is used.
        let teamsMain = window(20, "com.microsoft.teams2", "チャット | 木村さん | Microsoft Teams", width: 2_000)
        let teamsCall = window(31, "com.microsoft.teams2", "Co-pilot課題の集中ヒアリング | Microsoft Teams")
        check(MeetingWindowSelector.pick(from: [teamsMain, teamsCall, slack], meetingBundleID: "com.microsoft.teams2") == teamsCall,
              "Teams は会議名のウィンドウを選ぶ")
        check(MeetingWindowSelector.pick(from: [teamsMain, slack], meetingBundleID: "com.microsoft.teams2") == nil,
              "Teams のメイン画面だけなら選ばない")
        // A title-less guess is only made for the app holding the microphone.
        check(MeetingWindowSelector.pick(from: [teamsCall], meetingBundleID: "com.google.Chrome") == nil,
              "マイクを持たないアプリは題名で判定する")
        // The main window of the detected app is never taken for the call.
        check(MeetingWindowSelector.pick(from: [zoomMain], meetingBundleID: "us.zoom.caphost") == nil,
              "Zoom のメイン画面は選ばない")
        print("MeetingWindowSelectorSelfTest passed")
    }

    static func check(_ condition: Bool, _ label: String) {
        if !condition {
            print("FAILED: \(label)")
            exit(1)
        }
    }
}
