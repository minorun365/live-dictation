import Foundation

/// A meeting held in a room rather than on a call, read from a file that some other
/// tool keeps up to date.
///
/// The app does not talk to any calendar service itself. Calendars need an account and
/// credentials, and which events count as "in person" depends on how each person fills
/// in their calendar, so both stay outside the app: a separate job writes the list, and
/// the app only decides when to remind.
struct InPersonMeeting: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let location: String?

    /// The same event can move to another time. Keying reminders on the start as well
    /// means a rescheduled meeting is reminded again at its new time.
    var reminderKey: String {
        "\(id)@\(Int(start.timeIntervalSince1970))"
    }
}

/// The file the reminder reads. `fetchedAt` tells the reader whether the list is still
/// being refreshed; a list that has stopped updating would quietly miss new meetings.
struct InPersonMeetingFeed: Codable, Sendable {
    let fetchedAt: Date?
    let meetings: [InPersonMeeting]
    let lastError: String?
    let lastErrorAt: Date?

    static let fileName = "InPersonMeetings.json"

    static func load(from url: URL) throws -> InPersonMeetingFeed {
        let data = try Data(contentsOf: url)
        return try decoder.decode(InPersonMeetingFeed.self, from: data)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // The writer uses local offsets such as "+09:00", with or without fractions.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            for formatter in isoFormatters {
                if let date = formatter.date(from: text) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "日時として読めません: \(text)"
            )
        }
        return decoder
    }()

    // ISO8601DateFormatter is safe to read from any thread once configured.
    nonisolated(unsafe) private static let isoFormatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()
}

/// Decides which meetings to remind about right now. Kept free of timers and
/// notifications so the rules can be checked on their own.
enum InPersonReminderRule {
    /// Five minutes is enough to open the lid, pick the Mac up and still be seated
    /// before the meeting starts.
    static let leadTime: TimeInterval = 5 * 60

    /// A list older than this has stopped refreshing. The writer runs every few
    /// minutes, so half an hour covers a sleeping Mac catching up without crying wolf.
    static let staleAfter: TimeInterval = 30 * 60

    /// Meetings whose reminder window is open and that have not been reminded yet.
    ///
    /// The window runs from `leadTime` before the start until the meeting ends, so a
    /// Mac that was asleep at the five-minute mark still reminds once it wakes, as long
    /// as the meeting is still going.
    static func due(
        _ meetings: [InPersonMeeting],
        at now: Date,
        alreadyReminded: Set<String>
    ) -> [InPersonMeeting] {
        meetings
            .filter { meeting in
                now >= meeting.start.addingTimeInterval(-leadTime)
                    && now < meeting.end
                    && !alreadyReminded.contains(meeting.reminderKey)
            }
            .sorted { $0.start < $1.start }
    }

    /// Meetings overrun. A recording the app started for a meeting keeps going this
    /// long past the scheduled end before the app stops it.
    static let autoStopGrace: TimeInterval = 10 * 60

    /// How long before the automatic stop the "about to stop" notice appears, leaving
    /// time to keep the recording going.
    static let stopNoticeLead: TimeInterval = 2 * 60

    /// The meeting whose recording should start by itself now, for those who turned
    /// automatic recording on. It shares the reminder's window — `leadTime` before the
    /// start until the end — so the reminder and the automatic start never drift apart,
    /// and a Mac that wakes mid-meeting still catches it.
    static func dueForAutoStart(
        _ meetings: [InPersonMeeting],
        at now: Date,
        alreadyStarted: Set<String>
    ) -> InPersonMeeting? {
        meetings
            .filter { meeting in
                now >= meeting.start.addingTimeInterval(-leadTime)
                    && now < meeting.end
                    && !alreadyStarted.contains(meeting.reminderKey)
            }
            .min { $0.start < $1.start }
    }

    enum StopStep: Equatable {
        case keepRecording
        case notice
        case stop
    }

    /// What to do with a recording the app started for `meeting`.
    static func stopStep(for meeting: InPersonMeeting, at now: Date) -> StopStep {
        let stopAt = meeting.end.addingTimeInterval(autoStopGrace)
        if now >= stopAt { return .stop }
        if now >= stopAt.addingTimeInterval(-stopNoticeLead) { return .notice }
        return .keepRecording
    }

    /// The next moment something may happen: the reminder or automatic start, the
    /// meeting's end, the stop notice or the stop. The reminder schedules a timer for
    /// exactly this moment, because a menu bar app that is out of sight gets its
    /// repeating timers delayed by App Nap — by about a minute in practice.
    static func nextMark(_ meetings: [InPersonMeeting], after now: Date) -> Date? {
        meetings
            .flatMap { meeting in
                let stopAt = meeting.end.addingTimeInterval(autoStopGrace)
                return [
                    meeting.start.addingTimeInterval(-leadTime),
                    meeting.end,
                    stopAt.addingTimeInterval(-stopNoticeLead),
                    stopAt,
                ]
            }
            .filter { $0 > now }
            .min()
    }

    static func isStale(_ feed: InPersonMeetingFeed, at now: Date) -> Bool {
        guard let fetchedAt = feed.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > staleAfter
    }
}
