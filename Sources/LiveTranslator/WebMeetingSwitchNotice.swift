import Foundation
import OSLog
@preconcurrency import UserNotifications

/// Tells the user that a room recording became a web-meeting recording because a
/// meeting app started using the microphone. Without it, the mode quietly changing
/// mid-meeting would look like a second, unexplained session afterwards.
enum WebMeetingSwitchNotice {
    private static let logger = Logger(subsystem: "com.minorun365.LiveDictation", category: "WebMeetingSwitchNotice")

    static func post(to mode: TranscriptionMode) {
        let content = UNMutableNotificationContent()
        content.title = "Web会議モードに切り替えました"
        content.body = "対面モードで録音中に会議アプリがマイクを使い始めたため、\(mode.label)のWeb会議として録り直しています。話者の区別と画面の記録が付きます"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "webMeetingSwitch.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
