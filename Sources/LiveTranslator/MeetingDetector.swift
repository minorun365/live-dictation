import CoreAudio
import Foundation

/// Watches which applications are using the microphone and reports when a meeting
/// starts or ends.
///
/// Looking at the microphone device alone is not enough: dictation tools hold the
/// microphone all day, so every dictation would look like a meeting. macOS 14.2 added
/// per-process audio properties, which tell us *who* is recording, and that is what
/// separates a meeting from dictation.
@MainActor
final class MeetingDetector {
    enum State: Equatable {
        case idle
        case meeting(bundleID: String)
    }

    /// Apps whose microphone use always means a meeting.
    ///
    /// Matched by prefix on purpose. A meeting app spreads its audio over helper
    /// processes with their own bundle IDs — Zoom records through `us.zoom.caphost`
    /// rather than `us.zoom.xos`, and Slack through `…slackmacgap.helper` — so exact
    /// matching would miss the very process holding the microphone.
    private static let meetingPrefixes = [
        "us.zoom.",                   // Zoom
        "com.microsoft.teams",        // Teams
        "Cisco-Systems.Spark",        // Webex
        "com.tinyspeck.slackmacgap",  // Slack huddles
        "com.hnc.Discord",            // Discord
    ]

    /// Browsers count as a meeting only while they both record and play audio, which
    /// is what separates a Google Meet call from a page that merely uses the microphone.
    private static let browserPrefixes = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
    ]

    /// Apps to ignore even when they record.
    ///
    /// This app must stay on the list: without it, starting a recording would register
    /// as microphone use and the detector would keep re-triggering on itself.
    private static let ignoredPrefixes = [
        "com.minorun365.LiveDictation",  // this app
        "com.electron.aqua-voice",       // dictation
        "aquavoice.",                    // dictation helper
        "com.apple.CoreSpeech",          // system speech recognition
        "com.apple.SiriNCService",       // Siri
        "com.apple.audio",               // Core Audio services
    ]

    /// A meeting app can drop the microphone briefly — muting inside the app is enough
    /// on some clients — so wait this long before calling the meeting over. Stopping on
    /// the first quiet moment would split one meeting into several recordings.
    private let stopGraceInterval: TimeInterval = 60

    /// The listener fires as soon as the process list changes, and this poll is the
    /// backstop that also drives the grace period countdown.
    private let pollInterval: TimeInterval = 10

    private(set) var state: State = .idle
    var onChange: ((State) -> Void)?

    private var timer: Timer?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var lastSeenActiveAt: Date?

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }

        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.evaluate() }
        }
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        ) == noErr {
            listenerBlock = block
        }

        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        self.timer = timer
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let listenerBlock {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listenerBlock
            )
            self.listenerBlock = nil
        }
        lastSeenActiveAt = nil
        state = .idle
    }

    // MARK: - Detection

    private func evaluate() {
        let active = activeMeetingBundleID()

        if let active {
            lastSeenActiveAt = Date()
            if state == .idle {
                transition(to: .meeting(bundleID: active))
            }
            return
        }

        guard case .meeting = state else { return }
        let quietSince = lastSeenActiveAt ?? Date()
        if Date().timeIntervalSince(quietSince) >= stopGraceInterval {
            transition(to: .idle)
        }
    }

    private func transition(to next: State) {
        guard state != next else { return }
        state = next
        onChange?(next)
    }

    /// Returns the bundle ID of an app that currently looks like a meeting, if any.
    private func activeMeetingBundleID() -> String? {
        for process in Self.processObjects() {
            guard let bundleID = Self.stringProperty(process, kAudioProcessPropertyBundleID),
                  !bundleID.isEmpty,
                  !Self.matches(bundleID, Self.ignoredPrefixes),
                  Self.boolProperty(process, kAudioProcessPropertyIsRunningInput) == true
            else { continue }

            if Self.matches(bundleID, Self.meetingPrefixes) {
                return bundleID
            }
            // A browser needs playback too, otherwise a page using the microphone for
            // dictation or a voice memo would start a recording.
            if Self.matches(bundleID, Self.browserPrefixes),
               Self.boolProperty(process, kAudioProcessPropertyIsRunningOutput) == true {
                return bundleID
            }
        }
        return nil
    }

    private static func matches(_ bundleID: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { bundleID.hasPrefix($0) }
    }

    // MARK: - Core Audio plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var propertyAddress = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &propertyAddress, 0, nil, &size) == noErr,
              size > 0
        else { return [] }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &propertyAddress, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    private static func stringProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var propertyAddress = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func boolProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> Bool? {
        var propertyAddress = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &propertyAddress, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }
}
