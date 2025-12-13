import SwiftUI
import Combine

@main
struct ZappApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var channelRepo = ChannelRepository()
    @StateObject private var mediathekRepo = MediathekRepository()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            OrientationRootView {
                MainTabView()
                    .environmentObject(channelRepo)
                    .environmentObject(mediathekRepo)
                    .environmentObject(settings)
                    .environmentObject(NetworkMonitor.shared)
            }
            .ignoresSafeArea()
            .optionalPreferredColorScheme(settings.preferredColorScheme)
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var channelRepo: ChannelRepository
    @EnvironmentObject var mediathekRepo: MediathekRepository
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .live
    @State private var showSettings = false
    @State private var showLaunchScreen = true
    @State private var lastSuccessfulSync: Date?
    @State private var forcedSplashOnForeground = false
    @State private var showGeoRestrictionWarning = false
    @State private var geoWarningAcknowledged = false
    @State private var detectedRegionName: String?
    @State private var geoLookupTask: Task<Void, Never>?
    @State private var geoNeedsFreshLookup = true
    @State private var isGeoCheckPending = true
    @State private var geoLookupAttempts = 0
    @AppStorage("geoWarningLastShownAt") private var geoWarningLastShownAt: Double = 0

    private let minimumRefreshInterval: TimeInterval = 30
    private let geoWarningThrottleInterval: TimeInterval = 5 * 60
    private let geoRetryDelay: TimeInterval = 0.8
    private let maxGeoLookupRetries: Int = 2

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ChannelListView()
            }
            .tabItem {
                Label("tab_live", systemImage: "dot.radiowaves.left.and.right")
            }
            .tag(MainTab.live)
            
            NavigationStack {
                MediathekView()
            }
            .tabItem {
                Label("tab_mediathek", systemImage: "film")
            }
            .tag(MainTab.mediathek)
            
            NavigationStack {
                PersonalView()
                    .toolbar { settingsToolbar }
            }
            .tabItem {
                Label("tab_personal", systemImage: "rectangle.stack.person.crop")
            }
            .tag(MainTab.personal)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showGeoRestrictionWarning) {
            GeoRestrictionInfoView(regionDescription: detectedRegionName) {
                acknowledgeGeoRestrictionWarning()
            }
        }
        .onReceive(networkMonitor.$connectionType) { _ in
            evaluateGeoRestrictionIfNeeded()
        }
        .overlay {
            LaunchAnimationView()
                .opacity(showLaunchScreen ? 1 : 0)
                .allowsHitTesting(showLaunchScreen)
                .zIndex(1)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if needsRefresh() {
                forcedSplashOnForeground = true
                showLaunchScreen = true
            }

            resetGeoRestrictionState(forceNetworkLookup: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDownloadsTab)) { _ in
            selectedTab = .personal
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                let willNeedRefresh = needsRefresh()
                forcedSplashOnForeground = willNeedRefresh
                if willNeedRefresh {
                    showLaunchScreen = true
                }
            case .active:
                _ = triggerRefreshIfNeeded()
                forcedSplashOnForeground = false
            default:
                break
            }
        }
        .onChange(of: channelRepo.isSyncing) { _, isSyncing in
            if isSyncing {
                showLaunchScreen = true
            } else {
                lastSuccessfulSync = Date()
                hideLaunchScreenIfReady(immediate: false)
            }
        }
        .onAppear {
            PlayerPresentationManager.shared.register(channelRepository: channelRepo)
            showLaunchScreen = true
            triggerRefreshIfNeeded(force: true)
            resetGeoRestrictionState(forceNetworkLookup: true)
        }
    }

    @ToolbarContentBuilder
    private var settingsToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }
        }
    }

    @discardableResult
    private func triggerRefreshIfNeeded(force: Bool = false) -> Bool {
        let shouldRefresh = force || needsRefresh()
        guard shouldRefresh else {
            hideLaunchScreenIfReady(immediate: forcedSplashOnForeground)
            return false
        }

        showLaunchScreen = true
        refreshDataAfterForeground()
        return true
    }

    private func needsRefresh(at date: Date = Date()) -> Bool {
        guard let lastSuccessfulSync else { return true }
        return date.timeIntervalSince(lastSuccessfulSync) >= minimumRefreshInterval
    }

    private func hideLaunchScreen(immediate: Bool) {
        guard showLaunchScreen else { return }
        if immediate {
            showLaunchScreen = false
        } else {
            withAnimation(.easeOut(duration: 0.55)) {
                showLaunchScreen = false
            }
        }
    }

    private func hideLaunchScreenIfReady(immediate: Bool) {
        guard showLaunchScreen else { return }
        guard !channelRepo.isSyncing, !isGeoCheckPending else { return }
        hideLaunchScreen(immediate: immediate)
    }

    private func refreshDataAfterForeground() {
        Task {
            await channelRepo.refreshFromApi()
            await MainActor.run {
                mediathekRepo.loadPersistedData()
            }
        }
    }

    private func evaluateGeoRestrictionIfNeeded(forceNetworkLookup: Bool = false) {
        guard !geoWarningAcknowledged else {
            return
        }
        guard isGeoCheckPending || geoNeedsFreshLookup else { return }
        let shouldForceLookup = forceNetworkLookup || geoNeedsFreshLookup

        geoLookupTask?.cancel()
        geoLookupTask = Task {
            let remoteCode = await GeoRestrictionService.shared.currentCountryCode(forceRefresh: shouldForceLookup)
            await MainActor.run {
                if remoteCode == nil, geoLookupAttempts < maxGeoLookupRetries {
                    geoLookupAttempts += 1
                    scheduleGeoRetry()
                } else {
                    let fallback = remoteCode == nil ? resolvedRegionCode() : nil
                    handleGeoLookupResult(remoteCode: remoteCode, fallbackCode: fallback)
                }
            }
        }
    }

    @MainActor
    private func scheduleGeoRetry() {
        geoLookupTask?.cancel()
        geoLookupTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(geoRetryDelay * 1_000_000_000))
            evaluateGeoRestrictionIfNeeded(forceNetworkLookup: true)
        }
    }

    @MainActor
    private func handleGeoLookupResult(remoteCode: String?, fallbackCode: String?) {
        let finalCode = remoteCode ?? fallbackCode
        let isRestricted = finalCode == nil || finalCode != "DE"

        guard isRestricted else {
            if remoteCode != nil {
                geoNeedsFreshLookup = false
            }
            geoLookupTask = nil
            markGeoCheckCompleted(immediate: forcedSplashOnForeground)
            return
        }

        let localizedName: String? = {
            guard let countryCode = finalCode else { return nil }
            return Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
        }()

        let now = Date()
        let canShow = canPresentGeoWarning(at: now)

        guard canShow else {
            geoWarningAcknowledged = true
            if remoteCode != nil {
                geoNeedsFreshLookup = false
            }
            geoLookupTask = nil
            markGeoCheckCompleted(immediate: forcedSplashOnForeground)
            return
        }

        detectedRegionName = localizedName
        showGeoRestrictionWarning = true
        geoWarningLastShownAt = now.timeIntervalSince1970
        if remoteCode != nil {
            geoNeedsFreshLookup = false
        }
        geoLookupTask = nil
        markGeoCheckCompleted(immediate: true)
    }

    private func resetGeoRestrictionState(forceNetworkLookup: Bool) {
        geoWarningAcknowledged = false
        detectedRegionName = nil
        geoNeedsFreshLookup = true
        isGeoCheckPending = true
        geoLookupAttempts = 0
        evaluateGeoRestrictionIfNeeded(forceNetworkLookup: forceNetworkLookup)
    }

    private func acknowledgeGeoRestrictionWarning() {
        geoWarningAcknowledged = true
        showGeoRestrictionWarning = false
        markGeoCheckCompleted(immediate: true)
    }

    @MainActor
    private func markGeoCheckCompleted(immediate: Bool) {
        guard isGeoCheckPending else { return }
        isGeoCheckPending = false
        hideLaunchScreenIfReady(immediate: immediate)
    }

    private func canPresentGeoWarning(at date: Date = Date()) -> Bool {
        guard !geoWarningAcknowledged else { return false }
        return date.timeIntervalSince1970 - geoWarningLastShownAt >= geoWarningThrottleInterval
    }

    private func resolvedRegionCode() -> String? {
        if #available(iOS 16.0, *) {
            if let region = Locale.autoupdatingCurrent.region {
                return region.identifier.uppercased()
            }
            return nil
        } else {
            if let code = Locale.autoupdatingCurrent.regionCode {
                return code.uppercased()
            }

            if let code = (Locale.autoupdatingCurrent as NSLocale).object(forKey: .countryCode) as? String {
                return code.uppercased()
            }

            return nil
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
            .environmentObject(ChannelRepository())
            .environmentObject(MediathekRepository())
            .environmentObject(AppSettings.shared)
            .environmentObject(NetworkMonitor.shared)
    }
}

private enum MainTab: Hashable {
    case live
    case mediathek
    case personal
}

private struct GeoRestrictionInfoView: View {
    let regionDescription: String?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "globe.europe.africa.fill")
                        .font(.system(size: 54))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)

                    Text(String(localized: "geo_restriction_title"))
                        .font(.title).bold()
                        .multilineTextAlignment(.center)

                    Text(messageText)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                VStack(spacing: 12) {
                    Button {
                        onDismiss()
                    } label: {
                        Text(String(localized: "geo_restriction_cta"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(.tint)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    Button(role: .cancel) {
                        onDismiss()
                    } label: {
                        Text(String(localized: "close"))
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
    }

    private var messageText: String {
        if let regionDescription {
            return String.localizedStringWithFormat(
                String(localized: "geo_restriction_message_region"),
                regionDescription
            )
        }

        return String(localized: "geo_restriction_message_generic")
    }
}
