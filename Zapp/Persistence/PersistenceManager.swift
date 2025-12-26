import Foundation
import UIKit
import CryptoKit
import OSLog

extension Notification.Name {
    static let downloadsUpdated = Notification.Name("PersistenceManager.downloadsUpdated")
    static let continueWatchingUpdated = Notification.Name("PersistenceManager.continueWatchingUpdated")
    static let bookmarksUpdated = Notification.Name("PersistenceManager.bookmarksUpdated")
    static let navigateToDownloadsTab = Notification.Name("MainTab.navigateToDownloads")
    static let showOnboardingAgain = Notification.Name("AppSettings.showOnboardingAgain")
}

private let persistenceLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zapp", category: "Persistence")

@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()
    
    private let userDefaults = UserDefaults.standard
    private let bookmarksKey = "bookmarks"
    private let downloadsKey = "downloads"
    private let continueWatchingKey = "continueWatching"
    private var activeDownloadDelegates: [String: DownloadProgressDelegate] = [:]
    private var activeDownloadTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloadSessions: [String: URLSession] = [:]
    private let fileManager = FileManager.default
    private var isThumbnailBackfillRunning = false
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var thumbnailsDirectory: URL {
        documentsDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    }
    
    private init() {}

    
    func loadBookmarks() -> [PersistedMediathekShow] {
        guard let data = userDefaults.data(forKey: bookmarksKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedMediathekShow].self, from: data)) ?? []
    }
    
    func toggleBookmark(show: MediathekShow) {
        var bookmarks = loadBookmarks()
        
        if let index = bookmarks.firstIndex(where: { $0.apiId == show.id }) {
            bookmarks.remove(at: index)
        } else {
            let persisted = PersistedMediathekShow(
                id: Int.random(in: 1...Int.max),
                apiId: show.id,
                show: show,
                bookmarked: true,
                bookmarkedAt: Date(),
                createdAt: Date(),
                updatedAt: Date()
            )
            bookmarks.append(persisted)
        }
        
        saveBookmarks(bookmarks)
    }

    func removeBookmark(apiId: String) {
        var bookmarks = loadBookmarks()
        guard let index = bookmarks.firstIndex(where: { $0.apiId == apiId }) else { return }
        bookmarks.remove(at: index)
        saveBookmarks(bookmarks)
    }

    func deleteAllBookmarks() {
        saveBookmarks([])
        NotificationCenter.default.post(name: .bookmarksUpdated, object: nil)
    }
    
    private func saveBookmarks(_ bookmarks: [PersistedMediathekShow]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            userDefaults.set(data, forKey: bookmarksKey)
        }
    }
    
    
    func loadContinueWatching() -> [PersistedMediathekShow] {
        guard let data = userDefaults.data(forKey: continueWatchingKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedMediathekShow].self, from: data)) ?? []
    }
    
    func savePlaybackPosition(show: MediathekShow, position: TimeInterval, duration: TimeInterval) {
        if duration > 0 {
            let nearEndThreshold = max(1.0, duration * 0.01)
            if position >= duration - nearEndThreshold || position >= duration * 0.99 {
                removeContinueWatchingEntry(apiId: show.id)
                updateBookmarksPlayback(show: show, position: duration, duration: duration)
                updateDownloadsPlayback(show: show, position: duration, duration: duration)
                return
            }
        }

        var continueWatching = loadContinueWatching()

        if let index = continueWatching.firstIndex(where: { $0.apiId == show.id }) {
            continueWatching[index].playbackPosition = position
            continueWatching[index].videoDuration = duration
            continueWatching[index].lastPlayedBackAt = Date()
            continueWatching[index].updatedAt = Date()
        } else {
            var persisted = PersistedMediathekShow(
                id: Int.random(in: 1...Int.max),
                apiId: show.id,
                show: show,
                createdAt: Date(),
                updatedAt: Date()
            )
            persisted.playbackPosition = position
            persisted.videoDuration = duration
            persisted.lastPlayedBackAt = Date()
            continueWatching.append(persisted)
        }

        // Keep only last 50
        if continueWatching.count > 50 {
            continueWatching = Array(continueWatching.suffix(50))
        }

        saveContinueWatching(continueWatching)
        notifyContinueWatchingChanged()
        updateBookmarksPlayback(show: show, position: position, duration: duration)
        updateDownloadsPlayback(show: show, position: position, duration: duration)
    }

    func removeContinueWatchingEntry(apiId: String) {
        var continueWatching = loadContinueWatching()
        guard let index = continueWatching.firstIndex(where: { $0.apiId == apiId }) else { return }
        continueWatching.remove(at: index)
        saveContinueWatching(continueWatching)
        notifyContinueWatchingChanged()
    }

    func deleteAllContinueWatching() {
        saveContinueWatching([])
        notifyContinueWatchingChanged()
    }
    
    private func saveContinueWatching(_ continueWatching: [PersistedMediathekShow]) {
        if let data = try? JSONEncoder().encode(continueWatching) {
            userDefaults.set(data, forKey: continueWatchingKey)
        }
    }
    

    
    func loadDownloads() -> [PersistedMediathekShow] {
        guard let data = userDefaults.data(forKey: downloadsKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedMediathekShow].self, from: data)) ?? []
    }
    
    func startDownload(show: MediathekShow, quality: MediathekShow.Quality) {
        var downloads = loadDownloads()
        let expectedBytes = (show.size ?? 0) > 0 ? Int64(show.size!) : nil
        
        if let index = downloads.firstIndex(where: { $0.apiId == show.id }) {
            downloads[index].downloadStatus = .queued
            downloads[index].downloadProgress = 0
            downloads[index].downloadedBytes = 0
            downloads[index].expectedDownloadBytes = expectedBytes
            if let path = downloads[index].downloadedVideoPath {
                removeFileIfExists(at: path)
            }
            if let thumbPath = downloads[index].downloadedThumbnailPath {
                removeFileIfExists(at: thumbPath)
            }
            downloads[index].downloadedVideoPath = nil
            downloads[index].downloadedThumbnailPath = nil
            downloads[index].updatedAt = Date()
        } else {
            var persisted = PersistedMediathekShow(
                id: Int.random(in: 1...Int.max),
                apiId: show.id,
                show: show,
                createdAt: Date(),
                updatedAt: Date()
            )
            persisted.downloadStatus = .queued
            persisted.downloadedVideoPath = nil
            persisted.downloadedThumbnailPath = nil
            persisted.downloadedBytes = 0
            persisted.expectedDownloadBytes = expectedBytes
            downloads.append(persisted)
        }
        
        saveDownloads(downloads)

        let delegate = DownloadProgressDelegate(apiId: show.id, expectedBytesHint: expectedBytes, persistence: self)
        activeDownloadDelegates[show.id] = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        activeDownloadSessions[show.id] = session

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDownload(show: show, quality: quality, delegate: delegate, session: session)
        }
        activeDownloadTasks[show.id] = task
    }
    
    func cancelDownload(apiId: String) {
        cancelActiveDownload(for: apiId)
        var downloads = loadDownloads()
        if let index = downloads.firstIndex(where: { $0.apiId == apiId }) {
            downloads[index].downloadStatus = .none
            downloads[index].downloadProgress = 0
            downloads[index].downloadedBytes = 0
            downloads[index].expectedDownloadBytes = nil
            if let path = downloads[index].downloadedVideoPath {
                removeFileIfExists(at: path)
                downloads[index].downloadedVideoPath = nil
            }
            if let thumbPath = downloads[index].downloadedThumbnailPath {
                removeFileIfExists(at: thumbPath)
                downloads[index].downloadedThumbnailPath = nil
            }
            downloads[index].updatedAt = Date()
            saveDownloads(downloads)
        }
    }
    
    func deleteDownload(apiId: String) {
        cancelActiveDownload(for: apiId)
        var downloads = loadDownloads()
        if let index = downloads.firstIndex(where: { $0.apiId == apiId }) {
            // Delete local file
            if let path = downloads[index].downloadedVideoPath {
                removeFileIfExists(at: path)
            }
            if let thumbPath = downloads[index].downloadedThumbnailPath {
                removeFileIfExists(at: thumbPath)
            }
            downloads.remove(at: index)
            saveDownloads(downloads)
        }
    }

    func deleteAllDownloads() {
        let downloads = loadDownloads()

        for entry in downloads {
            cancelActiveDownload(for: entry.apiId)
            if let videoPath = entry.downloadedVideoPath {
                removeFileIfExists(at: videoPath)
            }
            if let thumbnailPath = entry.downloadedThumbnailPath {
                removeFileIfExists(at: thumbnailPath)
            }
        }

        saveDownloads([])
    }
    
    private func saveDownloads(_ downloads: [PersistedMediathekShow]) {
        if let data = try? JSONEncoder().encode(downloads) {
            userDefaults.set(data, forKey: downloadsKey)
            notifyDownloadsChanged()
        }
    }
    
    private func updateBookmarksPlayback(show: MediathekShow, position: TimeInterval, duration: TimeInterval) {
        var bookmarks = loadBookmarks()
        guard let index = bookmarks.firstIndex(where: { $0.apiId == show.id }) else { return }
        bookmarks[index].playbackPosition = position
        bookmarks[index].videoDuration = duration
        bookmarks[index].lastPlayedBackAt = Date()
        bookmarks[index].updatedAt = Date()
        saveBookmarks(bookmarks)
    }
    
    private func updateDownloadsPlayback(show: MediathekShow, position: TimeInterval, duration: TimeInterval) {
        var downloads = loadDownloads()
        guard let index = downloads.firstIndex(where: { $0.apiId == show.id }) else { return }
        downloads[index].playbackPosition = position
        downloads[index].videoDuration = duration
        downloads[index].lastPlayedBackAt = Date()
        downloads[index].updatedAt = Date()
        saveDownloads(downloads)
    }
    
    private func performDownload(show: MediathekShow, quality: MediathekShow.Quality, delegate: DownloadProgressDelegate, session: URLSession) async {
        defer {
            activeDownloadDelegates.removeValue(forKey: show.id)
            activeDownloadTasks.removeValue(forKey: show.id)
            if let session = activeDownloadSessions.removeValue(forKey: show.id) {
                session.invalidateAndCancel()
            }
        }

        guard let url = show.url(for: quality) else { return }
        
        var downloads = loadDownloads()
        guard let index = downloads.firstIndex(where: { $0.apiId == show.id }) else { return }
        
        downloads[index].downloadStatus = .downloading

        var resolvedExpected = downloads[index].resolvedExpectedDownloadBytes
        if resolvedExpected == nil {
            resolvedExpected = await fetchExpectedDownloadBytes(for: url)
        }

        if let resolvedExpected {
            downloads[index].expectedDownloadBytes = resolvedExpected
            delegate.updateExpectedBytes(resolvedExpected)
        }

        saveDownloads(downloads)
        
        do {
            let (localURL, _) = try await session.download(from: url)

            let destinationURL = documentsDirectory.appendingPathComponent("\(show.id).mp4")

            try? fileManager.removeItem(at: destinationURL)
            try fileManager.moveItem(at: localURL, to: destinationURL)
            
            downloads = loadDownloads()
            if let idx = downloads.firstIndex(where: { $0.apiId == show.id }) {
                downloads[idx].downloadStatus = .completed
                downloads[idx].downloadProgress = 100
                let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
                if let sizeNumber = attributes?[.size] as? NSNumber {
                    let byteCount = sizeNumber.int64Value
                    downloads[idx].downloadedBytes = byteCount
                    downloads[idx].expectedDownloadBytes = byteCount
                } else if let expectedBytes = downloads[idx].resolvedExpectedDownloadBytes {
                    downloads[idx].downloadedBytes = expectedBytes
                    downloads[idx].expectedDownloadBytes = expectedBytes
                }
                downloads[idx].downloadedVideoPath = destinationURL.path
                let thumbnailSources: [URL] = {
                    var urls: [URL] = [destinationURL]
                    if let remote = show.preferredThumbnailURL {
                        urls.append(remote)
                    }
                    return urls
                }()
                downloads[idx].downloadedThumbnailPath = await persistThumbnail(from: thumbnailSources, apiId: show.id)
                downloads[idx].updatedAt = Date()
                saveDownloads(downloads)
            }
        } catch is CancellationError {
            downloads = loadDownloads()
            if let idx = downloads.firstIndex(where: { $0.apiId == show.id }) {
                downloads[idx].downloadStatus = .none
                downloads[idx].downloadProgress = 0
                downloads[idx].downloadedBytes = 0
                downloads[idx].expectedDownloadBytes = nil
                downloads[idx].updatedAt = Date()
                saveDownloads(downloads)
            }
        } catch {
            persistenceLogger.error("Download failed: \(String(describing: error))")
            downloads = loadDownloads()
            if let idx = downloads.firstIndex(where: { $0.apiId == show.id }) {
                downloads[idx].downloadStatus = .failed
                downloads[idx].downloadProgress = 0
                downloads[idx].downloadedBytes = 0
                downloads[idx].updatedAt = Date()
                saveDownloads(downloads)
            }
        }
    }

    private func cancelActiveDownload(for apiId: String) {
        activeDownloadDelegates.removeValue(forKey: apiId)
        if let task = activeDownloadTasks.removeValue(forKey: apiId) {
            task.cancel()
        }
        if let session = activeDownloadSessions.removeValue(forKey: apiId) {
            session.invalidateAndCancel()
        }
    }

    private func fetchExpectedDownloadBytes(for url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               let lengthString = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let bytes = Int64(lengthString) {
                return bytes
            }
        } catch {
            persistenceLogger.debug("HEAD request for \(url) failed: \(String(describing: error))")
        }
        return nil
    }

    func handleProgressUpdate(
        apiId: String,
        progress: Double,
        downloadedBytes: Int64,
        expectedBytes: Int64?
    ) {
        let clamped = max(0, min(1, progress))
        var downloads = loadDownloads()
        guard let index = downloads.firstIndex(where: { $0.apiId == apiId }) else { return }

        downloads[index].downloadStatus = .downloading
        let safeDownloaded = max(downloadedBytes, 0)
        downloads[index].downloadedBytes = safeDownloaded

        let resolvedExpected = expectedBytes ?? downloads[index].resolvedExpectedDownloadBytes
        if let resolvedExpected, resolvedExpected > 0 {
            let byteFraction = min(1, Double(safeDownloaded) / Double(resolvedExpected))
            let fraction = max(clamped, byteFraction)
            downloads[index].downloadProgress = Int(fraction * 100)
            downloads[index].expectedDownloadBytes = resolvedExpected
        } else {
            downloads[index].downloadProgress = Int(clamped * 100)
        }

        downloads[index].updatedAt = Date()
        saveDownloads(downloads)
    }

    func backfillDownloadThumbnailsIfNeeded() async {
        guard !isThumbnailBackfillRunning else { return }
        isThumbnailBackfillRunning = true
        defer { isThumbnailBackfillRunning = false }

        var downloads = loadDownloads()
        var didChange = false

        for index in downloads.indices {
            guard downloads[index].downloadStatus == .completed,
                  downloads[index].downloadedThumbnailPath == nil,
                  let path = downloads[index].downloadedVideoPath,
                  fileManager.fileExists(atPath: path)
            else { continue }

            var sources: [URL] = [URL(fileURLWithPath: path)]
            if let remote = downloads[index].show.preferredThumbnailURL {
                sources.append(remote)
            }

            if let thumbnailPath = await persistThumbnail(from: sources, apiId: downloads[index].apiId) {
                downloads[index].downloadedThumbnailPath = thumbnailPath
                downloads[index].updatedAt = Date()
                didChange = true
            }
        }

        if didChange {
            saveDownloads(downloads)
        }
    }

    private func notifyDownloadsChanged() {
        NotificationCenter.default.post(name: .downloadsUpdated, object: nil)
    }

    private func notifyContinueWatchingChanged() {
        NotificationCenter.default.post(name: .continueWatchingUpdated, object: nil)
    }

    private func persistThumbnail(from sources: [URL], apiId: String) async -> String? {
        for source in sources {
            if let thumbnailPath = await persistThumbnail(source: source, apiId: apiId) {
                return thumbnailPath
            }
        }
        return nil
    }

    private func persistThumbnail(source: URL, apiId: String) async -> String? {
        do {
            let image = try await VideoThumbnailService.shared.thumbnail(for: source, quality: .standard)
            return try persist(image: image, apiId: apiId)
        } catch {
            persistenceLogger.debug("Failed to persist thumbnail for \(apiId) using \(source): \(String(describing: error))")
            return nil
        }
    }

    private func persist(image: UIImage, apiId: String) throws -> String {
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let destination = thumbnailDestinationURL(for: apiId)
        guard let data = image.jpegData(compressionQuality: 0.85) ?? image.pngData() else {
            return destination.path
        }
        try data.write(to: destination, options: .atomic)
        return destination.path
    }

    private func thumbnailDestinationURL(for apiId: String) -> URL {
        let hashed = SHA256.hash(data: Data(apiId.utf8)).map { String(format: "%02x", $0) }.joined()
        return thumbnailsDirectory.appendingPathComponent("\(hashed)_thumb.jpg")
    }

    private func removeFileIfExists(at path: String) {
        guard fileManager.fileExists(atPath: path) else { return }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            persistenceLogger.debug("Failed to remove file at \(path): \(String(describing: error))")
        }
    }

    func playbackPosition(for apiId: String) -> TimeInterval? {
        if let entry = loadContinueWatching().first(where: { $0.apiId == apiId }), entry.playbackPosition > 0 {
            return entry.playbackPosition
        }
        if let entry = loadDownloads().first(where: { $0.apiId == apiId }), entry.playbackPosition > 0 {
            return entry.playbackPosition
        }
        if let entry = loadBookmarks().first(where: { $0.apiId == apiId }), entry.playbackPosition > 0 {
            return entry.playbackPosition
        }
        return nil
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    weak var persistence: PersistenceManager?
    let apiId: String
    private(set) var expectedBytesHint: Int64?
    private var lastUpdate: Date = .distantPast

    init(apiId: String, expectedBytesHint: Int64?, persistence: PersistenceManager) {
        self.apiId = apiId
        self.expectedBytesHint = expectedBytesHint
        self.persistence = persistence
    }

    func updateExpectedBytes(_ bytes: Int64) {
        expectedBytesHint = bytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = resolveExpectedBytes(
            reported: totalBytesExpectedToWrite,
            downloadTask: downloadTask
        )

        let fraction: Double
        if let expectedBytes, expectedBytes > 0 {
            fraction = Double(totalBytesWritten) / Double(expectedBytes)
        } else if downloadTask.progress.totalUnitCount > 0 {
            fraction = Double(downloadTask.progress.completedUnitCount) / Double(downloadTask.progress.totalUnitCount)
        } else {
            fraction = 0
        }

        let now = Date()
        if now.timeIntervalSince(lastUpdate) > 0.5 || fraction >= 1.0 {
            lastUpdate = now
            Task { @MainActor [weak persistence] in
                persistence?.handleProgressUpdate(
                    apiId: apiId,
                    progress: fraction,
                    downloadedBytes: totalBytesWritten,
                    expectedBytes: expectedBytes
                )
            }
        }
    }

    private func resolveExpectedBytes(reported: Int64, downloadTask: URLSessionDownloadTask) -> Int64? {
        if reported > 0 {
            return reported
        }
        if downloadTask.countOfBytesExpectedToReceive > 0 {
            return downloadTask.countOfBytesExpectedToReceive
        }
        if let responseExpected = downloadTask.response?.expectedContentLength, responseExpected > 0 {
            return responseExpected
        }
        if let expectedBytesHint, expectedBytesHint > 0 {
            return expectedBytesHint
        }
        return nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // handled via async return value in PersistenceManager
    }
}
