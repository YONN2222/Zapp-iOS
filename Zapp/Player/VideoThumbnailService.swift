import Foundation
import AVFoundation
import CryptoKit
import UIKit

enum VideoThumbnailError: Error {
    case failedToGenerate
}

enum ThumbnailQuality: String, Sendable {
    case standard
    case high
}

actor VideoThumbnailService {
    static let shared = VideoThumbnailService()

    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let diskCacheDirectory: URL
    private let maxDiskCacheSize: UInt64 = 200 * 1024 * 1024 // 200 MB
    private var inFlightTasks: [String: Task<UIImage, Error>] = [:]

    init() {
        cache.totalCostLimit = 50 * 1024 * 1024 // 50 MB in-memory

        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        diskCacheDirectory = cachesDirectory.appendingPathComponent("VideoThumbnails", isDirectory: true)

        Self.prepareDiskCacheDirectory(at: diskCacheDirectory)
        Self.pruneDiskCache(at: diskCacheDirectory, limit: maxDiskCacheSize)
    }

    func thumbnail(for url: URL, quality: ThumbnailQuality = .standard) async throws -> UIImage {
        let stringKey = cacheKey(for: url, quality: quality)
        let cacheKey = stringKey as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        if let diskCached = loadImageFromDisk(forKey: stringKey) {
            let cost = imageCostInBytes(diskCached)
            cache.setObject(diskCached, forKey: cacheKey, cost: cost)
            return diskCached
        }

        if let task = inFlightTasks[stringKey] {
            return try await task.value
        }

        let task = Task<UIImage, Error> {
            try await ThumbnailGenerator.generate(for: url, quality: quality)
        }
        inFlightTasks[stringKey] = task

        do {
            let image = try await task.value
            let cost = imageCostInBytes(image)
            cache.setObject(image, forKey: cacheKey, cost: cost)
            storeImageToDisk(image, forKey: stringKey)
            inFlightTasks[stringKey] = nil
            return image
        } catch {
            inFlightTasks[stringKey] = nil
            throw error
        }
    }

    func cacheThumbnails(for urls: [URL], quality: ThumbnailQuality = .standard) async {
        for url in urls {
            _ = try? await thumbnail(for: url, quality: quality)
        }
    }

    func clearCache() {
        cache.removeAllObjects()
        clearDiskCache()
    }

    private func imageCostInBytes(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let bytesPerPixel = 4
        let bytesPerRow = cgImage.width * bytesPerPixel
        return bytesPerRow * cgImage.height
    }

    private func cacheKey(for url: URL, quality: ThumbnailQuality) -> String {
        "\(quality.rawValue)::\(url.absoluteString)"
    }

    private func diskURL(forKey key: String) -> URL {
        diskCacheDirectory.appendingPathComponent(hashedFilename(for: key))
    }

    private func loadImageFromDisk(forKey key: String) -> UIImage? {
        let fileURL = diskURL(forKey: key)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        updateAccessDate(for: fileURL)
        return image
    }

    private func storeImageToDisk(_ image: UIImage, forKey key: String) {
        let fileURL = diskURL(forKey: key)
        guard let data = image.pngData() ?? image.jpegData(compressionQuality: 0.9) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            updateAccessDate(for: fileURL)
            Self.pruneDiskCache(at: diskCacheDirectory, limit: maxDiskCacheSize)
        } catch {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func updateAccessDate(for url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func clearDiskCache() {
        guard let files = try? fileManager.contentsOfDirectory(at: diskCacheDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    private func hashedFilename(for key: String) -> String {
        let data = Data(key.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func prepareDiskCacheDirectory(at url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directoryURL = url
        try? directoryURL.setResourceValues(resourceValues)
    }

    private static func pruneDiskCache(at url: URL, limit: UInt64) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var totalSize: UInt64 = 0
        var entries: [(url: URL, accessDate: Date, size: UInt64)] = []

        for fileURL in files {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey]),
                  let fileSize = resourceValues.fileSize else { continue }
            totalSize += UInt64(fileSize)
            let accessDate = resourceValues.contentAccessDate ?? resourceValues.contentModificationDate ?? Date.distantPast
            entries.append((fileURL, accessDate, UInt64(fileSize)))
        }

        guard totalSize > limit else { return }

        let sortedEntries = entries.sorted { $0.accessDate < $1.accessDate }
        var currentSize = totalSize

        for entry in sortedEntries {
            try? FileManager.default.removeItem(at: entry.url)
            if currentSize <= limit { break }
            currentSize = currentSize > entry.size ? currentSize - entry.size : 0
        }
    }
}

private enum ThumbnailGenerator {
    static func generate(for url: URL, quality: ThumbnailQuality) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(
                url: url,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            )
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let maximumSize: CGSize = {
                switch quality {
                case .standard:
                    return CGSize(width: 320, height: 180)
                case .high:
                    return CGSize(width: 1280, height: 720)
                }
            }()
            generator.maximumSize = maximumSize

            let candidateSeconds: [Double] = [15, 60, 5]
            var lastError: Error?

            for second in candidateSeconds {
                try Task.checkCancellation()
                let time = CMTime(seconds: second, preferredTimescale: 600)
                do {
                    let cgImage = try await generateCGImage(at: time, with: generator)
                    return UIImage(cgImage: cgImage)
                } catch {
                    lastError = error
                }
            }

            do {
                let cgImage = try await generateCGImage(at: .zero, with: generator)
                return UIImage(cgImage: cgImage)
            } catch {
                lastError = error
            }

            throw lastError ?? VideoThumbnailError.failedToGenerate
        }.value
    }

    private static func generateCGImage(at time: CMTime, with generator: AVAssetImageGenerator) async throws -> CGImage {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                    if let cgImage {
                        continuation.resume(returning: cgImage)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: VideoThumbnailError.failedToGenerate)
                    }
                }
            }
        }, onCancel: {
            generator.cancelAllCGImageGeneration()
        })
    }
}

