import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Saves a screenshot every second while recording.
///
/// The meeting window is captured on its own when it can be found, so the shared
/// slides and participant names are kept even when the call sits on another display
/// or behind other windows. Until a meeting window shows up (a hand-started recording,
/// a minimized call, a Meet tab sent to the background), every display is captured
/// side by side in one image instead.
@MainActor
final class ScreenshotCaptureManager {
    private var captureTask: Task<Void, Never>?
    private var store: ScreenshotSessionStore?

    /// How often the target is chosen again. The call window can move, close, or be
    /// replaced by a new one, and re-listing windows every frame would be wasteful.
    private static let retargetInterval: TimeInterval = 5
    private static let maximumConsecutiveFailures = 5

    func start(
        sessionDirectoryURL: URL,
        meetingBundleID: String?,
        onTargetChange: @escaping @MainActor ([String: String]) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) async throws {
        captureTask?.cancel()

        // Resolve once up front so a missing permission fails the start, as before.
        let firstTarget = try await Self.resolveTarget(meetingBundleID: meetingBundleID)
        let store = try ScreenshotSessionStore(
            sessionDirectoryURL: sessionDirectoryURL,
            startedAt: Date()
        )
        self.store = store

        captureTask = Task { [weak self] in
            var target: CaptureTarget? = firstTarget
            var resolvedAt = Date()
            var reportedDescription: [String: String]?
            var failures = 0

            while !Task.isCancelled {
                do {
                    if target == nil
                        || Date().timeIntervalSince(resolvedAt) >= Self.retargetInterval {
                        target = try await Self.resolveTarget(meetingBundleID: meetingBundleID)
                        resolvedAt = Date()
                    }
                    if let current = target {
                        if current.description != reportedDescription {
                            reportedDescription = current.description
                            onTargetChange(current.description)
                        }
                        let image = try await current.capture()
                        try await store.save(image)
                        failures = 0
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // A closed window or a display that went away is not fatal: choose
                    // again on the next frame. Give up only when nothing can be captured.
                    failures += 1
                    target = nil
                    if failures >= Self.maximumConsecutiveFailures {
                        onFailure(error.localizedDescription)
                        break
                    }
                }

                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }

            try? await store.finish()
            self?.store = nil
        }
    }

    func stop() async {
        guard let captureTask else { return }
        captureTask.cancel()
        await captureTask.value
        self.captureTask = nil
        store = nil
    }

    private static func resolveTarget(meetingBundleID: String?) async throws -> CaptureTarget {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: false
        )
        let candidates = content.windows.map { window in
            CaptureWindowCandidate(
                id: window.windowID,
                bundleID: window.owningApplication?.bundleIdentifier ?? "",
                title: window.title ?? "",
                width: window.frame.width,
                height: window.frame.height,
                isOnScreen: window.isOnScreen,
                layer: window.windowLayer
            )
        }
        if let picked = MeetingWindowSelector.pick(
            from: candidates,
            meetingBundleID: meetingBundleID
        ), let window = content.windows.first(where: { $0.windowID == picked.id }) {
            return .window(window)
        }

        let displays = content.displays.sorted { $0.frame.minX < $1.frame.minX }
        guard !displays.isEmpty else { throw ScreenshotCaptureError.noDisplay }
        return .displays(displays)
    }
}

private enum CaptureTarget {
    case window(SCWindow)
    case displays([SCDisplay])

    /// Long side of a saved frame. The composite of several displays gets more room
    /// so each display stays readable once they share one image.
    private static let windowLongSide: CGFloat = 1_920
    private static let displaysLongSide: CGFloat = 2_880

    var description: [String: String] {
        switch self {
        case .window(let window):
            [
                "target": "meeting_window",
                "app": window.owningApplication?.bundleIdentifier ?? "",
                "title": window.title ?? "",
            ]
        case .displays(let displays):
            [
                "target": "all_displays",
                "displays": String(displays.count),
            ]
        }
    }

    func capture() async throws -> CGImage {
        switch self {
        case .window(let window):
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = Self.pixelSize(of: filter)
            let configuration = Self.configuration(
                size: size,
                scale: min(1, Self.windowLongSide / max(size.width, size.height))
            )
            configuration.ignoreShadowsSingleWindow = true
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        case .displays(let displays):
            return try await Self.captureSideBySide(displays)
        }
    }

    private static func pixelSize(of filter: SCContentFilter) -> CGSize {
        CGSize(
            width: max(1, filter.contentRect.width * CGFloat(filter.pointPixelScale)),
            height: max(1, filter.contentRect.height * CGFloat(filter.pointPixelScale))
        )
    }

    private static func configuration(size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(size.width * scale))
        configuration.height = max(1, Int(size.height * scale))
        configuration.showsCursor = false
        configuration.captureResolution = .best
        return configuration
    }

    /// Lays the displays out left to right in one image, top-aligned, so each saved
    /// frame still stands for the whole screen at one moment.
    private static func captureSideBySide(_ displays: [SCDisplay]) async throws -> CGImage {
        let filters = displays.map { SCContentFilter(display: $0, excludingWindows: []) }
        let sizes = filters.map(pixelSize(of:))
        let totalWidth = sizes.reduce(0) { $0 + $1.width }
        let maxHeight = sizes.map(\.height).max() ?? 1
        let scale = min(1, displaysLongSide / max(totalWidth, maxHeight))

        var images: [CGImage] = []
        for (filter, size) in zip(filters, sizes) {
            images.append(
                try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration(size: size, scale: scale)
                )
            )
        }
        if images.count == 1 { return images[0] }

        let width = images.reduce(0) { $0 + $1.width }
        let height = images.map(\.height).max() ?? 1
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ScreenshotCaptureError.cannotCompose
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var x = 0
        for image in images {
            // Core Graphics draws from the bottom, so top alignment starts at the top edge.
            context.draw(image, in: CGRect(
                x: x,
                y: height - image.height,
                width: image.width,
                height: image.height
            ))
            x += image.width
        }
        guard let composed = context.makeImage() else {
            throw ScreenshotCaptureError.cannotCompose
        }
        return composed
    }
}

private enum ScreenshotCaptureError: LocalizedError {
    case noDisplay
    case cannotCompose

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "画面を取得できません。"
        case .cannotCompose:
            "画面の画像を合成できません。"
        }
    }
}
