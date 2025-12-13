import Foundation
import Combine

@MainActor
final class MediathekRepository: ObservableObject {
    @Published private(set) var bookmarks: [PersistedMediathekShow] = []
    @Published private(set) var downloads: [PersistedMediathekShow] = []
    @Published private(set) var continueWatching: [PersistedMediathekShow] = []
    
    private let persistence = PersistenceManager.shared
    private var downloadsObserver: NSObjectProtocol?
    private var continueWatchingObserver: NSObjectProtocol?
    
    init() {
        loadPersistedData()
        let persistence = persistence
        Task(priority: .utility) {
            await persistence.backfillDownloadThumbnailsIfNeeded()
        }
        downloadsObserver = NotificationCenter.default.addObserver(
            forName: .downloadsUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloads = self.persistence.loadDownloads()
            }
            guard let self else { return }
            let persistence = self.persistence
            Task(priority: .utility) {
                await persistence.backfillDownloadThumbnailsIfNeeded()
            }
        }

        continueWatchingObserver = NotificationCenter.default.addObserver(
            forName: .continueWatchingUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.continueWatching = self.persistence.loadContinueWatching()
            }
        }
    }

    deinit {
        if let downloadsObserver {
            NotificationCenter.default.removeObserver(downloadsObserver)
        }
        if let continueWatchingObserver {
            NotificationCenter.default.removeObserver(continueWatchingObserver)
        }
    }
    
    func loadPersistedData() {
        bookmarks = persistence.loadBookmarks()
        downloads = persistence.loadDownloads()
        continueWatching = persistence.loadContinueWatching()
        warmThumbnailCache()
    }
    
    func toggleBookmark(show: MediathekShow) {
        persistence.toggleBookmark(show: show)
        loadPersistedData()
    }

    func removeBookmark(apiId: String) {
        persistence.removeBookmark(apiId: apiId)
        loadPersistedData()
    }
    
    func isBookmarked(apiId: String) -> Bool {
        bookmarks.contains { $0.apiId == apiId }
    }
    
    func savePlaybackPosition(show: MediathekShow, position: TimeInterval, duration: TimeInterval) {
        persistence.savePlaybackPosition(show: show, position: position, duration: duration)
        loadPersistedData()
    }

    func removeContinueWatching(apiId: String) {
        persistence.removeContinueWatchingEntry(apiId: apiId)
        loadPersistedData()
    }
    
    func getPlaybackPosition(apiId: String) -> TimeInterval? {
        if let entry = continueWatching.first(where: { $0.apiId == apiId }), entry.playbackPosition > 0 {
            return entry.playbackPosition
        }
        if let entry = downloads.first(where: { $0.apiId == apiId }), entry.playbackPosition > 0 {
            return entry.playbackPosition
        }
        if let entry = bookmarks.first(where: { $0.apiId == apiId }), entry.playbackPosition > 0 {
            return entry.playbackPosition
        }
        return nil
    }
    
    @discardableResult
    func startDownload(show: MediathekShow, quality: MediathekShow.Quality) -> Bool {
        if AppSettings.shared.downloadOverWifiOnly && !NetworkMonitor.shared.isOnWiFi {
            return false
        }

        persistence.startDownload(show: show, quality: quality)
        loadPersistedData()
        NotificationCenter.default.post(name: .navigateToDownloadsTab, object: nil)
        return true
    }
    
    func cancelDownload(apiId: String) {
        persistence.cancelDownload(apiId: apiId)
        loadPersistedData()
    }
    
    func deleteDownload(apiId: String) {
        persistence.deleteDownload(apiId: apiId)
        loadPersistedData()
    }
    
    func getDownloadStatus(apiId: String) -> DownloadStatus {
        downloads.first { $0.apiId == apiId }?.downloadStatus ?? .none
    }

    private func warmThumbnailCache() {
        let persistedShows = bookmarks + downloads + continueWatching
        let urls = persistedShows.compactMap { $0.show.preferredThumbnailURL }
        guard !urls.isEmpty else { return }

        let uniqueUrls = Array(Set(urls))
        Task(priority: .utility) {
            await VideoThumbnailService.shared.cacheThumbnails(for: uniqueUrls, quality: .standard)
        }
    }
}
