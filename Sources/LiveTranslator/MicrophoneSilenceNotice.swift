import Foundation
import OSLog
@preconcurrency import UserNotifications

/// Tells the user, while the meeting is still going, that the microphone is recording
/// silence. Finding out afterwards means the meeting is lost; finding out now leaves
/// time to check the microphone or start the recording again.
enum MicrophoneSilenceNotice {
    private static let logger = Logger(subsystem: "com.minorun365.LiveDictation", category: "MicrophoneSilenceNotice")

    /// Seconds of silence after which the user is told. A room recording has nothing
    /// but the microphone and a room is never digitally silent, so it is told within
    /// seconds. A web meeting with a headset that gates its own noise can stay silent
    /// while the wearer listens, so it waits longer. Each value must be one of the
    /// marks `MeetingAudioCaptureManager` reports.
    static func notifyAfterSeconds(for mode: TranscriptionMode) -> Int {
        switch mode {
        case .inPerson, .inPersonEnglish: 10
        case .japanese, .englishTranslation: 180
        }
    }

    static func post(sessionID: String, seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "マイクの音が入っていません"
        content.body = "\(seconds)秒間、録音が無音です。つなぎ直しを試しています。マイクの接続を確かめ、直らなければ録音を止めて始め直してください"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "microphoneSilent.\(sessionID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func postRoomDeviceWarning(sessionID: String, device: MicrophoneDevice) {
        let content = UNMutableNotificationContent()
        content.title = "対面モードのマイクが「\(device.name)」です"
        content.body = device.kind == .bluetooth
            ? "Bluetoothのヘッドセットがつながっています。かばんの中で電源が入っていないか確かめ、切ってから録音を始め直してください"
            : "Macの内蔵マイクではありません。会議室の声が入らないことがあります"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "roomMicrophone.\(sessionID)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("post failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func withdraw(sessionID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["microphoneSilent.\(sessionID)"]
        )
    }
}
