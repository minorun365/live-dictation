import CoreGraphics
import Foundation

/// The full-screen stream writes a frame only when the screen changed: a new line of
/// text counts, a one-pixel caret does not, and a still screen still gets a frame
/// once a minute.
@main
struct ScreenChangeStoreSelfTest {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-change-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let startedAt = Date(timeIntervalSince1970: 100)
        let store = try ScreenshotSessionStore(
            sessionDirectoryURL: root,
            folder: "screens/display-1",
            policy: .changesOnly,
            startedAt: startedAt
        )
        let blank = try makeImage()
        let caret = try makeImage { context in
            context.fill(CGRect(x: 900, y: 500, width: 2, height: 16))
        }
        let chatLine = try makeImage { context in
            for x in stride(from: 1_400, to: 1_800, by: 6) {
                context.fill(CGRect(x: x, y: 300, width: 4, height: 14))
            }
        }

        let results = [
            try await store.save(blank, capturedAt: startedAt),
            try await store.save(blank, capturedAt: startedAt.addingTimeInterval(3)),
            try await store.save(caret, capturedAt: startedAt.addingTimeInterval(6)),
            try await store.save(chatLine, capturedAt: startedAt.addingTimeInterval(9)),
            try await store.save(chatLine, capturedAt: startedAt.addingTimeInterval(12)),
            try await store.save(chatLine, capturedAt: startedAt.addingTimeInterval(70)),
        ]
        try await store.finish()

        check(results == [true, false, false, true, false, true], "変化した時と60秒ごとだけ保存する: \(results)")
        let folder = root.appendingPathComponent("screens/display-1")
        let jpegs = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".jpg") }
        check(jpegs.count == 3, "保存した画像は3枚: \(jpegs.count)")
        let timeline = try String(contentsOf: folder.appendingPathComponent("timeline.md"), encoding: .utf8)
        check(timeline.contains("000002_0000009000ms.jpg"), "timeline に変化した時点が載る")
        print("ScreenChangeStoreSelfTest passed")
    }

    /// A white 1,920×1,080 screen with black marks drawn on it.
    private static func makeImage(draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: 1_920, height: 1_080, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { fatalError("context") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        context.setFillColor(gray: 0, alpha: 1)
        draw(context)
        guard let image = context.makeImage() else { fatalError("image") }
        return image
    }

    private static func check(_ condition: Bool, _ label: String) {
        if !condition {
            print("FAILED: \(label)")
            exit(1)
        }
    }
}
