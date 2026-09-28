import Foundation

@main
struct InPersonScheduleSelfTest {
    static func main() throws {
        let json = """
        {"fetchedAt":"2026-09-28T16:00:00+09:00","meetings":[
          {"id":"a","title":"相談","start":"2026-09-28T16:30:00+09:00","end":"2026-09-28T17:00:00+09:00","location":"会議室A","reason":"会議室"},
          {"id":"b","title":"1on1","start":"2026-09-28T18:00:00.000+09:00","end":"2026-09-28T18:30:00+09:00"}
        ]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let feed = try InPersonMeetingFeed.load(from: url)
        try check(feed.meetings.count == 2, "2件読める")
        try check(feed.meetings[1].location == nil, "location が無くても読める")
        let a = feed.meetings[0]
        let at = { (hhmm: String) -> Date in
            ISO8601DateFormatter().date(from: "2026-09-28T\(hhmm):00+09:00")!
        }

        try check(InPersonReminderRule.due(feed.meetings, at: at("16:24"), alreadyReminded: []).isEmpty, "6分前は出さない")
        try check(InPersonReminderRule.due(feed.meetings, at: at("16:25"), alreadyReminded: []).map(\.id) == ["a"], "5分前ちょうどに出す")
        try check(InPersonReminderRule.due(feed.meetings, at: at("16:45"), alreadyReminded: []).map(\.id) == ["a"], "寝ていて過ぎても会議中なら出す")
        try check(InPersonReminderRule.due(feed.meetings, at: at("17:00"), alreadyReminded: []).isEmpty, "終わった会議は出さない")
        try check(InPersonReminderRule.due(feed.meetings, at: at("16:26"), alreadyReminded: [a.reminderKey]).isEmpty, "一度出したら出さない")

        let moved = InPersonMeeting(id: "a", title: "相談", start: at("16:40"), end: at("17:10"), location: nil)
        try check(moved.reminderKey != a.reminderKey, "時間が変わったら出し直す")

        try check(!InPersonReminderRule.isStale(feed, at: at("16:29")), "29分後はまだ新しい")
        try check(InPersonReminderRule.isStale(feed, at: at("16:31")), "31分後は止まっている扱い")
        print("InPersonScheduleSelfTest OK")
    }

    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw TestFailure(label: label) }
    }

    struct TestFailure: Error, CustomStringConvertible {
        let label: String
        var description: String { "NG: \(label)" }
    }
}
