import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ScreenshotSessionStore {
    /// How a store decides which frames to write.
    struct Policy: Sendable {
        /// Write every frame (the meeting-window stream), or only frames that differ
        /// from the last written one (the full-screen stream).
        let savesOnlyChanges: Bool
        /// Side of the grayscale thumbnail the change test compares.
        let thumbnailSide: Int
        /// A frame is kept anyway after this long without one.
        let keepAliveMilliseconds: Int64
        /// The full-screen stream counts pixels that changed by more than this
        /// (0–255), so one new chat line is caught but a blinking caret is not.
        let pixelDelta: Int
        /// Mean difference (every frame) or share of changed pixels (changes only)
        /// at which a frame counts as changed.
        let threshold: Double
        let timelineIntro: String

        static let everyFrame = Policy(
            savesOnlyChanges: false,
            thumbnailSide: 32,
            keepAliveMilliseconds: 30_000,
            pixelDelta: 0,
            threshold: 0.005,
            timelineIntro: "録音中に1秒間隔で保存した画像から、画面が変化した時点と30秒ごとの画像を抽出しています。全画像は同じフォルダにあり、`index.jsonl` で撮影時刻を確認できます。"
        )

        static let changesOnly = Policy(
            savesOnlyChanges: true,
            thumbnailSide: 128,
            keepAliveMilliseconds: 60_000,
            pixelDelta: 24,
            threshold: 0.0005,
            timelineIntro: "録音中のディスプレイ全体を、画面が変化したときだけ（最短3秒おき、変化が無くても60秒に1枚）保存しています。`index.jsonl` で撮影時刻を確認できます。"
        )
    }

    private struct ScreenshotRecord: Codable {
        let capturedAt: Date
        let elapsedMilliseconds: Int64
        let file: String
        let representative: Bool
    }

    private let directoryURL: URL
    private let indexHandle: FileHandle
    private let representativesHandle: FileHandle
    private let startedAt: Date
    private let encoder: JSONEncoder
    private let policy: Policy

    private var sequence = 0
    private var representativeRecords: [ScreenshotRecord] = []
    private var lastRepresentativeThumbnail: [UInt8]?
    private var lastRepresentativeElapsedMilliseconds: Int64?
    private var isFinished = false

    init(
        sessionDirectoryURL: URL,
        folder: String = "screenshots",
        policy: Policy = .everyFrame,
        startedAt: Date = Date()
    ) throws {
        self.startedAt = startedAt
        self.policy = policy
        directoryURL = sessionDirectoryURL.appendingPathComponent(
            folder,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let indexURL = directoryURL.appendingPathComponent("index.jsonl")
        let representativesURL = directoryURL.appendingPathComponent("representatives.jsonl")
        FileManager.default.createFile(atPath: indexURL.path, contents: nil)
        FileManager.default.createFile(atPath: representativesURL.path, contents: nil)
        indexHandle = try FileHandle(forWritingTo: indexURL)
        representativesHandle = try FileHandle(forWritingTo: representativesURL)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
    }

    /// Returns whether the frame was written.
    @discardableResult
    func save(_ image: CGImage, capturedAt: Date = Date()) throws -> Bool {
        guard !isFinished else { return false }

        let elapsedMilliseconds = max(
            0,
            Int64(capturedAt.timeIntervalSince(startedAt) * 1_000)
        )
        let thumbnail = Self.grayscaleThumbnail(of: image, side: policy.thumbnailSide)
        let isRepresentative = shouldKeepAsRepresentative(
            thumbnail: thumbnail,
            elapsedMilliseconds: elapsedMilliseconds
        )
        if policy.savesOnlyChanges && !isRepresentative { return false }

        sequence += 1
        let filename = String(
            format: "%06d_%010lldms.jpg",
            sequence,
            elapsedMilliseconds
        )
        let imageURL = directoryURL.appendingPathComponent(filename)

        try Self.writeJPEG(image, to: imageURL)

        let record = ScreenshotRecord(
            capturedAt: capturedAt,
            elapsedMilliseconds: elapsedMilliseconds,
            file: filename,
            representative: isRepresentative
        )
        try append(record, to: indexHandle)

        if isRepresentative {
            representativeRecords.append(record)
            lastRepresentativeThumbnail = thumbnail
            lastRepresentativeElapsedMilliseconds = elapsedMilliseconds
            try append(record, to: representativesHandle)
        }
        return true
    }

    func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        defer {
            try? indexHandle.close()
            try? representativesHandle.close()
        }

        try writeTimeline()
        try indexHandle.synchronize()
        try representativesHandle.synchronize()
    }

    private func shouldKeepAsRepresentative(
        thumbnail: [UInt8],
        elapsedMilliseconds: Int64
    ) -> Bool {
        guard let previous = lastRepresentativeThumbnail,
              let previousElapsed = lastRepresentativeElapsedMilliseconds else {
            return true
        }

        if elapsedMilliseconds - previousElapsed >= policy.keepAliveMilliseconds {
            return true
        }

        guard previous.count == thumbnail.count, !thumbnail.isEmpty else {
            return true
        }

        if policy.pixelDelta > 0 {
            let changed = zip(previous, thumbnail).reduce(0) { result, pair in
                abs(Int(pair.0) - Int(pair.1)) > policy.pixelDelta ? result + 1 : result
            }
            return Double(changed) / Double(thumbnail.count) >= policy.threshold
        }

        let totalDifference = zip(previous, thumbnail).reduce(0) { result, pair in
            result + abs(Int(pair.0) - Int(pair.1))
        }
        let normalizedDifference = Double(totalDifference)
            / Double(thumbnail.count * 255)
        return normalizedDifference >= policy.threshold
    }

    private func append(_ record: ScreenshotRecord, to handle: FileHandle) throws {
        let data = try encoder.encode(record)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func writeTimeline() throws {
        var markdown = "# 画面記録\n\n\(policy.timelineIntro)\n"

        for record in representativeRecords {
            let elapsed = Self.elapsedLabel(milliseconds: record.elapsedMilliseconds)
            markdown += "\n## \(elapsed)\n\n![\(elapsed)](\(record.file))\n"
        }

        try markdown.write(
            to: directoryURL.appendingPathComponent("timeline.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func elapsedLabel(milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotStoreError.cannotCreateImageDestination
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotStoreError.cannotWriteImage
        }
    }

    private static func grayscaleThumbnail(of image: CGImage, side: Int) -> [UInt8] {
        let width = side
        let height = side
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return rendered ? pixels : []
    }
}

private enum ScreenshotStoreError: Error {
    case cannotCreateImageDestination
    case cannotWriteImage
}
