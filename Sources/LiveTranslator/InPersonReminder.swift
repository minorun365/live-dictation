import AppKit
import Foundation
import OSLog
@preconcurrency import UserNotifications

/// Reminds, five minutes before an in-person meeting, that nothing is recording yet —
/// with a button that starts the in-person recording right away.
///
/// Web meetings start recording by themselves because the meeting app takes the
/// microphone. A meeting in a room gives no such signal, so it is easy to walk in and
/// forget. The list of in-person meetings comes from `InPersonMeetings.json`, which a
/// separate job writes; without that file this reminder simply stays quiet.
@MainActor
final class InPersonReminder: NSObject {
    /// Shown in the menu when the meeting list has stopped refreshing, so a broken
    /// feed is noticed before a meeting is missed. `nil` while the feed is healthy or
    /// was never set up.
    private(set) var feedWarning: String?
    var onFeedWarningChange: ((String?) -> Void)?

    private let feedURL: URL
    private let isRecording: () -> Bool
    private let startInPersonRecording: () async -> Void
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.minorun365.LiveDictation", category: "InPersonReminder")

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var meetings: [InPersonMeeting] = []
    private var feedModifiedAt: Date?
    private var reminded: Set<String> = []

    nonisolated private static let categoryID = "inPersonMeeting"
    nonisolated private static let startActionID = "startInPersonRecording"
    /// The poll also drives the five-minute mark, so it has to be well under a minute.
    private static let pollInterval: TimeInterval = 20

    init(
        isRecording: @escaping () -> Bool,
        startInPersonRecording: @escaping () async -> Void
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        feedURL = support
            .appendingPathComponent("LiveTranslator", isDirectory: true)
            .appendingPathComponent(InPersonMeetingFeed.fileName)
        self.isRecording = isRecording
        self.startInPersonRecording = startInPersonRecording
        super.init()
    }

    func start() {
        guard timer == nil else { return }
        center.delegate = self
        let startAction = UNNotificationAction(
            identifier: Self.startActionID,
            title: "対面で録音開始",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [startAction],
                intentIdentifiers: [],
                options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            logger.info("notification authorization granted=\(granted, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // A timer does not fire while the Mac sleeps. Checking on wake means a meeting
        // whose five-minute mark passed with the lid closed is still reminded as soon
        // as the lid opens.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    /// Called whenever recording starts or stops. Starting takes the reminder off the
    /// screen; stopping may release one that was held back during a web meeting.
    func recordingStateChanged() {
        if isRecording() {
            center.removeAllDeliveredNotifications()
        }
        evaluate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        let now = Date()
        reloadFeedIfChanged(now: now)
        withdrawEndedReminders(now: now)

        // While something is recording — typically the web meeting just before — a
        // banner would only show up on a shared screen. Hold it until that ends.
        guard !isRecording() else { return }

        for meeting in InPersonReminderRule.due(meetings, at: now, alreadyReminded: reminded) {
            reminded.insert(meeting.reminderKey)
            post(meeting)
        }
    }

    private func reloadFeedIfChanged(now: Date) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: feedURL.path))?[.modificationDate] as? Date
        guard let modified else {
            meetings = []
            updateFeedWarning(nil)
            return
        }
        if modified != feedModifiedAt {
            do {
                let feed = try InPersonMeetingFeed.load(from: feedURL)
                meetings = feed.meetings
                feedModifiedAt = modified
                updateFeedWarning(warning(for: feed, now: now))
            } catch {
                logger.error("feed unreadable: \(error.localizedDescription, privacy: .public)")
                updateFeedWarning("対面会議の予定を読み込めません")
            }
        } else if let feed = try? InPersonMeetingFeed.load(from: feedURL) {
            // The file is unchanged, but "unchanged for too long" is itself the warning.
            updateFeedWarning(warning(for: feed, now: now))
        }
    }

    private func warning(for feed: InPersonMeetingFeed, now: Date) -> String? {
        guard InPersonReminderRule.isStale(feed, at: now) else { return nil }
        guard let fetchedAt = feed.fetchedAt else { return "対面会議の予定の取得が止まっています" }
        return "対面会議の予定の取得が止まっています（最終 \(Self.timeFormatter.string(from: fetchedAt))）"
    }

    private func updateFeedWarning(_ warning: String?) {
        guard warning != feedWarning else { return }
        feedWarning = warning
        onFeedWarningChange?(warning)
    }

    /// A reminder left on screen after its meeting ended would start a recording for
    /// nothing if clicked late.
    private func withdrawEndedReminders(now: Date) {
        let ended = meetings.filter { $0.end <= now }.map(\.reminderKey)
        guard !ended.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ended)
    }

    private func post(_ meeting: InPersonMeeting) {
        let content = UNMutableNotificationContent()
        content.title = "まもなく「\(meeting.title)」"
        var body = "\(Self.timeFormatter.string(from: meeting.start))〜\(Self.timeFormatter.string(from: meeting.end))"
        if let location = meeting.location, !location.isEmpty {
            body += "　\(location)"
        }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["end": meeting.end.timeIntervalSince1970]

        let request = UNNotificationRequest(identifier: meeting.reminderKey, content: content, trigger: nil)
        center.add(request) { [logger] error in
            if let error {
                logger.error("reminder failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("reminder posted: \(meeting.reminderKey, privacy: .public)")
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        return formatter
    }()
}

extension InPersonReminder: UNUserNotificationCenterDelegate {
    /// Menu bar apps count as frontmost more often than one would expect; without this,
    /// the reminder would be swallowed whenever the menu happened to be open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Both the button and a click on the banner itself start the recording: whoever
    /// clicks a reminder that says a meeting is about to start wants it recorded.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let end = response.notification.request.content.userInfo["end"] as? Double
        completionHandler()
        guard action == Self.startActionID || action == UNNotificationDefaultActionIdentifier else { return }
        // A late click on a meeting that is already over must not start anything.
        if let end, Date().timeIntervalSince1970 >= end { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("reminder accepted: \(action, privacy: .public)")
            await self.startInPersonRecording()
        }
    }
}
