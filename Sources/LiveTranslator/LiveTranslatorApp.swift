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
                    model.stopRecordingIfNeeded()
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
            // Idle shows someone asleep, recording shows someone taking notes. Both read
            // as decoration to anyone else: the app is used on shared screens during
            // customer calls, so the menu bar must not look like a recorder either way
            // — no label, dot, or red tint.
            Image(nsImage: model.isRecording ? Self.recordingMenuBarIcon : Self.menuBarIcon)
        }
    }

    // Idle: someone asleep under a duvet. The drawing is wider than it is tall, so it is
    // fitted to the 18pt menu bar height instead of being squeezed into a square.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "文字起こしちゃん")!
        image.size = NSSize(width: 24, height: 18)
        return image
    }()

    // Recording: someone taking notes — the same drawing as the app icon.
    private static let recordingMenuBarIcon: NSImage = {
        guard let image = NSImage(named: "RecordingMenuBarIcon") else { return menuBarIcon }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

@available(macOS 26.4, *)
private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRecording
             ? "録音中（\(model.currentMode.label)）"
             : "待機中（会議を検知すると録音します）")

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
        }

        Button("ウィンドウを開く") {
            openWindow(id: LiveDictationApp.mainWindowID)
        }

        Divider()

        Button("文字起こしちゃんを終了") {
            model.stopRecordingIfNeeded()
            NSApplication.shared.terminate(nil)
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window leaves the app running in the menu bar. Quitting the process
    /// here would stop the meeting detector, which is the one thing that has to keep
    /// working while nothing is on screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
