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

    static func isMeetingWindow(_ candidate: CaptureWindowCandidate) -> Bool {
        guard candidate.layer == 0,
              candidate.isOnScreen,
              candidate.width >= minimumWidth,
              candidate.height >= minimumHeight,
              !candidate.title.isEmpty,
              !candidate.bundleID.hasPrefix(ownBundlePrefix) else {
            return false
        }
        let family = family(of: candidate.bundleID)
        if browserFamilies.contains(family) {
            return browserTitleMarks.contains { candidate.title.contains($0) }
        }
        guard let marks = appTitleMarks[family] else { return false }
        return marks.contains { candidate.title.contains($0) }
    }

    /// Prefers the app that holds the microphone, then the larger window, since the
    /// call window is usually the big one and a stray small one is a preview.
    static func pick(
        from candidates: [CaptureWindowCandidate],
        meetingBundleID: String?
    ) -> CaptureWindowCandidate? {
        let meetingFamily = meetingBundleID.map(family(of:))
        return candidates
            .filter(isMeetingWindow)
            .max { lhs, rhs in
                let lhsMatches = meetingFamily == family(of: lhs.bundleID)
                let rhsMatches = meetingFamily == family(of: rhs.bundleID)
                if lhsMatches != rhsMatches { return !lhsMatches }
                return lhs.width * lhs.height < rhs.width * rhs.height
            }
    }
}
