import SwiftUI
import Foundation

struct PersonalView: View {
    @EnvironmentObject var repo: MediathekRepository
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("personal_continue_watching").tag(0)
                Text("personal_bookmarks").tag(1)
                if !FeatureFlags.disableDownloads {
                    Text("personal_downloads").tag(2)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal, usesCenteredLayout ? 24 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            TabView(selection: $selectedTab) {
                ContinueWatchingListView()
                    .tag(0)

                BookmarksListView()
                    .tag(1)

                if !FeatureFlags.disableDownloads {
                    DownloadsListView()
                        .tag(2)
                }
            }
            .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
            .padding(.horizontal, usesCenteredLayout ? 12 : 0)
        }
        .frame(maxWidth: usesCenteredLayout ? 900 : .infinity)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDownloadsTab)) { _ in
            if !FeatureFlags.disableDownloads {
                selectedTab = 2
            } else {
                selectedTab = 1
            }
        }
        .navigationTitle(Text("tab_personal"))
    }

    private var usesCenteredLayout: Bool {
        horizontalSizeClass == .regular
    }
}

struct DownloadsListView: View {
    @EnvironmentObject var repo: MediathekRepository
    private let gridColumns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 16)]
    
    var body: some View {
        if repo.downloads.isEmpty {
            EmptyStateView(
                icon: "arrow.down.circle",
                title: String(localized: "personal_no_downloads_title"),
                message: String(localized: "personal_no_downloads_message")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(repo.downloads) { persisted in
                        PersistedShowCard(persisted: persisted, allowDownloadDeletion: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct ContinueWatchingListView: View {
    @EnvironmentObject var repo: MediathekRepository
    @EnvironmentObject var networkMonitor: NetworkMonitor
    private let gridColumns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 16)]
    
    var body: some View {
        if !networkMonitor.hasConnection {
            EmptyStateView(
                icon: "wifi.slash",
                title: String(localized: "personal_continue_offline_title"),
                message: String(localized: "personal_continue_offline_message"),
                actionTitle: String(localized: "retry"),
                action: {
                    networkMonitor.retryConnectionCheck()
                }
            )
        } else if repo.continueWatching.isEmpty {
            EmptyStateView(
                icon: "play.circle",
                title: String(localized: "personal_no_continue_title"),
                message: String(localized: "personal_no_continue_message")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(repo.continueWatching) { persisted in
                        PersistedShowCard(
                            persisted: persisted,
                            showProgress: true,
                            allowContinueWatchingDeletion: true
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct BookmarksListView: View {
    @EnvironmentObject var repo: MediathekRepository
    @ObservedObject private var settings = AppSettings.shared
    private let gridColumns = [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 16)]
    
    var body: some View {
        if repo.bookmarks.isEmpty {
            EmptyStateView(
                icon: "bookmark",
                title: String(localized: "personal_no_bookmarks_title"),
                message: String(localized: "personal_no_bookmarks_message")
            )
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(repo.bookmarks) { persisted in
                        PersistedShowCard(
                            persisted: persisted,
                            showProgress: settings.showProgressInBookmarks,
                            allowBookmarkRemoval: true
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct PersistedShowCard: View {
    let persisted: PersistedMediathekShow
    let showProgress: Bool
    let allowDownloadDeletion: Bool
    let allowContinueWatchingDeletion: Bool
    let allowBookmarkRemoval: Bool
    @EnvironmentObject var repo: MediathekRepository
    @Environment(\.colorScheme) private var colorScheme
    @State private var showDownloadNotReadyAlert = false
    @State private var showDetailsSheet = false
    
    init(
        persisted: PersistedMediathekShow,
        showProgress: Bool = false,
        allowDownloadDeletion: Bool = false,
        allowContinueWatchingDeletion: Bool = false,
        allowBookmarkRemoval: Bool = false
    ) {
        self.persisted = persisted
        self.showProgress = showProgress
        self.allowDownloadDeletion = allowDownloadDeletion
        self.allowContinueWatchingDeletion = allowContinueWatchingDeletion
        self.allowBookmarkRemoval = allowBookmarkRemoval
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ZStack(alignment: .bottomTrailing) {
                    VideoThumbnailView(
                        url: persisted.thumbnailSourceURL,
                        cornerRadius: 8,
                        placeholderIcon: "play.rectangle.fill"
                    )
                    .frame(width: 120, height: 68)

                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                        .padding(6)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(persisted.show.title)
                        .font(.headline)
                        .lineLimit(2)
                    
                    Text(persisted.show.topic)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    HStack {
                        Label(persisted.show.channel, systemImage: "tv")
                        Spacer()
                        Label(persisted.show.formattedDuration, systemImage: "clock")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Menu {
                    Button(action: { showDetailsSheet = true }) {
                        Label("show_details", systemImage: "info.circle")
                    }

                    Button(action: { playShow() }) {
                        Label("show_play", systemImage: "play")
                    }
                    .disabled(allowDownloadDeletion && !canPlayDownload)
                    
                    if allowDownloadDeletion {
                        Button(role: .destructive, action: { deleteDownload() }) {
                            Label("download_delete", systemImage: "trash")
                        }
                    }
                    
                    if allowContinueWatchingDeletion {
                        Button(role: .destructive, action: { removeContinueWatchingEntry() }) {
                            Label("personal_continue_remove", systemImage: "text.badge.minus")
                        }
                    }

                    if allowBookmarkRemoval {
                        Button(role: .destructive, action: { removeBookmarkEntry() }) {
                            Label("show_remove_bookmark", systemImage: "bookmark.slash")
                        }
                    } else if persisted.bookmarked {
                        Button(action: { repo.toggleBookmark(show: persisted.show) }) {
                            Label("show_remove_bookmark", systemImage: "bookmark.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .frame(minWidth: 56, minHeight: 56, alignment: .top)
                        .offset(x: 12)
                        .contentShape(Rectangle())
                }
            }
            
            if showProgress && persisted.videoDuration > 0 {
                ProgressView(value: persisted.playbackPosition, total: persisted.videoDuration)
                    .tint(.blue)
                
                HStack {
                    Text(timeString(from: persisted.playbackPosition))
                    Spacer()
                    Text(timeString(from: persisted.videoDuration))
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            
            if allowDownloadDeletion {
                downloadStatusSection
            } else if persisted.downloadStatus == .downloading {
                downloadProgressBlock(message: formattedDownloadingProgress(persisted.downloadProgress))
            }
        }
        .padding()
        .background(cardBackground)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .onTapGesture {
            if allowDownloadDeletion && !canPlayDownload {
                showDownloadNotReadyAlert = true
            } else {
                playShow()
            }
        }
        .alert("download_not_ready_title", isPresented: $showDownloadNotReadyAlert) {
            Button("ok", role: .cancel) { }
        } message: {
            Text("download_not_ready_message")
        }
        .sheet(isPresented: $showDetailsSheet) {
            NavigationStack {
                MediathekDetailView(show: persisted.show)
                    .environmentObject(repo)
            }
        }
    }
    
    @ViewBuilder
    private var downloadStatusSection: some View {
        switch persisted.downloadStatus {
        case .queued:
            downloadProgressBlock(
                message: String.localizedStringWithFormat(
                    String(localized: "download_waiting_progress"),
                    persisted.downloadProgress
                )
            )
        case .downloading:
            if persisted.downloadProgress > 0 {
                downloadProgressBlock(message: formattedDownloadingProgress(persisted.downloadProgress))
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("download_downloading_unmeasured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        case .completed:
            VStack(alignment: .leading, spacing: 4) {
                Label("download_completed", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let sizeLine = downloadSizeLine(includeDownloadedPortion: false) {
                    Text(sizeLine)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("download_failed", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                if let sizeLine = downloadSizeLine(includeDownloadedPortion: false) {
                    Text(sizeLine)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        case .none:
            EmptyView()
        }
    }
    
    @ViewBuilder
    private func downloadProgressBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
                DownloadProgressBar(progress: Double(persisted.downloadProgress) / 100)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func downloadSizeLine(includeDownloadedPortion: Bool) -> String? {
        let downloaded = persisted.downloadedBytes > 0 ? persisted.downloadedBytes : nil
        let total = persisted.resolvedExpectedDownloadBytes
        let formatter = Self.byteFormatter

        if includeDownloadedPortion, let downloaded, let total {
            return String(
                format: String(localized: "download_size_of_total"),
                formatter.string(fromByteCount: downloaded),
                formatter.string(fromByteCount: total)
            )
        }
        if includeDownloadedPortion, let downloaded {
            return String(
                format: String(localized: "download_size_downloaded_only"),
                formatter.string(fromByteCount: downloaded)
            )
        }
        if let total {
            return String(
                format: String(localized: "download_size_total"),
                formatter.string(fromByteCount: total)
            )
        }
        return nil
    }

    private func formattedDownloadingProgress(_ progress: Int) -> String {
        String.localizedStringWithFormat(String(localized: "download_downloading"), progress)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private var canPlayDownload: Bool {
        guard allowDownloadDeletion else { return true }
        return persisted.downloadStatus == .completed && persisted.localVideoURL != nil
    }
    
    private func playShow() {
        if let localURL = persisted.localVideoURL, persisted.downloadStatus == .completed {
            let preferred = AppSettings.shared.preferredQuality(available: persisted.show.supportedQualities)
            PlayerPresentationManager.shared.presentShow(
                persisted.show,
                quality: preferred,
                startTime: persisted.playbackPosition,
                localFileURL: localURL
            )
            return
        }

        if allowDownloadDeletion {
            showDownloadNotReadyAlert = true
            return
        }

        let preferred = AppSettings.shared.preferredQuality(available: persisted.show.supportedQualities)
        PlayerPresentationManager.shared.presentShow(
            persisted.show,
            quality: preferred,
            startTime: persisted.playbackPosition
        )
    }
    
    private func deleteDownload() {
        repo.deleteDownload(apiId: persisted.apiId)
    }
    
    private func removeContinueWatchingEntry() {
        repo.removeContinueWatching(apiId: persisted.apiId)
    }
    
    private func removeBookmarkEntry() {
        repo.removeBookmark(apiId: persisted.apiId)
    }
    
    private func timeString(from seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private var cardBackground: Color {
        if colorScheme == .dark {
            return Color(uiColor: .secondarySystemBackground)
        }
        return Color(.systemBackground)
    }
}

struct PersonalView_Previews: PreviewProvider {
    static var previews: some View {
        PersonalView()
            .environmentObject(MediathekRepository())
            .environmentObject(NetworkMonitor.shared)
    }
}

    private struct DownloadProgressBar: View {
        let progress: Double
        private let minimumFillWidth: CGFloat = 10

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: fillWidth(totalWidth: geometry.size.width))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.2), value: progress)
        }

        private func fillWidth(totalWidth: CGFloat) -> CGFloat {
            guard totalWidth > 0 else { return 0 }
            let clamped = max(0, min(progress, 1))
            guard clamped > 0 else { return 0 }
            return max(CGFloat(clamped) * totalWidth, minimumFillWidth)
        }
    }
