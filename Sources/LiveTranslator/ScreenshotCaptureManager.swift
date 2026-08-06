import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenshotCaptureManager {
    private var captureTask: Task<Void, Never>?
    private var store: ScreenshotSessionStore?

    func start(
        sessionDirectoryURL: URL,
        onFailure: @escaping @MainActor (String) -> Void
    ) async throws {
        captureTask?.cancel()

        let shareableContent = try await SCShareableContent.current
        let mainDisplayID = CGMainDisplayID()
        guard let mainDisplay = shareableContent.displays.first(where: {
            $0.displayID == mainDisplayID
        }) else {
            throw ScreenshotCaptureError.mainDisplayUnavailable
        }

        let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])
        let startedAt = Date()
        let store = try ScreenshotSessionStore(
            sessionDirectoryURL: sessionDirectoryURL,
            startedAt: startedAt
        )
        self.store = store

        let configuration = SCStreamConfiguration()
        let sourceWidth = max(1, filter.contentRect.width * CGFloat(filter.pointPixelScale))
        let sourceHeight = max(1, filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, 1_920 / max(sourceWidth, sourceHeight))
        configuration.width = Int(sourceWidth * scale)
        configuration.height = Int(sourceHeight * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: configuration
                    )
                    try await store.save(image)
                } catch is CancellationError {
                    break
                } catch {
                    onFailure(error.localizedDescription)
                    break
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
}

private enum ScreenshotCaptureError: LocalizedError {
    case mainDisplayUnavailable

    var errorDescription: String? {
        switch self {
        case .mainDisplayUnavailable:
            "メイン画面を取得できません。"
        }
    }
}
