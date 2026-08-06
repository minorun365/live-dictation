import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ScreenshotSessionStore {
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

    private var sequence = 0
    private var representativeRecords: [ScreenshotRecord] = []
    private var lastRepresentativeThumbnail: [UInt8]?
    private var lastRepresentativeElapsedMilliseconds: Int64?
    private var isFinished = false

    init(sessionDirectoryURL: URL, startedAt: Date = Date()) throws {
        self.startedAt = startedAt
        directoryURL = sessionDirectoryURL.appendingPathComponent(
            "screenshots",
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

    func save(_ image: CGImage, capturedAt: Date = Date()) throws {
        guard !isFinished else { return }

        sequence += 1
        let elapsedMilliseconds = max(
            0,
            Int64(capturedAt.timeIntervalSince(startedAt) * 1_000)
        )
        let filename = String(
            format: "%06d_%010lldms.jpg",
            sequence,
            elapsedMilliseconds
        )
        let imageURL = directoryURL.appendingPathComponent(filename)

        try Self.writeJPEG(image, to: imageURL)

        let thumbnail = Self.grayscaleThumbnail(of: image)
        let isRepresentative = shouldKeepAsRepresentative(
            thumbnail: thumbnail,
            elapsedMilliseconds: elapsedMilliseconds
        )
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

        if elapsedMilliseconds - previousElapsed >= 30_000 {
            return true
        }

        guard previous.count == thumbnail.count, !thumbnail.isEmpty else {
            return true
        }

        let totalDifference = zip(previous, thumbnail).reduce(0) { result, pair in
            result + abs(Int(pair.0) - Int(pair.1))
        }
        let normalizedDifference = Double(totalDifference)
            / Double(thumbnail.count * 255)
        return normalizedDifference >= 0.005
    }

    private func append(_ record: ScreenshotRecord, to handle: FileHandle) throws {
        let data = try encoder.encode(record)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private func writeTimeline() throws {
        var markdown = """
        # 画面記録

        録音中に1秒間隔で保存した画像から、画面が変化した時点と30秒ごとの画像を抽出しています。全画像は同じフォルダにあり、`index.jsonl` で撮影時刻を確認できます。

        """

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

    private static func grayscaleThumbnail(of image: CGImage) -> [UInt8] {
        let width = 32
        let height = 32
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
