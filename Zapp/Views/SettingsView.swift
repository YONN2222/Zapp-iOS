import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var repo: MediathekRepository
    @EnvironmentObject private var channelRepo: ChannelRepository
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showingCacheClearedAlert = false
    @State private var showingDownloadsClearedAlert = false
    @State private var showingHistoryClearedAlert = false
    @State private var pendingDestructiveAction: DestructiveAction?
    @State private var appVersionValue = SettingsView.readAppVersion()
    @State private var appBuildValue = SettingsView.readAppBuild()

    private let iosRepoURL = URL(string: "https://github.com/YONN2222/zapp-iOS")!
    private let androidRepoURL = URL(string: "https://github.com/mediathekview/zapp")!

    var body: some View {
        NavigationView {
            Form {
                appearanceSection
                qualitySection
                mediathekSection
                liveTvSection
                storageSection
                communitySection
                aboutSection
            }
            .navigationTitle(Text("settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "settings_done")) { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $pendingDestructiveAction) { action in
            DestructiveConfirmationView(
                action: action,
                onDismiss: { pendingDestructiveAction = nil },
                onConfirm: {
                    handleDestructiveAction(action)
                    pendingDestructiveAction = nil
                }
            )
        }
        .alert(String(localized: "settings_cache_cleared_title"), isPresented: $showingCacheClearedAlert) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text("settings_cache_cleared_message")
        }
        .alert(String(localized: "settings_downloads_cleared_title"), isPresented: $showingDownloadsClearedAlert) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text("settings_downloads_cleared_message")
        }
        .alert(String(localized: "settings_history_cleared_title"), isPresented: $showingHistoryClearedAlert) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text("settings_history_cleared_message")
        }
        .optionalPreferredColorScheme(settings.preferredColorScheme)
        .onAppear {
            appVersionValue = SettingsView.readAppVersion()
            appBuildValue = SettingsView.readAppBuild()
        }
    }

    private var appearanceSection: some View {
        Section(String(localized: "settings_appearance")) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRowLabel(
                    title: String(localized: "settings_app_design_title"),
                    description: String(localized: "settings_app_design_description")
                )

                Picker(String(localized: "settings_app_design_title"), selection: $settings.colorSchemePreference) {
                    ForEach(AppSettings.ColorSchemePreference.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 2)
        }
    }

    private var qualitySection: some View {
        Section(String(localized: "settings_streaming_quality")) {
            qualityPickerRow(
                title: String(localized: "settings_stream_quality_wifi_title"),
                description: String(localized: "settings_stream_quality_wifi_description"),
                selection: $settings.streamQualityWifi
            )

            qualityPickerRow(
                title: String(localized: "settings_stream_quality_cellular_title"),
                description: String(localized: "settings_stream_quality_cellular_description"),
                selection: $settings.streamQualityCellular
            )
        }
    }

    private var storageSection: some View {
        Section(String(localized: "settings_storage_section")) {
            Toggle(isOn: $settings.downloadOverWifiOnly) {
                SettingsRowLabel(
                    title: String(localized: "settings_download_wifi_only_title"),
                    description: String(localized: "settings_download_wifi_only_description")
                )
            }

            Button(role: .destructive) {
                pendingDestructiveAction = .deleteDownloads(count: repo.downloads.count)
            } label: {
                SettingsRowLabel(
                    title: String(localized: "settings_delete_downloads_title"),
                    description: downloadDeletionDescription
                )
            }
            .disabled(repo.downloads.isEmpty)

            Button(role: .destructive) {
                pendingDestructiveAction = .clearCache
            } label: {
                SettingsRowLabel(
                    title: String(localized: "settings_clear_cache_title"),
                    description: String(localized: "settings_clear_cache_description")
                )
            }
            .accessibilityIdentifier("settings-clear-thumbnail-cache")

            Button(role: .destructive) {
                pendingDestructiveAction = .clearSearchHistory
            } label: {
                SettingsRowLabel(
                    title: String(localized: "settings_history_reset_title"),
                    description: String(localized: "settings_history_reset_description")
                )
            }
        }
    }

    private var mediathekSection: some View {
        Section(String(localized: "settings_mediathek_section")) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsRowLabel(
                    title: String(localized: "settings_mediathek_api_title"),
                    description: String(localized: "settings_mediathek_api_description")
                )

                if let url = URL(string: "https://mediathekview.de") {
                    Link(destination: url) {
                        HStack {
                            Text(url.absoluteString)
                                .font(.body)
                                .foregroundColor(.accentColor)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings-mediathek-link")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var communitySection: some View {
        Section(String(localized: "settings_community_section")) {
            Link(destination: iosRepoURL) {
                SettingsRowLabel(
                    title: String(localized: "settings_community_ios_title"),
                    description: String(localized: "settings_community_ios_description")
                )
            }

            Link(destination: androidRepoURL) {
                SettingsRowLabel(
                    title: String(localized: "settings_community_android_title"),
                    description: String(localized: "settings_community_android_description")
                )
            }
        }
    }

    private var aboutSection: some View {
        Section(String(localized: "settings_about")) {
            SettingsInfoRow(title: String(localized: "settings_version"), value: appVersionValue)
            SettingsInfoRow(title: String(localized: "settings_build"), value: appBuildValue)
        }
    }

    private var downloadDeletionDescription: String {
        let count = repo.downloads.count
        if count == 0 {
            return String(localized: "settings_delete_downloads_description_empty")
        } else if count == 1 {
            return String(localized: "settings_delete_downloads_description_single")
        } else {
            return String.localizedStringWithFormat(
                String(localized: "settings_delete_downloads_description_plural"),
                count
            )
        }
    }

    private static func readAppVersion() -> String {
        if let value = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !value.isEmpty {
            return value
        }
        return "–"
    }

    private static func readAppBuild() -> String {
        if let value = Bundle.main.infoDictionary?[kCFBundleVersionKey as String] as? String, !value.isEmpty {
            return value
        }
        return "–"
    }

    private func handleDestructiveAction(_ action: DestructiveAction) {
        switch action {
        case .deleteDownloads:
            deleteAllDownloads()
        case .clearCache:
            clearThumbnailCache()
        case .clearSearchHistory:
            clearSearchHistory()
        case .resetChannelOrder:
            channelRepo.resetChannelCustomizations()
        }
    }

    private func clearThumbnailCache() {
        Task {
            await VideoThumbnailService.shared.clearCache()
            await MainActor.run {
                showingCacheClearedAlert = true
            }
        }
    }

    private func deleteAllDownloads() {
        Task { @MainActor in
            PersistenceManager.shared.deleteAllDownloads()
            repo.loadPersistedData()
            showingDownloadsClearedAlert = true
        }
    }

    private func clearSearchHistory() {
        SearchHistoryStore.shared.clear()
        showingHistoryClearedAlert = true
    }

    private var liveTvSection: some View {
        Section(String(localized: "settings_live_tv_section")) {
            Button {
                pendingDestructiveAction = .resetChannelOrder
            } label: {
                SettingsRowLabel(
                    title: String(localized: "settings_reset_channels_title"),
                    description: String(localized: "settings_reset_channels_description")
                )
            }
            .accessibilityIdentifier("settings-reset-channel-order")
        }
    }

    private func qualityPickerRow(
        title: String,
        description: String,
        selection: Binding<MediathekShow.Quality>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRowLabel(title: title, description: description)

            Menu {
                ForEach(MediathekShow.Quality.allCases, id: \.self) { quality in
                    Button {
                        selection.wrappedValue = quality
                    } label: {
                        HStack {
                            Text(quality.localizedName)
                            Spacer()
                            if selection.wrappedValue == quality {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selection.wrappedValue.localizedName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }
}

private enum DestructiveAction: Identifiable, Equatable {
    case deleteDownloads(count: Int)
    case clearCache
    case clearSearchHistory
    case resetChannelOrder

    var id: String {
        switch self {
        case let .deleteDownloads(count):
            return "deleteDownloads_\(count)"
        case .clearCache:
            return "clearCache"
        case .clearSearchHistory:
            return "clearSearchHistory"
        case .resetChannelOrder:
            return "resetChannelOrder"
        }
    }

    var title: String {
        switch self {
        case .deleteDownloads:
            return String(localized: "settings_delete_downloads_title")
        case .clearCache:
            return String(localized: "settings_clear_cache_title")
        case .clearSearchHistory:
            return String(localized: "settings_history_reset_title")
        case .resetChannelOrder:
            return String(localized: "settings_reset_channels_title")
        }
    }

    var message: String {
        switch self {
        case let .deleteDownloads(count):
            if count <= 0 {
                return String(localized: "settings_delete_downloads_message_empty")
            }
            if count == 1 {
                return String(localized: "settings_delete_downloads_message_single")
            }
            return String.localizedStringWithFormat(
                String(localized: "settings_delete_downloads_message_plural"),
                count
            )
        case .clearCache:
            return String(localized: "settings_clear_cache_confirmation")
        case .clearSearchHistory:
            return String(localized: "settings_history_reset_confirmation")
        case .resetChannelOrder:
            return String(localized: "settings_reset_channels_confirmation")
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .deleteDownloads:
            return String(localized: "settings_delete_downloads_confirm" )
        case .clearCache:
            return String(localized: "settings_clear_cache_confirm" )
        case .clearSearchHistory:
            return String(localized: "settings_history_reset_confirm" )
        case .resetChannelOrder:
            return String(localized: "settings_reset_channels_confirm" )
        }
    }
}

private struct DestructiveConfirmationView: View {
    let action: DestructiveAction
    let onDismiss: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 52))
                        .foregroundColor(.orange)
                        .symbolEffect(.pulse)
                    Text(action.title)
                        .font(.title)
                        .bold()
                        .multilineTextAlignment(.center)
                    Text(action.message)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    Button(role: .destructive) {
                        onConfirm()
                    } label: {
                        Text(action.primaryButtonTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button(role: .cancel) {
                        onDismiss()
                    } label: {
                        Text(String(localized: "cancel"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(.horizontal)
                Spacer()
            }
            .padding(.vertical, 24)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "close")) { onDismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body)
            Text(description)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(MediathekRepository())
    }
}
