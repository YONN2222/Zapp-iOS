import Foundation
import OSLog

extension Notification.Name {
    static let searchHistoryUpdated = Notification.Name("SearchHistoryStore.historyUpdated")
}

final class SearchHistoryStore {
    static let shared = SearchHistoryStore()

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let historyKey = "mediathekSearchHistory"
    private let storageDirectoryName = "SearchHistory"
    private let storageFileName = "history.json"
    private let maxEntries = 10
    private let historyURL: URL

    private var cachedHistory: [String]

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = userDefaults
        self.fileManager = fileManager
        self.historyURL = SearchHistoryStore.makeHistoryURL(
            fileManager: fileManager,
            directoryName: storageDirectoryName,
            fileName: storageFileName
        )

        if let persisted = SearchHistoryStore.readHistory(from: historyURL, fileManager: fileManager) {
            self.cachedHistory = persisted
        } else {
            self.cachedHistory = []
        }

        migrateLegacyDefaultsIfNeeded()
    }

    func loadHistory() -> [String] {
        cachedHistory
    }

    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        modifyHistory { history in
            history.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            history.insert(trimmed, at: 0)
        }
    }

    func remove(_ query: String) {
        modifyHistory { history in
            history.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        }
    }

    func clear() {
        guard !cachedHistory.isEmpty else { return }
        cachedHistory = []
        defaults.removeObject(forKey: historyKey)
        removePersistedHistory()
        notifyObservers()
    }

    private func modifyHistory(_ block: (inout [String]) -> Void) {
        var history = cachedHistory
        block(&history)

        if history.count > maxEntries {
            history = Array(history.prefix(maxEntries))
        }

        guard history != cachedHistory else { return }

        cachedHistory = history
        persistHistory()
        notifyObservers()
    }

    private func persistHistory() {
        do {
            try ensureStorageDirectoryExists()
            let data = try JSONEncoder().encode(cachedHistory)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            searchHistoryLogger.debug("Failed to persist search history: \(String(describing: error))")
        }
    }

    private func removePersistedHistory() {
        if fileManager.fileExists(atPath: historyURL.path) {
            try? fileManager.removeItem(at: historyURL)
        }
    }

    private func ensureStorageDirectoryExists() throws {
        let directory = historyURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func migrateLegacyDefaultsIfNeeded() {
        let legacy = defaults.stringArray(forKey: historyKey) ?? []
        guard !legacy.isEmpty else { return }

        var merged = cachedHistory
        for entry in legacy.reversed() {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            merged.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            merged.insert(trimmed, at: 0)
        }

        if merged.count > maxEntries {
            merged = Array(merged.prefix(maxEntries))
        }

        cachedHistory = merged
        persistHistory()
        defaults.removeObject(forKey: historyKey)
    }

    private func notifyObservers() {
        NotificationCenter.default.post(name: .searchHistoryUpdated, object: nil)
    }

    private static func makeHistoryURL(
        fileManager: FileManager,
        directoryName: String,
        fileName: String
    ) -> URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return baseDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func readHistory(from url: URL, fileManager: FileManager) -> [String]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

private let searchHistoryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zapp", category: "SearchHistory")
