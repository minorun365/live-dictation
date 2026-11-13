import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// The second screen record: every display, one image per display, saved only when
/// that display changed (at most every 3 seconds) into `screens/display-N/`.
///
/// The meeting-window record follows the call, so it misses what sits outside it —
/// a chat in its own window, the slides being shared, notes in another app. This one
/// keeps whatever was visible on the displays. Windows of the apps in
/// `CaptureExclusion` are cut out before the image is taken, and every image stays
/// in the session folder on this Mac.
@MainActor
final class FullScreenCaptureManager {
    private var captureTask: Task<Void, Never>?

    static let intervalSeconds = 3
    /// Each display keeps its own resolution instead of sharing one wide image, so
    /// small chat text stays readable.
    private static let longSide: CGFloat = 1_920
    private static let maximumConsecutiveFailures = 5

    func start(
        sessionDirectoryURL: URL,
        onDisplaysChange: @escaping @MainActor ([String: String]) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) async throws {
        captureTask?.cancel()

        // Fails the start when screen recording is not allowed.
        _ = try await Self.shareableContent()
        let startedAt = Date()

        captureTask = Task {
            var stores: [CGDirectDisplayID: ScreenshotSessionStore] = [:]
            var reportedDisplays: [String: String]?
            var failures = 0

            while !Task.isCancelled {
                do {
                    let content = try await Self.shareableContent()
                    let displays = content.displays.sorted { $0.frame.minX < $1.frame.minX }
                    guard !displays.isEmpty else { throw FullScreenCaptureError.noDisplay }
                    let excluded = content.applications.filter {
                        CaptureExclusion.isExcluded(bundleID: $0.bundleIdentifier)
                    }

                    for display in displays where stores[display.displayID] == nil {
                        // Numbered in the order the displays first appeared, so a
                        // display plugged in mid-meeting gets the next number.
                        stores[display.displayID] = try ScreenshotSessionStore(
                            sessionDirectoryURL: sessionDirectoryURL,
                            folder: "screens/display-\(stores.count + 1)",
                            policy: .changesOnly,
                            startedAt: startedAt
                        )
                    }

                    let description = Self.describe(displays, excluded: excluded)
                    if description != reportedDisplays {
                        reportedDisplays = description
                        onDisplaysChange(description)
                    }

                    for display in displays {
                        guard let store = stores[display.displayID] else { continue }
                        let image = try await Self.capture(display, excluding: excluded)
                        try await store.save(image)
                    }
                    failures = 0
                } catch is CancellationError {
                    break
                } catch {
                    failures += 1
                    if failures >= Self.maximumConsecutiveFailures {
                        onFailure(error.localizedDescription)
                        break
                    }
                }

                do {
                    try await Task.sleep(for: .seconds(Self.intervalSeconds))
                } catch {
                    break
                }
            }

            for store in stores.values {
                try? await store.finish()
            }
        }
    }

    func stop() async {
        guard let captureTask else { return }
        captureTask.cancel()
        await captureTask.value
        self.captureTask = nil
    }

    private static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    private static func describe(
        _ displays: [SCDisplay],
        excluded: [SCRunningApplication]
    ) -> [String: String] {
        [
            "displays": String(displays.count),
            "sizes": displays
                .map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
                .joined(separator: ","),
            "excluded_apps_running": excluded.map(\.bundleIdentifier).sorted().joined(separator: ","),
        ]
    }

    static func capture(
        _ display: SCDisplay,
        excluding excluded: [SCRunningApplication]
    ) async throws -> CGImage {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )
        let width = max(1, filter.contentRect.width * CGFloat(filter.pointPixelScale))
        let height = max(1, filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, longSide / max(width, height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(width * scale))
        configuration.height = max(1, Int(height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

private enum FullScreenCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        "画面を取得できません。"
    }
}
