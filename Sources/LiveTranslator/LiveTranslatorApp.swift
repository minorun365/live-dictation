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
            // Kept plain on purpose — a status word rather than a coloured light.
            if model.isRecording {
                Label("録音中", systemImage: "waveform")
            } else {
                Image(systemName: "waveform")
            }
        }
    }
}

@available(macOS 26.4, *)
private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isRecording ? "録音中" : "待機中（会議を検知すると録音します）")

        Divider()

        Button(model.isRecording ? "録音を停止" : "録音を開始") {
            Task { await model.toggleRecording() }
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
