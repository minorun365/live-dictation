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
             : "待機中（会議を検知すると録音します）")

        if let warning = model.inPersonFeedWarning {
            Text(warning)
        }

        // The menu has three kinds of entries, kept apart by dividers: acting on the
        // recording, the automatic-recording setting, and the app itself.
        Divider()

        if model.isRecording {
            Button("録音を停止") {
                Task { await model.toggleRecording() }
            }
            if !model.currentMode.translatesEnglish {
                Button("英語モードに切り替える") {
                    Task { await model.switchToEnglish() }
                }
            }
        } else {
            // One header, then every way to start by hand. Each entry records in a
            // fixed mode instead of following the window's picker, so the menu alone
            // says what will happen.
            //
            // There are two places (web, in a room) times two languages. Listing all
            // four makes every row carry a qualifier, so the rows are the two places
            // in Japanese — what nearly every recording is, and done in a hurry — and
            // English, the rare case, gets one row that opens onto the same two.
            Section("手動で録音を開始") {
                Button("Web会議") {
                    Task { await model.startRecording(as: .japanese) }
                }
                Button("対面会議") {
                    Task { await model.startRecording(as: .inPerson) }
                }
                Menu("英語で開始") {
                    Button("Web会議") {
                        Task { await model.startRecording(as: .englishTranslation) }
                    }
                    Button("対面会議") {
                        Task { await model.startRecording(as: .inPersonEnglish) }
                    }
                }
            }
        }

        Divider()

        Toggle("対面会議を自動で録音", isOn: $autoStartsInPerson)

        Divider()

        Button("ウィンドウを開く") {
            openWindow(id: LiveDictationApp.mainWindowID)
        }

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
