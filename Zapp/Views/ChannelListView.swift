import SwiftUI
import Combine
import UIKit
import AVFoundation

struct ChannelListView: View {
    @EnvironmentObject var repo: ChannelRepository
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var nowDate = Date()
    @State private var activeOverflowSheet: OverflowSheet?
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if networkMonitor.hasConnection {
                channelList
            } else {
                EmptyStateView(
                    icon: "wifi.slash",
                    title: String(localized: "channel_no_connection_title"),
                    message: String(localized: "channel_no_connection_message"),
                    actionTitle: String(localized: "retry"),
                    action: {
                        networkMonitor.retryConnectionCheck()
                        Task { await refreshChannels() }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(Text("channel_list_title"))
        .onReceive(timer) { now in
            nowDate = now
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        NotificationCenter.default.post(name: .navigateToDownloadsTab, object: nil)
                    } label: {
                        Label("channel_menu_open_downloads", systemImage: "arrow.down.circle")
                    }

                        .listRowInsets(EdgeInsets(top: 10, leading: 28, bottom: 10, trailing: 20))
                    Button {
                        activeOverflowSheet = .reorder
                    } label: {
                        Label("channel_menu_reorder", systemImage: "line.3.horizontal.decrease")
                    }

                    Button {
                        activeOverflowSheet = .settings
                    } label: {
                        Label("settings_title", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
                .accessibilityLabel(Text("channel_overflow_accessibility"))
            }
        }
        .sheet(item: $activeOverflowSheet) { destination in
            switch destination {
            case .settings:
                SettingsView()
            case .reorder:
                ChannelOrderEditorView()
            }
        }
    }

    private var channelList: some View {
        Group {
            if usesGridLayout {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(repo.channels) { channel in
                            ChannelGridTileView(
                                channel: channel,
                                nowPlaying: repo.nowPlayingState(for: channel.id),
                                nowDate: nowDate
                            )
                            .task(id: taskIdentifier(for: channel.id)) {
                                await repo.ensureNowPlaying(for: channel.id, priority: .userInitiated)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .background(Color(.systemGroupedBackground))
                .refreshable {
                    await refreshChannels()
                }
            } else {
                List {
                    ForEach(repo.channels) { channel in
                        ChannelRowView(
                            channel: channel,
                            nowPlaying: repo.nowPlayingState(for: channel.id),
                            nowDate: nowDate
                        )
                        .task(id: taskIdentifier(for: channel.id)) {
                            await repo.ensureNowPlaying(for: channel.id, priority: .userInitiated)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await refreshChannels()
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: usesGridLayout)
    }

    private func refreshChannels() async {
        await repo.refreshFromApi()
        await MainActor.run {
            triggerRefreshHaptic()
        }
    }

    private func triggerRefreshHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    private func taskIdentifier(for channelId: String) -> String {
        "\(channelId)-\(repo.nowPlayingGeneration)"
    }

    private var usesGridLayout: Bool {
        horizontalSizeClass == .regular
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 320, maximum: 420), spacing: 20)]
    }
}

private enum OverflowSheet: Identifiable {
    case settings
    case reorder

    var id: Int {
        switch self {
        case .settings: return 0
        case .reorder: return 1
        }
    }
}

struct ChannelOrderEditorView: View {
    @EnvironmentObject private var channelRepo: ChannelRepository
    @Environment(\.dismiss) private var dismiss
    @State private var editableChannels: [EditableChannel] = []

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("channel_order_footer")) {
                    ForEach($editableChannels) { $channel in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("channel_order_name_placeholder", text: $channel.customName)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(true)

                            if let subtitle = channel.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if channel.showsDefaultHint {
                                Text(
                                    String(
                                        format: String(localized: "channel_order_default_hint"),
                                        channel.defaultName
                                    )
                                )
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onMove(perform: move)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .navigationTitle(Text("channel_order_title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "save"), action: save)
                        .disabled(editableChannels.isEmpty)
                }
            }
            .task {
                if editableChannels.isEmpty {
                    loadChannels()
                }
            }
        }
    }

    private func loadChannels() {
        editableChannels = channelRepo.channels.map { channel in
            EditableChannel(
                id: channel.id,
                defaultName: channel.defaultName,
                customName: channelRepo.customName(for: channel.id) ?? channel.name,
                subtitle: channel.subtitle
            )
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        editableChannels.move(fromOffsets: source, toOffset: destination)
    }

    private func save() {
        let order = editableChannels.map(\.id)
        var customNames: [String: String] = [:]

        for channel in editableChannels {
            let trimmed = channel.customName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != channel.defaultName {
                customNames[channel.id] = trimmed
            }
        }

        channelRepo.saveChannelCustomizations(order: order, customNames: customNames)
        dismiss()
    }
}

private struct EditableChannel: Identifiable {
    let id: String
    let defaultName: String
    var customName: String
    let subtitle: String?

    var showsDefaultHint: Bool {
        customName.trimmingCharacters(in: .whitespacesAndNewlines) != defaultName
    }
}

private struct ChannelRowView: View {
    let channel: Channel
    @ObservedObject var nowPlaying: ChannelNowPlayingState
    let nowDate: Date
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 16) {
            ChannelLogoView(channel: channel)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                if let liveTitle = nowPlaying.title {
                    Text(liveTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if nowPlaying.isLoading {
                    LoadingSubtitleView()
                } else if let subtitle = channel.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let progress = progressValue {
                    ChannelProgressView(progress: progress)
                        .padding(.top, 4)
                } else if nowPlaying.isLoading {
                    ChannelProgressPlaceholder()
                        .padding(.top, 4)
                } else {
                    ChannelProgressSpacer()
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 12)
            Button {
                showingDetails = true
            } label: {
                ChannelInfoButton()
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("channel_show_details_accessibility"))
        }
        .padding(.vertical, 6)
        .opacity(canPlay ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture {
            guard canPlay else { return }
            PlayerPresentationManager.shared.presentChannel(channel)
        }
        .sheet(isPresented: $showingDetails) {
            ChannelLiveDetailSheet(
                channel: channel,
                nowPlaying: nowPlaying,
                nowDate: nowDate,
                canPlay: canPlay,
                playAction: {
                    guard canPlay else { return }
                    PlayerPresentationManager.shared.presentChannel(channel)
                }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var progressValue: Double? {
        guard let range = nowPlaying.range else { return nil }
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        guard duration > 10 else { return nil }
        let elapsed = nowDate.timeIntervalSince(range.lowerBound)
        guard elapsed >= 0 else { return 0 }
        if elapsed >= duration { return 1 }
        return elapsed / duration
    }

    private var canPlay: Bool {
        channel.streamUrl != nil
    }
}

private struct ChannelGridTileView: View {
    let channel: Channel
    @ObservedObject var nowPlaying: ChannelNowPlayingState
    let nowDate: Date
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                ChannelLogoView(channel: channel)
                    .frame(width: 104, height: 68, alignment: .leading)
                Spacer()
                Button {
                    showingDetails = true
                } label: {
                    ChannelInfoButton()
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("channel_show_details_accessibility"))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(channel.name)
                    .font(.headline)
                    .foregroundColor(.primary)

                if let liveTitle = nowPlaying.title {
                    Text(liveTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else if nowPlaying.isLoading {
                    LoadingSubtitleView()
                } else if let subtitle = channel.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                if let progress = progressValue {
                    ChannelProgressView(progress: progress)
                        .padding(.top, 6)
                } else if nowPlaying.isLoading {
                    ChannelProgressPlaceholder()
                        .padding(.top, 6)
                } else {
                    ChannelProgressSpacer()
                        .padding(.top, 6)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { playChannelIfPossible() }
        .sheet(isPresented: $showingDetails) {
            ChannelLiveDetailSheet(
                channel: channel,
                nowPlaying: nowPlaying,
                nowDate: nowDate,
                canPlay: canPlay,
                playAction: playChannelIfPossible
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .opacity(canPlay ? 1 : 0.45)
    }

    private func playChannelIfPossible() {
        guard canPlay else { return }
        PlayerPresentationManager.shared.presentChannel(channel)
    }

    private var progressValue: Double? {
        guard let range = nowPlaying.range else { return nil }
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        guard duration > 10 else { return nil }
        let elapsed = nowDate.timeIntervalSince(range.lowerBound)
        guard elapsed >= 0 else { return 0 }
        if elapsed >= duration { return 1 }
        return elapsed / duration
    }

    private var canPlay: Bool {
        channel.streamUrl != nil
    }
}

private struct ChannelProgressView: View {
    let progress: Double

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.9), .accentColor.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * clampedProgress)
                    .animation(.easeInOut(duration: 0.4), value: clampedProgress)
            }
        }
        .frame(height: 6)
    }
}

private struct ChannelProgressPlaceholder: View {
    @State private var animate = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * 0.35)
                    .offset(x: animate ? geometry.size.width * 0.65 : 0)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: animate)
            }
        }
        .frame(height: 6)
        .onAppear { animate = true }
    }
}

private struct ChannelProgressSpacer: View {
    var body: some View {
        Capsule()
            .fill(Color.clear)
            .frame(height: 6)
    }
}

private struct LoadingSubtitleView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
            Text("channel_loading_now_playing")
        }
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
}

private struct ChannelInfoButton: View {
    var body: some View {
        Circle()
            .fill(Color.playerControlFill)
            .overlay(
                Circle()
                    .stroke(Color.playerControlBorder, lineWidth: 0.8)
            )
            .overlay(
                Image(systemName: "info")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color.playerControlForeground)
            )
            .accessibilityHidden(true)
    }
}

private struct ChannelLiveDetailSheet: View {
    let channel: Channel
    @ObservedObject var nowPlaying: ChannelNowPlayingState
    let nowDate: Date
    let canPlay: Bool
    let playAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ChannelLivePreviewCard(channel: channel, canPlay: canPlay, playAction: playAction)

                VStack(alignment: .leading, spacing: 6) {
                    Text(nowPlaying.title ?? channel.name)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.leading)

                    Text(channel.name)
                        .font(.headline)
                        .foregroundColor(.secondary)

                    if let description = nowPlaying.showDescription, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let subtitle = channel.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                timingSection

                if let progress = progressValue {
                    ChannelProgressView(progress: progress)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemBackground))
    }

    @ViewBuilder
    private var timingSection: some View {
        if let range = nowPlaying.range {
            VStack(alignment: .leading, spacing: 12) {
                timingRow(icon: "play.circle.fill", title: "channel_timing_started", value: formattedTime(range.lowerBound))
                timingRow(icon: "stop.circle.fill", title: "channel_timing_ends", value: formattedTime(range.upperBound))
                if let remaining = remainingText {
                    timingRow(icon: "hourglass.bottomhalf.filled", title: "channel_timing_remaining", value: remaining)
                }
            }
        } else if nowPlaying.isLoading {
            Label("channel_loading_now_playing", systemImage: "clock.arrow.circlepath")
                .font(.subheadline)
                .foregroundColor(.secondary)
        } else {
            Label("channel_timing_unavailable", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func timingRow(icon: String, title: LocalizedStringKey, value: String?) -> some View {
        if let value {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.body.weight(.semibold))
                }
            }
        }
    }

    private var progressValue: Double? {
        guard let range = nowPlaying.range else { return nil }
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        guard duration > 10 else { return nil }
        let elapsed = nowDate.timeIntervalSince(range.lowerBound)
        guard elapsed >= 0 else { return 0 }
        if elapsed >= duration { return 1 }
        return elapsed / duration
    }

    private var remainingText: String? {
        guard let endDate = nowPlaying.range?.upperBound else { return nil }
        let seconds = endDate.timeIntervalSince(nowDate)
        if seconds <= 30 {
            return String(localized: "channel_remaining_ending_soon")
        }
        let minutes = Int((seconds / 60).rounded(.down))
        if minutes == 1 {
            return String(localized: "channel_remaining_one_minute")
        }
        return String.localizedStringWithFormat(
            String(localized: "channel_remaining_minutes"),
            minutes
        )
    }

    private func formattedTime(_ date: Date) -> String {
        ChannelLiveDetailSheet.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct ChannelLivePreviewCard: View {
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let channel: Channel
    let canPlay: Bool
    let playAction: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            previewSurface
            overlayContent
        }
        .aspectRatio(16/9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            Group {
                if shouldShowBorder {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            if !canPlay {
                Image(systemName: "lock.fill")
                    .font(.callout)
                    .padding(10)
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canPlay else { return }
            playAction()
        }
    }

    private var previewSurface: some View {
        Group {
            if shouldShowPreview, let url = previewURL {
                LivePreviewPlayerView(url: url)
                    .overlay(Color.black.opacity(0.12))
                    .transition(.opacity)
            } else {
                fallbackSurface
            }
        }
    }

    @ViewBuilder
    private var overlayContent: some View {
        if shouldShowPreview {
            VStack(alignment: .leading, spacing: 6) {
                Label("channel_preview_label", systemImage: "wifi")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .labelStyle(.titleAndIcon)
                Text(channel.name)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.2))
                    )
            )
            .padding(16)
        }
    }

    private var fallbackSurface: some View {
        ZStack {
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            ChannelLogoView(channel: channel)
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 8)
        }
    }

    private var shouldShowBorder: Bool {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return false }
        return horizontalSizeClass != .regular
    }

    private var gradientColors: [Color] {
        if let hex = channel.color, let color = Color(hex: hex) {
            return [color.opacity(0.85), color.opacity(0.45)]
        }
        return [Color.blue.opacity(0.6), Color.purple.opacity(0.4)]
    }

    private var shouldShowPreview: Bool {
        networkMonitor.isOnWiFi && canPlay && previewURL != nil
    }

    private var previewURL: URL? {
        channel.streamUrl
    }
}

private struct LivePreviewPlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> LivePreviewPlayerContainer {
        let view = LivePreviewPlayerContainer()
        view.configure(with: url)
        return view
    }

    func updateUIView(_ uiView: LivePreviewPlayerContainer, context: Context) {
        uiView.configure(with: url)
    }

    static func dismantleUIView(_ uiView: LivePreviewPlayerContainer, coordinator: ()) {
        uiView.teardown()
    }
}

private final class LivePreviewPlayerContainer: UIView {
    private var player: AVPlayer?
    private var currentURL: URL?
    private let cornerRadius: CGFloat = 20

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        clipsToBounds = true
        layer.cornerRadius = cornerRadius
        if #available(iOS 13.0, *) {
            layer.cornerCurve = .continuous
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = cornerRadius
    }

    func configure(with url: URL) {
        guard currentURL != url else {
            if player?.rate == 0 {
                player?.play()
            }
            return
        }

        currentURL = url
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredPeakBitRate = 500_000
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()

        guard let playerLayer = layer as? AVPlayerLayer else { return }
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.player = player
        self.player = player
    }

    func teardown() {
        player?.pause()
        (layer as? AVPlayerLayer)?.player = nil
        player = nil
        currentURL = nil
    }

    deinit {
        teardown()
    }
}

private extension Color {
    static var playerControlFill: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.05)
        })
    }

    static var playerControlBorder: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.24)
            : UIColor.black.withAlphaComponent(0.07)
        })
    }

    static var playerControlForeground: Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor.black
        })
    }
}

struct ChannelListView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            ChannelListView()
        }
        .environmentObject(ChannelRepository())
        .environmentObject(NetworkMonitor.shared)
    }
}
