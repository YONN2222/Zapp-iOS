import Foundation
import Combine
import OSLog

private let channelRepositoryLogger = Logger(subsystem: "com.yonn2222.Zapp", category: "ChannelRepository")

@MainActor
final class ChannelNowPlayingState: ObservableObject, Identifiable {
    let id: String
    @Published var title: String?
    @Published var showDescription: String?
    @Published var range: ClosedRange<Date>?
    @Published var isLoading: Bool = false

    init(channelId: String) {
        self.id = channelId
    }

    func reset() {
        title = nil
        showDescription = nil
        range = nil
        isLoading = false
    }
}

@MainActor
final class ChannelRepository: ObservableObject {
    @Published private(set) var channels: [Channel] = []
    @Published private(set) var nowPlayingGeneration: Int = 0
    @Published private(set) var isSyncing: Bool = false

    private var baseChannels: [Channel] = []
    private let orderingStore = ChannelOrderingStore()
    private var customOrder: [String]
    private var customNames: [String: String]

    private struct NowPlayingEntry {
        let title: String?
        let description: String?
        let range: ClosedRange<Date>?
        let fetchedAt: Date
        let ttl: TimeInterval
    }

    private static let nowPlayingLimiter = ConcurrencyLimiter(limit: 4)

    private let nowPlayingTTL: TimeInterval = 90
    private let failureBackoff: TimeInterval = 20
    private let initialPrefetchCount = 12

    private var nowPlayingCache: [String: NowPlayingEntry] = [:]
    private var nowPlayingTasks: [String: Task<Void, Never>] = [:]
    private var nowPlayingStates: [String: ChannelNowPlayingState] = [:]

    init() {
        let storedNames = orderingStore.loadCustomNames()
        self.customOrder = orderingStore.loadOrder()
        self.customNames = ChannelRepository.sanitize(customNames: storedNames)
        Task { await loadBundledChannels(); await refreshFromApi() }
    }

    

    private func loadBundledChannels() async {
        guard let url = Bundle.main.url(forResource: "channels", withExtension: "json") else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            baseChannels = try decoder.decode([Channel].self, from: data)
            applyCustomizationsAndPublish()
        } catch {
            channelRepositoryLogger.error("Failed to load bundled channels: \(String(describing: error))")
        }
    }

    func refreshFromApi() async {
        guard !Task.isCancelled else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let map = try await ZappAPI.shared.fetchChannelInfoList()
            // update channels with incoming stream urls
            for i in baseChannels.indices {
                let id = baseChannels[i].id
                if let info = map[id] {
                    baseChannels[i].stream_url = info.streamUrl
                }
            }
        } catch {
            channelRepositoryLogger.error("Could not refresh channel info from backend: \(String(describing: error))")
        }

        applyCustomizationsAndPublish()
        invalidateNowPlayingCache()
        scheduleInitialNowPlayingPrefetch()
    }

    func channel(for id: String) -> Channel? { channels.first { $0.id == id } }

    func nowPlayingState(for channelId: String) -> ChannelNowPlayingState {
        if let existing = nowPlayingStates[channelId] {
            return existing
        }
        let state = ChannelNowPlayingState(channelId: channelId)
        nowPlayingStates[channelId] = state
        return state
    }

    func ensureNowPlaying(for channelId: String, priority: TaskPriority = .utility) async {
        if let entry = cachedEntry(for: channelId) {
            apply(entry, to: channelId)
            return
        }

        if nowPlayingTasks[channelId] == nil {
            setLoading(true, for: channelId)
            let task = Task(priority: priority) {
                await ChannelRepository.nowPlayingLimiter.acquire()
                defer { Task { await ChannelRepository.nowPlayingLimiter.release() } }
                let info = await ChannelRepository.fetchNowPlayingInfo(for: channelId)
                await MainActor.run { [weak self] in
                    self?.storeNowPlaying(info, for: channelId)
                }
            }
            nowPlayingTasks[channelId] = task
        }

        if let existingTask = nowPlayingTasks[channelId] {
            await existingTask.value
        }
    }

    private nonisolated static func fetchNowPlayingInfo(for channelId: String) async -> (title: String?, description: String?, range: ClosedRange<Date>?) {
        do {
            if let show = try await ZappAPI.shared.fetchShows(for: channelId) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                let startDate = show.startTime.flatMap { formatter.date(from: $0) }
                let endDate = show.endTime.flatMap { formatter.date(from: $0) }
                let trimmedTitle = show.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let sanitizedDescription = ChannelRepository.normalizeDescription(show.description)
                let trimmedDescription = sanitizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
                let range: ClosedRange<Date>?
                if let startDate, let endDate, startDate < endDate {
                    range = startDate...endDate
                } else {
                    range = nil
                }
                let normalizedDescription = (trimmedDescription?.isEmpty == false) ? trimmedDescription : nil
                return (trimmedTitle.isEmpty ? nil : trimmedTitle, normalizedDescription, range)
            }
        } catch {
            // Avoid accessing the file-scoped logger from a nonisolated context
            // (which can be treated as MainActor-isolated). Create a local
            // logger instance here so the call is allowed from nonisolated
            // static methods.
            let logger = Logger(subsystem: "com.yonn2222.Zapp", category: "ChannelRepository")
            logger.debug("Failed to fetch now playing info for \(channelId): \(String(describing: error))")
        }
        return (nil, nil, nil)
    }

    private nonisolated static func normalizeDescription(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let withLineBreaks = raw
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<b>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</b>", with: "\n", options: .caseInsensitive)
        return withLineBreaks
    }

    private func cachedEntry(for channelId: String) -> NowPlayingEntry? {
        guard let entry = nowPlayingCache[channelId] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) < entry.ttl {
            return entry
        }
        nowPlayingCache[channelId] = nil
        return nil
    }

    private func apply(_ entry: NowPlayingEntry, to channelId: String) {
        let state = nowPlayingState(for: channelId)
        state.title = entry.title
        state.showDescription = entry.description
        state.range = entry.range
    }

    @MainActor
    private func storeNowPlaying(_ info: (title: String?, description: String?, range: ClosedRange<Date>?), for channelId: String) {
        nowPlayingTasks[channelId] = nil
        defer { setLoading(false, for: channelId) }

        let hasContent = (info.title != nil) || (info.description != nil) || (info.range != nil)
        let entry = NowPlayingEntry(title: info.title,
                                    description: info.description,
                                    range: info.range,
                                    fetchedAt: Date(),
                                    ttl: hasContent ? nowPlayingTTL : failureBackoff)
        nowPlayingCache[channelId] = entry
        apply(entry, to: channelId)
    }

    private func invalidateNowPlayingCache() {
        nowPlayingCache.removeAll()
        nowPlayingTasks.values.forEach { $0.cancel() }
        nowPlayingTasks.removeAll()
        nowPlayingStates.values.forEach { $0.reset() }
        nowPlayingGeneration &+= 1
    }

    private func scheduleInitialNowPlayingPrefetch() {
        guard initialPrefetchCount > 0 else { return }
        let ids = channels.prefix(initialPrefetchCount).map(\.id)
        guard !ids.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            for (index, id) in ids.enumerated() {
                await self.ensureNowPlaying(for: id, priority: index < 2 ? .high : .medium)
            }
        }
    }

    private func setLoading(_ isLoading: Bool, for channelId: String) {
        let state = nowPlayingState(for: channelId)
        state.isLoading = isLoading
    }

    private func ensureStatesExistForLoadedChannels() {
        for channel in channels {
            _ = nowPlayingState(for: channel.id)
        }
        let validIds = Set(channels.map(\.id))
        let obsolete = nowPlayingStates.keys.filter { !validIds.contains($0) }
        obsolete.forEach { nowPlayingStates.removeValue(forKey: $0) }
    }

    func saveChannelCustomizations(order: [String], customNames newNames: [String: String]) {
        customOrder = order
        customNames = ChannelRepository.sanitize(customNames: newNames)
        orderingStore.save(order: customOrder)
        orderingStore.save(customNames: customNames)
        applyCustomizationsAndPublish()
    }

    func customName(for channelId: String) -> String? {
        customNames[channelId]
    }

    func resetChannelCustomizations() {
        customOrder = []
        customNames = [:]
        orderingStore.reset()
        applyCustomizationsAndPublish()
    }

    private func applyCustomizationsAndPublish() {
        guard !baseChannels.isEmpty else { return }
        var adjusted = baseChannels
        applyCustomNames(to: &adjusted)
        adjusted = applyCustomOrder(to: adjusted)
        channels = adjusted
        ensureStatesExistForLoadedChannels()
    }

    private func applyCustomNames(to channels: inout [Channel]) {
        for index in channels.indices {
            let id = channels[index].id
            if let custom = customNames[id], !custom.isEmpty {
                channels[index].name = custom
            } else {
                channels[index].name = channels[index].defaultName
            }
        }
    }

    private func applyCustomOrder(to channels: [Channel]) -> [Channel] {
        guard !customOrder.isEmpty else { return channels }
        let explicitOrder = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($0.element, $0.offset) })
        let fallbackOrder = Dictionary(uniqueKeysWithValues: baseChannels.enumerated().map { ($0.element.id, $0.offset) })

        return channels.sorted { lhs, rhs in
            let leftIndex = explicitOrder[lhs.id] ?? (fallbackOrder[lhs.id] ?? Int.max)
            let rightIndex = explicitOrder[rhs.id] ?? (fallbackOrder[rhs.id] ?? Int.max)
            if leftIndex == rightIndex {
                return lhs.defaultName.localizedCaseInsensitiveCompare(rhs.defaultName) == .orderedAscending
            }
            return leftIndex < rightIndex
        }
    }

    private static func sanitize(customNames: [String: String]) -> [String: String] {
        customNames.reduce(into: [:]) { partialResult, entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                partialResult[entry.key] = trimmed
            }
        }
    }
}

private final class ChannelOrderingStore {
    private let defaults = UserDefaults.standard
    private let orderKey = "channelOrdering.order"
    private let customNamesKey = "channelOrdering.customNames"

    func loadOrder() -> [String] {
        defaults.stringArray(forKey: orderKey) ?? []
    }

    func save(order: [String]) {
        defaults.set(order, forKey: orderKey)
    }

    func loadCustomNames() -> [String: String] {
        defaults.dictionary(forKey: customNamesKey) as? [String: String] ?? [:]
    }

    func save(customNames: [String: String]) {
        defaults.set(customNames, forKey: customNamesKey)
    }

    func reset() {
        defaults.removeObject(forKey: orderKey)
        defaults.removeObject(forKey: customNamesKey)
    }
}
