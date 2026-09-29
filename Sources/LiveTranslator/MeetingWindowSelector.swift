import Foundation

/// What the selector needs to know about one window. Kept free of ScreenCaptureKit
/// types so the choice can be tested without screen-recording permission.
struct CaptureWindowCandidate: Equatable {
    let id: UInt32
    let bundleID: String
    let title: String
    let width: Double
    let height: Double
    let isOnScreen: Bool
    let layer: Int
}

/// Picks the window that shows the meeting, so the screenshots follow the call
/// wherever it is — on another display, or behind Slack on the main one. Recording
/// only the main display lost every shared slide whenever the meeting sat elsewhere.
enum MeetingWindowSelector {
    /// Bundle ID prefixes grouped by app. A meeting app records through helper
    /// processes (`us.zoom.caphost`, `com.google.Chrome.helper`), while the window
    /// belongs to the main app, so both sides are reduced to the same family.
    private static let families = [
        "us.zoom.",
        "com.microsoft.teams",
        "Cisco-Systems.Spark",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.",
        "com.brave.Browser",
    ]

    private static let browserFamilies: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.",
        "com.brave.Browser",
    ]

    /// A browser window counts only when its title names a meeting service. Chrome
    /// titles a Google Meet window "Meet - abc-defg-hij" while that tab is in front.
    private static let browserTitleMarks = [
        "Meet - ", "Meet – ", "Meet — ", "Google Meet",
        "Zoom", "Microsoft Teams", "Webex",
    ]

    /// Titles each meeting app gives the call window, as opposed to its main window.
    private static let appTitleMarks: [String: [String]] = [
        "us.zoom.": ["Meeting", "ミーティング", "Webinar", "ウェビナー"],
        "com.microsoft.teams": ["会議", "Meeting", "通話", "Call"],
        "Cisco-Systems.Spark": ["Webex", "Meeting", "ミーティング"],
        "com.tinyspeck.slackmacgap": ["ハドル", "Huddle"],
        "com.hnc.Discord": ["Voice", "ボイス"],
    ]

    private static let ownBundlePrefix = "com.minorun365.LiveDictation"
    private static let minimumWidth = 320.0
    private static let minimumHeight = 200.0

    static func family(of bundleID: String) -> String {
        families.first { bundleID.hasPrefix($0) } ?? bundleID
    }

    /// Main-window titles of meeting apps. Everything else the microphone app opens
    /// is taken as the call: Teams names its call window after the meeting subject
    /// ("Co-pilot課題の… | Microsoft Teams"), so no fixed word can find it.
    private static let mainWindowTitlePrefixes = [
        "チャット", "アクティビティ", "予定表", "カレンダー", "チーム", "コミュニティ",
        "OneDrive", "アプリ", "Copilot", "通話 |", "Chat", "Activity", "Calendar",
        "Teams |", "Microsoft Teams", "Zoom Workplace", "Zoom Workplace -", "Zoom",
        "Slack", "Discord", "Webex",
    ]

    private static func isUsable(_ candidate: CaptureWindowCandidate) -> Bool {
        candidate.layer == 0
            && candidate.isOnScreen
            && candidate.width >= minimumWidth
            && candidate.height >= minimumHeight
            && !candidate.title.isEmpty
            && !candidate.bundleID.hasPrefix(ownBundlePrefix)
    }

    /// Whether the title alone says this is a call window.
    static func hasMeetingTitle(_ candidate: CaptureWindowCandidate) -> Bool {
        let family = family(of: candidate.bundleID)
        if browserFamilies.contains(family) {
            return browserTitleMarks.contains { candidate.title.contains($0) }
        }
        guard let marks = appTitleMarks[family] else { return false }
        return marks.contains { candidate.title.contains($0) }
    }

    static func isMeetingWindow(
        _ candidate: CaptureWindowCandidate,
        meetingFamily: String? = nil
    ) -> Bool {
        guard isUsable(candidate) else { return false }
        if hasMeetingTitle(candidate) { return true }
        // For the app holding the microphone, any window but its main one counts.
        let family = family(of: candidate.bundleID)
        guard let meetingFamily, family == meetingFamily,
              !browserFamilies.contains(family) else { return false }
        return !mainWindowTitlePrefixes.contains { candidate.title.hasPrefix($0) }
    }

    /// Prefers the app that holds the microphone, then a title that names a call,
    /// then the newest window — a call window opens after the app's main window, and
    /// window IDs only grow — and finally the larger one.
    static func pick(
        from candidates: [CaptureWindowCandidate],
        meetingBundleID: String?
    ) -> CaptureWindowCandidate? {
        let meetingFamily = meetingBundleID.map(family(of:))
        func rank(_ window: CaptureWindowCandidate) -> (Int, Int, UInt32, Double) {
            (
                meetingFamily == family(of: window.bundleID) ? 1 : 0,
                hasMeetingTitle(window) ? 1 : 0,
                window.id,
                window.width * window.height
            )
        }
        return candidates
            .filter { isMeetingWindow($0, meetingFamily: meetingFamily) }
            .max { rank($0) < rank($1) }
    }
}
