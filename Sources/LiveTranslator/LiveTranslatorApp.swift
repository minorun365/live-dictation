import SwiftUI

@main
@available(macOS 26.4, *)
struct LiveDictationApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView(model: model)
                .frame(minWidth: 1_250, minHeight: 520)
        }
        .defaultSize(width: 1_470, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("文字起こしちゃんを終了") {
                    // 録音の保存は AppDelegate.applicationShouldTerminate が待つ
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }

        // The app has to outlive its window: meetings are detected while nothing is on
        // screen, so closing the window must not take the detector down with it.
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            // Idle shows someone asleep, recording shows someone taking notes. The menu
            // bar shows up on shared screens, so it carries only a small drawing — no
            // label, dot, or red tint that would distract from what is being presented.
            MenuBarLabel(model: model)
        }
    }

    /// Whether the main window exists, on screen or in the Dock. `openWindow` on a
    /// `WindowGroup` adds another window each time, so callers check this first.
    static var mainWindowIsOpen: Bool {
        NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }
    }

    // Idle: someone who dozed off over a book. The drawing is roughly square, so it
    // sits in the same 18pt square as the recording icon.
    fileprivate static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "文字起こしちゃん")!
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    // Recording: someone taking notes — the same drawing as the app icon.
    fileprivate static let recordingMenuBarIcon: NSImage = {
        guard let image = NSImage(named: "RecordingMenuBarIcon") else { return menuBarIcon }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// The menu bar icon. It is the one view that lives as long as the app does, so it
/// also carries out the model's requests to bring the main window back: an English
/// recording the detector starts on its own has no button press to open it from.
@available(macOS 26.4, *)
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: model.isRecording
              ? LiveDictationApp.recordingMenuBarIcon
              : LiveDictationApp.menuBarIcon)
            .onChange(of: model.mainWindowRequest) {
                guard !LiveDictationApp.mainWindowIsOpen else { return }
                openWindow(id: LiveDictationApp.mainWindowID)
            }
    }
}

@available(macOS 26.4, *)
private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Read by `InPersonReminder` on every check, so flipping it takes effect at once.
    @AppStorage(InPersonReminder.autoStartDefaultsKey) private var autoStartsInPerson = false

    var body: some View {
        Text(model.isRecording
             ? "録音中（\(model.currentMode.label)）"
             : model.nextMeetingIsEnglish
             ? "待機中（次の会議は英語で録音します）"
             : "待機中（会議を検知すると録音します）")

        if let warning = model.inPersonFeedWarning {
            Text(warning)
        }

        Divider()

        Button(model.isRecording ? "録音を停止" : "手動で録音開始") {
            Task { await model.toggleRecording() }
        }

        // Meeting rooms are where the window is least likely to be open, so in-person
        // recording gets its own entry rather than a mode to pick beforehand.
        if !model.isRecording {
            Button("対面会議を開始") {
                Task { await model.startInPersonRecording() }
            }
            // English gets the same kind of entry: the detector starts every meeting
            // in the mode picked in the window, which is Japanese unless someone
            // opened the window and changed it beforehand.
            Button("英語会議を開始") {
                Task { await model.startEnglishRecording() }
            }
            Toggle("次の会議は英語で録音", isOn: Binding(
                get: { model.nextMeetingIsEnglish },
                set: { model.setNextMeetingEnglish($0) }
            ))
        } else if model.currentMode != .englishTranslation {
            Button("英語モードに切り替える") {
                Task { await model.switchToEnglish() }
            }
        }

        Divider()

        Toggle("対面会議を自動で録音", isOn: $autoStartsInPerson)

        Button("ウィンドウを開く") {
            openWindow(id: LiveDictationApp.mainWindowID)
        }

        Divider()

        Button("文字起こしちゃんを終了") {
            // 録音の保存は AppDelegate.applicationShouldTerminate が待つ
            NSApplication.shared.terminate(nil)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// First launch only: remind the user to tell meeting participants about the
    /// recording. One button, no opt-out of recording — the reminder informs, it does
    /// not gate, and it never shows again once acknowledged.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        guard RecordingNotice.needsShowing(in: defaults) else { return }

        let alert = NSAlert()
        alert.messageText = RecordingNotice.title
        alert.informativeText = RecordingNotice.message
        alert.addButton(withTitle: RecordingNotice.buttonTitle)
        NSApplication.shared.activate()
        alert.runModal()
        RecordingNotice.markAcknowledged(in: defaults)
    }

    /// Closing the window leaves the app running in the menu bar. Quitting the process
    /// here would stop the meeting detector, which is the one thing that has to keep
    /// working while nothing is on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 録音中や停止処理の途中で終わると、音声ファイルに目次が書かれず開けなくなる。
    /// 保存が終わるまで終了を保留する。固まったときに終われなくならないよう上限を設ける。
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let terminateNow = TerminationGate.shared.shouldTerminateNow(timeout: .seconds(60)) { allow in
            sender.reply(toApplicationShouldTerminate: allow)
        }
        return terminateNow ? .terminateNow : .terminateLater
    }
}
