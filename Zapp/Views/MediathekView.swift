import SwiftUI
import UIKit

struct MediathekView: View {
    @EnvironmentObject var repo: MediathekRepository
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var viewModel = MediathekSearchViewModel()
    @State private var showFilters = false
    @State private var offlineSearchText = ""
    @State private var connectionTimeoutTask: Task<Void, Never>?
    @State private var hasConnectionTimedOut = false
    @State private var sheetShow: MediathekShow?

    @ViewBuilder
    var body: some View {
        mainContent
            .sheet(isPresented: $showFilters) {
                FilterView(
                    initialChannels: viewModel.selectedChannels,
                    initialMinDuration: viewModel.minDurationMinutes,
                    initialMaxDuration: viewModel.maxDurationMinutes
                ) { channels, min, max in
                    viewModel.applyFilters(
                        channels: channels,
                        minDurationMinutes: min,
                        maxDurationMinutes: max
                    )
                }
            }
            .sheet(item: $sheetShow) { show in
                NavigationStack {
                    MediathekDetailView(show: show)
                }
                .presentationDetents([.large])
                .presentationCornerRadius(28)
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.resizes)
            }
            .onChange(of: viewModel.isInitialLoading) { _, newValue in
                handleLoadingStateChange(newValue)
            }
            .onChange(of: networkMonitor.hasConnection) { _, hasConnection in
                if hasConnection {
                    handleLoadingStateChange(viewModel.isInitialLoading)
                } else {
                    resetConnectionTimeoutState()
                }
            }
            .onChange(of: hasConnectionTimedOut) { _, timedOut in
                if timedOut {
                    viewModel.cancelActiveSearch()
                }
            }
            .onAppear {
                if networkMonitor.hasConnection && viewModel.isInitialLoading {
                    startConnectionTimeout()
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if usesInlineSearch {
            content
                .navigationTitle(Text("tab_mediathek"))
                .toolbar { filterToolbar }
        } else {
            content
                .navigationTitle(Text("tab_mediathek"))
                .toolbar { filterToolbar }
                .searchable(
                    text: searchBinding,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: searchPrompt
                ) {
                    if !isOfflineModeActive {
                        SearchSuggestionListView(
                            searchText: viewModel.searchText,
                            history: viewModel.searchHistory,
                            onSuggestionTapped: viewModel.selectHistoryEntry,
                            onSubmit: viewModel.submitSearch,
                            onDeleteHistoryEntry: viewModel.deleteHistoryEntry
                        )
                    }
                }
                .onSubmit(of: .search) {
                    guard networkMonitor.hasConnection else { return }
                    if hasConnectionTimedOut {
                        resetConnectionTimeoutState()
                    }
                    viewModel.submitSearch()
                }
        }
    }

    private var filterToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showFilters = true
            } label: {
                Image(systemName: viewModel.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(Text("mediathek_filter_open_accessibility"))
            .disabled(!networkMonitor.hasConnection)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isOfflineModeActive {
            offlineContent(includeInlineSearch: usesInlineSearch)
        } else {
            onlineContent(includeInlineSearch: usesInlineSearch)
        }
    }

    private var isOfflineModeActive: Bool {
        hasConnectionTimedOut || !networkMonitor.hasConnection
    }

    private func onlineContent(includeInlineSearch: Bool) -> some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if includeInlineSearch {
                        inlineSearchBar
                    }

                    if viewModel.hasActiveFilters {
                        ActiveFiltersView(viewModel: viewModel)
                    }

                    if let info = viewModel.queryInfo {
                        QueryInfoSummaryView(info: info)
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.shows) { show in
                            showCard(for: show)
                                .onAppear { viewModel.loadMoreIfNeeded(currentItem: show) }
                        }

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    if viewModel.errorMessage != nil {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: String(localized: "mediathek_no_results_title"),
                            message: String(localized: "mediathek_no_results_message"),
                            actionTitle: String(localized: "retry")
                        ) {
                            Task { await viewModel.refresh() }
                        }
                        .frame(maxWidth: .infinity)
                    } else if viewModel.shows.isEmpty && !viewModel.isInitialLoading {
                        if !hasCommittedQuery {
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: String(localized: "mediathek_prompt_search_title"),
                                message: String(localized: "mediathek_prompt_search_message")
                            )
                            .frame(maxWidth: .infinity)
                        } else {
                            EmptyStateView(
                                icon: "exclamationmark.magnifyingglass",
                                title: String(localized: "mediathek_no_results_title"),
                                message: String(localized: "mediathek_no_results_adjust")
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, includeInlineSearch ? 8 : 16)
                .padding(.bottom, 32)
                .frame(maxWidth: includeInlineSearch ? 900 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                await viewModel.refresh()
            }

            if viewModel.isInitialLoading && viewModel.shows.isEmpty {
                ProgressView(String(localized: "mediathek_initial_loading"))
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func offlineContent(includeInlineSearch: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if includeInlineSearch {
                    inlineSearchBar
                }

                EmptyStateView(
                    icon: "wifi.slash",
                    title: String(localized: "mediathek_offline_title"),
                    message: String(localized: "mediathek_offline_message"),
                    actionTitle: String(localized: "retry"),
                    action: retryConnectionAttempt
                )
                .frame(maxWidth: .infinity)

                if !offlineFilteredDownloads.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(offlineFilteredDownloads) { persisted in
                            PersistedShowCard(persisted: persisted, allowDownloadDeletion: true)
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 16)
            .frame(maxWidth: includeInlineSearch ? 840 : .infinity)
            .frame(maxWidth: .infinity)
        }
    }

    private var offlineFilteredDownloads: [PersistedMediathekShow] {
        let trimmedQuery = offlineSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return repo.downloads }
        let normalizedQuery = Self.normalized(trimmedQuery)
        return repo.downloads.filter { persisted in
            let show = persisted.show
            return [show.title, show.topic, show.channel, show.description ?? ""]
                .map(Self.normalized)
                .contains(where: { $0.contains(normalizedQuery) })
        }
    }

    nonisolated private static func normalized(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private var searchBinding: Binding<String> {
        networkMonitor.hasConnection ? $viewModel.searchText : $offlineSearchText
    }

    private var searchPrompt: Text {
        Text(isOfflineModeActive ? "mediathek_search_prompt_offline" : "mediathek_search_prompt_online")
    }

    private var trimmedSearchInput: String {
        viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var committedQueryText: String {
        viewModel.committedQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCommittedQuery: Bool {
        !committedQueryText.isEmpty
    }

    private var shouldShowInlineSuggestions: Bool {
        usesInlineSearch
            && !isOfflineModeActive
            && trimmedSearchInput != committedQueryText
            && (!viewModel.searchHistory.isEmpty || !trimmedSearchInput.isEmpty)
    }

    private var usesInlineSearch: Bool {
        horizontalSizeClass == .regular
    }

    private var usesSheetDetailPresentation: Bool {
        horizontalSizeClass == .regular
    }

    private var inlineSearchBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)

                    TextField("", text: searchBinding, prompt: searchPrompt)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.search)
                        .onSubmit {
                            guard networkMonitor.hasConnection else { return }
                            if hasConnectionTimedOut {
                                resetConnectionTimeoutState()
                            }
                            viewModel.submitSearch()
                            dismissKeyboard()
                        }

                    if !searchBinding.wrappedValue.isEmpty {
                        Button {
                            searchBinding.wrappedValue = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(color: Color.black.opacity(0.08), radius: 22, x: 0, y: 12)
                )

            }

            if isOfflineModeActive {
                Text("mediathek_offline_results_note")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if shouldShowInlineSuggestions {
                InlineSearchSuggestionList(
                    searchText: viewModel.searchText,
                    history: viewModel.searchHistory,
                    onSuggestionTapped: viewModel.selectHistoryEntry,
                    onSubmit: viewModel.submitSearch,
                    onDeleteHistoryEntry: viewModel.deleteHistoryEntry
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func showCard(for show: MediathekShow) -> some View {
        if usesSheetDetailPresentation {
            Button {
                sheetShow = show
            } label: {
                MediathekShowCard(show: show)
            }
            .buttonStyle(PlainButtonStyle())
        } else {
            NavigationLink(destination: MediathekDetailView(show: show)) {
                MediathekShowCard(show: show)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func retryConnectionAttempt() {
        resetConnectionTimeoutState()
        networkMonitor.retryConnectionCheck()
        guard networkMonitor.hasConnection else { return }
        if !viewModel.searchText.isEmpty {
            Task { await viewModel.refresh() }
            startConnectionTimeout()
        }
    }

    private func handleLoadingStateChange(_ isLoading: Bool) {
        guard networkMonitor.hasConnection else {
            resetConnectionTimeoutState()
            return
        }
        if isLoading {
            startConnectionTimeout()
        } else {
            resetConnectionTimeoutState()
        }
    }

    private func startConnectionTimeout() {
        guard connectionTimeoutTask == nil else { return }
        hasConnectionTimedOut = false
        connectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled else { return }
            hasConnectionTimedOut = true
            connectionTimeoutTask = nil
        }
    }

    private func resetConnectionTimeoutState() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        hasConnectionTimedOut = false
    }
}

    private struct InlineSearchSuggestionList: View {
        let searchText: String
        let history: [String]
        let onSuggestionTapped: (String) -> Void
        let onSubmit: () -> Void
        let onDeleteHistoryEntry: (String) -> Void

        private var trimmedSearchText: String {
            searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var additionalSuggestions: [String] {
            if trimmedSearchText.isEmpty {
                return Array(history.dropFirst())
            }

            return history.filter { entry in
                entry.range(of: trimmedSearchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                if !trimmedSearchText.isEmpty {
                    suggestionSection(title: "mediathek_suggestion_section_single") {
                        InlineSuggestionRow(
                            title: String.localizedStringWithFormat(
                                String(localized: "mediathek_suggestion_search_for"),
                                trimmedSearchText
                            ),
                            icon: "magnifyingglass",
                            action: onSubmit,
                            deleteAction: nil
                        )
                    }
                } else if let lastQuery = history.first {
                    suggestionSection(title: "mediathek_suggestion_section_last") {
                        InlineSuggestionRow(
                            title: lastQuery,
                            icon: "clock.arrow.circlepath",
                            action: { onSuggestionTapped(lastQuery) },
                            deleteAction: { onDeleteHistoryEntry(lastQuery) }
                        )
                    }
                }

                if !additionalSuggestions.isEmpty {
                    suggestionSection(title: trimmedSearchText.isEmpty ? "mediathek_suggestion_section_history" : "mediathek_suggestion_section_matches") {
                        ForEach(Array(additionalSuggestions.enumerated()), id: \.element) { index, entry in
                            if index > 0 {
                                Divider()
                                    .padding(.leading, 30)
                                    .padding(.vertical, 4)
                                    .opacity(0.35)
                            }
                            InlineSuggestionRow(
                                title: entry,
                                icon: "text.magnifyingglass",
                                action: { onSuggestionTapped(entry) },
                                deleteAction: { onDeleteHistoryEntry(entry) }
                            )
                        }
                    }
                } else if history.isEmpty && trimmedSearchText.isEmpty {
                    suggestionSection(title: "mediathek_suggestion_section_history") {
                        Text("mediathek_suggestion_history_empty")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.08), radius: 22, x: 0, y: 12)
            )
        }

        @ViewBuilder
        private func suggestionSection<Content: View>(title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                content()
            }
        }
    }

    private struct InlineSuggestionRow: View {
        let title: String
        let icon: String
        let action: () -> Void
        let deleteAction: (() -> Void)?

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                Text(title)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                if let deleteAction {
                    Button(role: .destructive) {
                        deleteAction()
                    } label: {
                        Image(systemName: "trash")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .accessibilityLabel(Text("mediathek_history_delete_accessibility"))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
        }
    }

struct SearchSuggestionListView: View {
    let searchText: String
    let history: [String]
    let onSuggestionTapped: (String) -> Void
    let onSubmit: () -> Void
    let onDeleteHistoryEntry: (String) -> Void

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var additionalSuggestions: [String] {
        if trimmedSearchText.isEmpty {
            return Array(history.dropFirst())
        }

        return history.filter { entry in
            entry.range(of: trimmedSearchText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        if !trimmedSearchText.isEmpty {
            Button(action: onSubmit) {
                Label(
                    String.localizedStringWithFormat(
                        String(localized: "mediathek_suggestion_search_for"),
                        trimmedSearchText
                    ),
                    systemImage: "magnifyingglass"
                )
            }
        } else if let lastQuery = history.first {
            Section("mediathek_suggestion_section_last") {
                Button {
                    onSuggestionTapped(lastQuery)
                } label: {
                    Label(lastQuery, systemImage: "clock.arrow.circlepath")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        onDeleteHistoryEntry(lastQuery)
                    } label: {
                        Label("mediathek_history_delete", systemImage: "trash")
                    }
                }
            }
        }

        if !additionalSuggestions.isEmpty {
            Section(trimmedSearchText.isEmpty ? "mediathek_suggestion_section_history" : "mediathek_suggestion_section_matches") {
                ForEach(additionalSuggestions, id: \.self) { entry in
                    Button {
                        onSuggestionTapped(entry)
                    } label: {
                        Label(entry, systemImage: "text.magnifyingglass")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDeleteHistoryEntry(entry)
                        } label: {
                            Label("mediathek_history_delete", systemImage: "trash")
                        }
                    }
                }
            }
        } else if history.isEmpty {
            Text("mediathek_suggestion_history_empty")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct MediathekShowCard: View {
    let show: MediathekShow
    @EnvironmentObject var repo: MediathekRepository
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ZStack(alignment: .bottomTrailing) {
                    VideoThumbnailView(
                        url: show.preferredThumbnailURL,
                        cornerRadius: 8,
                        placeholderIcon: nil
                    )
                    .frame(width: 120, height: 68)

                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                        .padding(6)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(show.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundColor(.primary)
                    
                    Text(show.topic)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    HStack {
                        Label(show.channel, systemImage: "tv")
                        Spacer()
                        Label(show.formattedDuration, systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { repo.toggleBookmark(show: show) }) {
                    Image(systemName: repo.isBookmarked(apiId: show.id) ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            if let description = show.description {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
    }
}

struct FilterView: View {
    @State private var selectedChannels: Set<MediathekChannel>
    @State private var minDuration: Int?
    @State private var maxDuration: Int?
    let onApply: (Set<MediathekChannel>, Int?, Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        initialChannels: Set<MediathekChannel>,
        initialMinDuration: Int?,
        initialMaxDuration: Int?,
        onApply: @escaping (Set<MediathekChannel>, Int?, Int?) -> Void
    ) {
        _selectedChannels = State(initialValue: initialChannels)
        _minDuration = State(initialValue: initialMinDuration)
        _maxDuration = State(initialValue: initialMaxDuration)
        self.onApply = onApply
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("mediathek_filter_channels")) {
                    ForEach(MediathekChannel.allCases, id: \.rawValue) { channel in
                        Toggle(channel.rawValue, isOn: Binding(
                            get: { selectedChannels.contains(channel) },
                            set: { isSelected in
                                if isSelected {
                                    selectedChannels.insert(channel)
                                } else {
                                    selectedChannels.remove(channel)
                                }
                            }
                        ))
                    }
                }

                Section(header: Text("mediathek_filter_duration")) {
                    HStack {
                        Text("mediathek_filter_min")
                        TextField("0", value: $minDuration, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }

                    HStack {
                        Text("mediathek_filter_max")
                        TextField("120", value: $maxDuration, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
            }
            .navigationTitle(Text("mediathek_filter_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "mediathek_filter_reset")) {
                        selectedChannels.removeAll()
                        minDuration = nil
                        maxDuration = nil
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "mediathek_filter_apply")) {
                        onApply(selectedChannels, minDuration, maxDuration)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ActiveFiltersView: View {
    @ObservedObject var viewModel: MediathekSearchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("mediathek_active_filters_title")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.selectedChannels.sorted { $0.rawValue < $1.rawValue }, id: \.self) { channel in
                        FilterChip(label: channel.rawValue) {
                            viewModel.removeChannel(channel)
                        }
                    }

                    if let min = viewModel.minDurationMinutes {
                        FilterChip(
                            label: String.localizedStringWithFormat(
                                String(localized: "mediathek_filter_min_chip"),
                                min
                            )
                        ) {
                            viewModel.clearMinDuration()
                        }
                    }

                    if let max = viewModel.maxDurationMinutes {
                        FilterChip(
                            label: String.localizedStringWithFormat(
                                String(localized: "mediathek_filter_max_chip"),
                                max
                            )
                        ) {
                            viewModel.clearMaxDuration()
                        }
                    }

                    Button(String(localized: "mediathek_filter_reset")) {
                        viewModel.resetFilters()
                    }
                    .font(.caption.bold())
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct FilterChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.primary)
            Button(action: action) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(.systemGray5))
        .clipShape(Capsule())
    }
}

struct QueryInfoSummaryView: View {
    let info: MediathekAnswer.MediathekResult.QueryInfo

    private var formattedTimestamp: String? {
        guard info.filmlisteTimestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: info.filmlisteTimestamp)
        let output = RelativeDateTimeFormatter()
        output.unitsStyle = .full
        return output.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                String.localizedStringWithFormat(
                    String(localized: "mediathek_query_results"),
                    info.totalResults
                )
            )
                .font(.subheadline)
                .fontWeight(.semibold)

            if let stamp = formattedTimestamp {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "mediathek_query_updated"),
                        stamp
                    )
                )
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String?
    let actionTitle: String?
    var action: (() -> Void)?
    
    init(
        icon: String,
        title: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            
            if let message, !message.isEmpty {
                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

struct MediathekView_Previews: PreviewProvider {
    static var previews: some View {
        MediathekView()
            .environmentObject(MediathekRepository())
            .environmentObject(NetworkMonitor.shared)
    }
}
