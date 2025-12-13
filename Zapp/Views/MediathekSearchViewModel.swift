import Foundation
import Combine

@MainActor
final class MediathekSearchViewModel: ObservableObject {
    struct SearchParameters: Equatable {
        let query: String
        let channels: Set<MediathekChannel>
        let minDurationMinutes: Int?
        let maxDurationMinutes: Int?
    }

    @Published var searchText: String = ""
    @Published private var committedQuery: String = ""

    @Published private(set) var selectedChannels: Set<MediathekChannel> = []
    @Published private(set) var minDurationMinutes: Int?
    @Published private(set) var maxDurationMinutes: Int?

    @Published private(set) var shows: [MediathekShow] = []
    @Published private(set) var isInitialLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var queryInfo: MediathekAnswer.MediathekResult.QueryInfo?
    @Published private(set) var searchHistory: [String] = []

    private let pageSize = 30
    private var nextOffset = 0
    private var hasReachedEnd = false
    private var currentParameters = SearchParameters(query: "", channels: [], minDurationMinutes: nil, maxDurationMinutes: nil)

    private var cancellables = Set<AnyCancellable>()
    private var activeTask: Task<Void, Never>?
    private let historyStore: SearchHistoryStore

    var committedQueryText: String {
        committedQuery
    }

    init(
        debounceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(200),
        historyStore: SearchHistoryStore? = nil
    ) {
        self.historyStore = historyStore ?? SearchHistoryStore.shared

        Publishers.CombineLatest4(
            $committedQuery,
            $selectedChannels,
            $minDurationMinutes,
            $maxDurationMinutes
        )
        .map { query, channels, minDuration, maxDuration -> SearchParameters in
            let sanitizedMin = minDuration.flatMap { $0 >= 0 ? $0 : nil }
            let sanitizedMax = maxDuration.flatMap { $0 >= 0 ? $0 : nil }
            return SearchParameters(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                channels: channels,
                minDurationMinutes: sanitizedMin,
                maxDurationMinutes: sanitizedMax
            )
        }
        .debounce(for: debounceInterval, scheduler: DispatchQueue.main)
        .sink { [weak self] parameters in
            self?.startNewSearch(with: parameters)
        }
        .store(in: &cancellables)

        searchHistory = self.historyStore.loadHistory()

        $searchText
            .removeDuplicates()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .sink { [weak self] trimmed in
                guard let self else { return }
                guard trimmed.isEmpty else { return }
                self.cancelActiveSearch()
                self.committedQuery = ""
                self.shows = []
                self.queryInfo = nil
                self.errorMessage = nil
                self.hasReachedEnd = false
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .searchHistoryUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.searchHistory = self?.historyStore.loadHistory() ?? []
            }
            .store(in: &cancellables)
    }

    var hasActiveFilters: Bool {
        !selectedChannels.isEmpty || minDurationMinutes != nil || maxDurationMinutes != nil
    }

    func applyFilters(channels: Set<MediathekChannel>, minDurationMinutes: Int?, maxDurationMinutes: Int?) {
        let sanitizedMin = minDurationMinutes.flatMap { $0 >= 0 ? $0 : nil }
        let sanitizedMax = maxDurationMinutes.flatMap { $0 >= 0 ? $0 : nil }

    let finalMin = sanitizedMin
        var finalMax = sanitizedMax

        if let min = finalMin, let max = finalMax, min > max {
            finalMax = min
        }

        selectedChannels = channels
        self.minDurationMinutes = finalMin
        self.maxDurationMinutes = finalMax
    }

    func removeChannel(_ channel: MediathekChannel) {
        var updated = selectedChannels
        updated.remove(channel)
        selectedChannels = updated
    }

    func clearMinDuration() {
        minDurationMinutes = nil
    }

    func clearMaxDuration() {
        maxDurationMinutes = nil
    }

    func resetFilters() {
        selectedChannels = []
        minDurationMinutes = nil
        maxDurationMinutes = nil
    }

    func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            cancelActiveSearch()
            committedQuery = ""
            shows = []
            queryInfo = nil
            errorMessage = nil
            hasReachedEnd = false
            return
        }

        let parameters = SearchParameters(
            query: trimmed,
            channels: selectedChannels,
            minDurationMinutes: minDurationMinutes,
            maxDurationMinutes: maxDurationMinutes
        )

        if trimmed == committedQuery {
            startNewSearch(with: parameters)
        } else {
            committedQuery = trimmed
        }

        historyStore.record(trimmed)
        searchHistory = historyStore.loadHistory()
    }

    func selectHistoryEntry(_ entry: String) {
        searchText = entry
        submitSearch()
    }

    func deleteHistoryEntry(_ entry: String) {
        historyStore.remove(entry)
        searchHistory = historyStore.loadHistory()
    }

    func refresh() async {
        activeTask?.cancel()
        hasReachedEnd = false
        nextOffset = 0
        guard !currentParameters.query.isEmpty else {
            return
        }
        await loadPage(reset: true)
    }

    func loadMoreIfNeeded(currentItem show: MediathekShow?) {
        guard !isInitialLoading, !isLoadingMore, !hasReachedEnd else { return }
        guard let show, show.id == shows.last?.id else { return }
        enqueueNextPage()
    }

    func loadNextPage() {
        guard !hasReachedEnd else { return }
        enqueueNextPage()
    }

    private func enqueueNextPage() {
        guard !isLoadingMore, !isInitialLoading else { return }
        activeTask?.cancel()
        activeTask = Task { [weak self] in
            await self?.loadPage(reset: false)
        }
    }

    private func startNewSearch(with parameters: SearchParameters) {
        currentParameters = parameters
        nextOffset = 0
        hasReachedEnd = false
        shows = []
        queryInfo = nil
        errorMessage = nil
        activeTask?.cancel()
        guard !parameters.query.isEmpty else {
            return
        }
        activeTask = Task { [weak self] in
            await self?.loadPage(reset: true)
        }
    }

    func cancelActiveSearch() {
        activeTask?.cancel()
        activeTask = nil
        isInitialLoading = false
        isLoadingMore = false
    }

    private func loadPage(reset: Bool) async {
        if reset {
            isInitialLoading = true
        } else {
            isLoadingMore = true
        }

        defer {
            if reset {
                isInitialLoading = false
            } else {
                isLoadingMore = false
            }
        }

        do {
            let request = buildRequest(offset: reset ? 0 : nextOffset)
            let answer = try await MediathekAPI.shared.search(request: request)
            guard !Task.isCancelled else { return }

            if reset {
                shows = answer.result.results
                nextOffset = answer.result.results.count
            } else {
                shows.append(contentsOf: answer.result.results)
                nextOffset += answer.result.results.count
            }

            queryInfo = answer.result.queryInfo
            errorMessage = nil
            hasReachedEnd = answer.result.results.count < pageSize
        } catch {
            guard !Task.isCancelled else { return }
            if reset {
                shows = []
            }
            errorMessage = Self.errorDescription(from: error)
        }
    }

    private func buildRequest(offset: Int) -> MediathekQueryRequest {
        let minSeconds = currentParameters.minDurationMinutes.map { $0 * 60 }
        let maxSeconds = currentParameters.maxDurationMinutes.map { $0 * 60 }
        let channels = Array(currentParameters.channels).sorted { $0.rawValue < $1.rawValue }

        return MediathekQueryRequest.search(
            query: currentParameters.query,
            channels: channels,
            minDurationSeconds: minSeconds,
            maxDurationSeconds: maxSeconds,
            offset: offset,
            size: pageSize
        )
    }

    private static func errorDescription(from error: Error) -> String? {
        if let apiError = error as? ZappAPIError {
            switch apiError {
            case .invalidURL:
                return String(localized: "mediathek_error_invalid_request")
            case .requestFailed:
                let retryLabel = String(localized: "retry")
                let format = String(localized: "mediathek_error_slow")
                return String(format: format, retryLabel)
            }
        }
        if (error as NSError).code == NSURLErrorCancelled {
            return nil
        }
        return error.localizedDescription
    }
}
