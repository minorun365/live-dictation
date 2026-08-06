import AppKit
import Foundation
@preconcurrency import ScreenCaptureKit

struct SelectedScreenContent: @unchecked Sendable {
    let filter: SCContentFilter
}

@MainActor
final class ScreenshotCaptureManager: NSObject {
    private let picker = SCContentSharingPicker.shared
    private var selectionContinuation: CheckedContinuation<SelectedScreenContent?, Never>?
    private var captureTask: Task<Void, Never>?
    private var store: ScreenshotSessionStore?

    func selectContent() async -> SelectedScreenContent? {
        guard selectionContinuation == nil else { return nil }

        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleIdentifier]
        }

        picker.defaultConfiguration = configuration
        picker.maximumStreamCount = 1
        picker.add(self)
        picker.isActive = true

        return await withCheckedContinuation { continuation in
            selectionContinuation = continuation
            picker.present()
        }
    }

    func start(
        filter: SCContentFilter,
        sessionDirectoryURL: URL,
        onFailure: @escaping @MainActor (String) -> Void
    ) throws {
        captureTask?.cancel()

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

    private func finishSelection(with filter: SCContentFilter?) {
        guard let continuation = selectionContinuation else { return }
        selectionContinuation = nil
        picker.remove(self)
        picker.isActive = false
        continuation.resume(returning: filter.map(SelectedScreenContent.init))
    }
}

extension ScreenshotCaptureManager: @preconcurrency SCContentSharingPickerObserver {
    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        finishSelection(with: nil)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        finishSelection(with: filter)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finishSelection(with: nil)
    }
}
