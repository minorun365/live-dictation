import AppKit
import Foundation
import OSLog
@preconcurrency import UserNotifications

/// Looks after in-person meetings, which give the app no signal of their own.
///
/// Five minutes before one starts, a reminder offers a button that starts the
/// in-person recording right then. With automatic recording turned on in the menu,
/// that same five-minute mark starts the recording by itself instead of offering the
/// button, and a recording started for a meeting stops ten minutes after the scheduled
/// end, with a notice two minutes earlier that can keep it going.
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

    /// The menu toggle writes this key. Off by default: the reminder and its button
    /// are the standard behaviour, and recording a room without anyone pressing a
    /// button is something each user opts into. The automatic stop belongs to the same
    /// switch, so with it off a recording started from the reminder runs until it is
    /// stopped by hand, as it always has.
    nonisolated static let autoStartDefaultsKey = "inPersonAutoStart"

    private let feedURL: URL
    private let isRecording: () -> Bool
    private let startInPersonRecording: () async -> Void
    private let stopRecording: () -> Void
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.minorun365.LiveDictation", category: "InPersonReminder")

    private var timer: Timer?
    /// Fires at the next mark exactly. The 20-second poll alone ran about a minute
    /// late in a real meeting: the reminder came 3:56 before the start, not 5:00.
    private var markTimer: Timer?
    /// Held in the few minutes before a mark so App Nap does not defer the timer.
    private var napGuard: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var meetings: [InPersonMeeting] = []
    private var feedModifiedAt: Date?
    private var reminded: Set<String> = []
    /// Meetings already started once, by hand or by the app. A recording stopped by
    /// hand stays stopped: starting it again would overrule a deliberate choice.
    private var started: Set<String> = []
    /// The meeting the current recording was started for. Only these recordings are
    /// stopped automatically; one started by the web-meeting detector or from the
    /// menu is left alone.
    private var recordingFor: InPersonMeeting?
    private var stopNoticed: Set<String> = []
    private var keepGoing: Set<String> = []

    nonisolated private static let categoryID = "inPersonMeeting"
    nonisolated private static let startActionID = "startInPersonRecording"
    nonisolated private static let startedCategoryID = "inPersonRecordingStarted"
    nonisolated private static let stopActionID = "stopInPersonRecording"
    nonisolated private static let stopSoonCategoryID = "inPersonRecordingStopSoon"
    nonisolated private static let keepActionID = "keepInPersonRecording"
    /// A fallback for the exact mark timer; it has to stay well under a minute.
    private static let pollInterval: TimeInterval = 20

    init(
        isRecording: @escaping () -> Bool,
        startInPersonRecording: @escaping () async -> Void,
        stopRecording: @escaping () -> Void
    ) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        feedURL = support
            .appendingPathComponent("LiveTranslator", isDirectory: true)
            .appendingPathComponent(InPersonMeetingFeed.fileName)
        self.isRecording = isRecording
        self.startInPersonRecording = startInPersonRecording
        self.stopRecording = stopRecording
        super.init()
    }

    private var autoStartEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.autoStartDefaultsKey)
    }

    func start() {
        guard timer == nil else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [UNNotificationAction(identifier: Self.startActionID, title: "対面で録音開始", options: [])],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.startedCategoryID,
                actions: [UNNotificationAction(identifier: Self.stopActionID, title: "録音を止める", options: [])],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: Self.stopSoonCategoryID,
                actions: [UNNotificationAction(identifier: Self.keepActionID, title: "録音を続ける", options: [])],
                intentIdentifiers: [],
                options: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [logger] granted, error in
            logger.info("notification authorization granted=\(granted, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // A timer does not fire while the Mac sleeps. Checking on wake means a meeting
        // whose mark passed with the lid closed is still handled as soon as the lid
        // opens.
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
            center.removeDeliveredNotifications(withIdentifiers: meetings.map(\.reminderKey))
        }
        evaluate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        let now = Date()
        defer { scheduleNextMark(after: now) }
        reloadFeedIfChanged(now: now)
        withdrawEndedReminders(now: now)

        if isRecording() {
            // While something is recording — typically the web meeting just before — a
            // banner would only show up on a shared screen. Hold it until that ends.
            if let meeting = recordingFor {
                handleStop(of: meeting, at: now)
            }
            return
        }
        recordingFor = nil

        // With automatic recording on, the five-minute mark starts the recording
        // instead of offering a button for it; the "recording started" notice that
        // follows takes the reminder's place.
        if autoStartEnabled {
            if let meeting = InPersonReminderRule.dueForAutoStart(meetings, at: now, alreadyStarted: started) {
                reminded.insert(meeting.reminderKey)
                Task { await self.record(meeting, automatically: true) }
            }
            return
        }

        for meeting in InPersonReminderRule.due(meetings, at: now, alreadyReminded: reminded) {
            reminded.insert(meeting.reminderKey)
            post(meeting)
        }
    }

    private func scheduleNextMark(after now: Date) {
        markTimer?.invalidate()
        markTimer = nil
        guard let mark = InPersonReminderRule.nextMark(meetings, after: now) else {
            releaseNapGuard()
            return
        }
        // A hair past the mark, so the check that runs sees the mark as reached.
        let timer = Timer(fire: mark.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        markTimer = timer

        if mark.timeIntervalSince(now) <= Self.napGuardLead {
            if napGuard == nil {
                napGuard = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "対面会議の通知と録音を時刻どおりに行うため"
                )
            }
        } else {
            releaseNapGuard()
        }
    }

    private func releaseNapGuard() {
        guard let napGuard else { return }
        ProcessInfo.processInfo.endActivity(napGuard)
        self.napGuard = nil
    }

    /// Long enough to cover the run-up to a mark, short enough that the app naps
    /// normally the rest of the day.
    private static let napGuardLead: TimeInterval = 6 * 60

    private func record(_ meeting: InPersonMeeting, automatically: Bool) async {
        guard !isRecording(), !started.contains(meeting.reminderKey) else { return }
        started.insert(meeting.reminderKey)
        recordingFor = meeting
        logger.info("starting for \(meeting.reminderKey, privacy: .public) automatic=\(automatically, privacy: .public)")
        await startInPersonRecording()
        guard isRecording() else {
            recordingFor = nil
            return
        }
        if automatically {
            notify(
                id: "started-\(meeting.reminderKey)",
                title: "「\(meeting.title)」の録音を始めました",
                body: "対面モード。終了予定の10分後に自動で止めます",
                category: Self.startedCategoryID
            )
        }
    }

    private func handleStop(of meeting: InPersonMeeting, at now: Date) {
        guard autoStartEnabled, !keepGoing.contains(meeting.reminderKey) else { return }
        switch InPersonReminderRule.stopStep(for: meeting, at: now) {
        case .keepRecording:
            break
        case .notice:
            guard !stopNoticed.contains(meeting.reminderKey) else { return }
            stopNoticed.insert(meeting.reminderKey)
            notify(
                id: "stop-soon-\(meeting.reminderKey)",
                title: "まもなく「\(meeting.title)」の録音を止めます",
                body: "終了予定を過ぎています。続けるなら「録音を続ける」を押してください",
                category: Self.stopSoonCategoryID
            )
        case .stop:
            logger.info("auto stop for \(meeting.reminderKey, privacy: .public)")
            recordingFor = nil
            center.removeDeliveredNotifications(withIdentifiers: [
                "started-\(meeting.reminderKey)", "stop-soon-\(meeting.reminderKey)",
            ])
            stopRecording()
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
        var body = "\(Self.timeFormatter.string(from: meeting.start))〜\(Self.timeFormatter.string(from: meeting.end))"
        if let location = meeting.location, !location.isEmpty {
            body += "　\(location)"
        }
        notify(
            id: meeting.reminderKey,
            title: "まもなく「\(meeting.title)」",
            body: body,
            category: Self.categoryID,
            userInfo: ["key": meeting.reminderKey]
        )
    }

    private func notify(id: String, title: String, body: String, category: String, userInfo: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { [logger] error in
            if let error {
                logger.error("notification failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("notification posted: \(id, privacy: .public)")
            }
        }
    }

    fileprivate func handleResponse(category: String, action: String, key: String?) {
        switch (category, action) {
        case (Self.categoryID, Self.startActionID), (Self.categoryID, UNNotificationDefaultActionIdentifier):
            // Both the button and a click on the banner itself start the recording:
            // whoever clicks a reminder that says a meeting is about to start wants it
            // recorded. A late click on a meeting that is already over starts nothing.
            guard let meeting = meetings.first(where: { $0.reminderKey == key }), Date() < meeting.end else { return }
            logger.info("reminder accepted: \(action, privacy: .public)")
            Task { await self.record(meeting, automatically: false) }
        case (Self.startedCategoryID, Self.stopActionID):
            guard recordingFor != nil else { return }
            recordingFor = nil
            stopRecording()
        case (Self.stopSoonCategoryID, Self.keepActionID):
            if let meeting = recordingFor {
                keepGoing.insert(meeting.reminderKey)
            }
        default:
            // The same delegate receives the transcript-ready banner; clicking that one
            // must not start or stop anything.
            break
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let key = response.notification.request.content.userInfo["key"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            self?.handleResponse(category: category, action: action, key: key)
        }
    }
}
