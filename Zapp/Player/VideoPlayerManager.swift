import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import OSLog

final class VideoPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var selectedQuality: MediathekShow.Quality = .high
    @Published var availableQualities: [MediathekShow.Quality] = []
    @Published var currentShow: MediathekShow?
    @Published var currentChannel: Channel?
    @Published var sleepTimerRemaining: TimeInterval?
    @Published var isBuffering = false
    @Published var seekableRange: ClosedRange<TimeInterval>?
    @Published var isLoadingStream = false
    @Published var playbackErrorState: PlaybackErrorState?
    
    private var timeObserver: Any?
    private var sleepTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var itemStatusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var bufferFullObserver: NSKeyValueObservation?
    private var audioSessionActive = false
    private var localPlaybackURL: URL?
    private var shouldResumeAfterRouteChange = false
    private var shouldResumeAfterInterruption = false
    private var lastPlaybackSource: PlaybackSource?
    private var retryCount = 0
    private let maxRetryAttempts = 3
    private var loadTimeoutWorkItem: DispatchWorkItem?
    private var pendingRetryWorkItem: DispatchWorkItem?
    
    private enum PlaybackSource {
        case live(channel: Channel)
        case show(show: MediathekShow, localFileURL: URL?)
        case direct(url: URL, show: MediathekShow?, channel: Channel?)

        var isLocal: Bool {
            switch self {
            case .show(_, let localFileURL):
                return localFileURL != nil
            default:
                return false
            }
        }

        var context: PlaybackErrorState.Context {
            switch self {
            case .live:
                return .live
            default:
                return .mediathek
            }
        }
    }

    struct PlaybackErrorState: Identifiable, Equatable {
        enum Context {
            case live
            case mediathek
        }

        let id = UUID()
        let context: Context

        var messageKey: String {
            switch context {
            case .live:
                return "player_error_live_unavailable"
            case .mediathek:
                return "player_error_vod_unavailable"
            }
        }
    }

    static let shared = VideoPlayerManager()
    private let playerLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zapp", category: "VideoPlayer")
    
    private init() {
        configureAudioSession()
        setupRemoteTransportControls()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    private func configureAudioSession() {
        let block = { [weak self] in
            guard let self = self else { return }
            let audioSession = AVAudioSession.sharedInstance()
            let baseOptions: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]
            let fallbackOptions = baseOptions.union([.mixWithOthers])

            do {
                if #available(iOS 13.0, *) {
                    do {
                        try audioSession.setCategory(
                            .playback,
                            mode: .moviePlayback,
                            policy: .longFormVideo,
                            options: baseOptions
                        )
                    } catch {
                        self.playerLogger.error("Long-form audio route not available, falling back: \(String(describing: error))")
                        try audioSession.setCategory(
                            .playback,
                            mode: .moviePlayback,
                            options: fallbackOptions
                        )
                    }
                } else {
                    try audioSession.setCategory(.playback, mode: .moviePlayback, options: fallbackOptions)
                }
            } catch {
                self.playerLogger.error("Failed to set audio session category: \(String(describing: error))")
            }
        }

        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async { block() }
        }
    }

    private func activateAudioSessionIfNeeded() {
        guard !audioSessionActive else { return }

        let block = { [weak self] in
            guard let self = self else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                self.audioSessionActive = true
                UIApplication.shared.beginReceivingRemoteControlEvents()
            } catch {
                self.playerLogger.error("Failed to activate audio session: \(String(describing: error))")
            }
        }

        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async { block() }
        }
    }

    private func deactivateAudioSessionIfNeeded() {
        guard audioSessionActive else { return }

        let block = { [weak self] in
            guard let self = self else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                self.playerLogger.error("Failed to deactivate audio session: \(String(describing: error))")
            }
            self.audioSessionActive = false
            UIApplication.shared.endReceivingRemoteControlEvents()
        }

        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async { block() }
        }
    }
    
    func loadVideo(
        url: URL,
        show: MediathekShow?,
        channel: Channel? = nil,
        startTime: TimeInterval = 0,
        resetRetryState: Bool = true
    ) {
        cleanup()
        activateAudioSessionIfNeeded()

        if lastPlaybackSource == nil {
            registerLoadSource(.direct(url: url, show: show, channel: channel), resetRetryState: resetRetryState)
        } else if resetRetryState, let source = lastPlaybackSource, case .direct = source {
            registerLoadSource(.direct(url: url, show: show, channel: channel), resetRetryState: true)
        }

        currentShow = show
        currentChannel = channel
        if show == nil {
            localPlaybackURL = nil
        }
        isBuffering = true
        isLoadingStream = true

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        disableSubtitlesIfNeeded(on: item)
        item.preferredForwardBufferDuration = 1
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        if channel != nil {
            applyLivePreferredBitRate(to: item)
        } else {
            item.preferredPeakBitRate = 0
        }

        registerPlayerItemNotifications(for: item)

        let player = AVPlayer(playerItem: item)
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player

        if startTime > 0 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }

        setupTimeObserver()
        observeBuffering(for: item)
        updateNowPlayingInfo()
        scheduleInitialLoadTimeout()
    }
    
    func loadShow(
        _ show: MediathekShow,
        localFileURL: URL? = nil,
        quality: MediathekShow.Quality? = nil,
        startTime: TimeInterval = 0,
        resetRetryState: Bool = true
    ) {
        registerLoadSource(.show(show: show, localFileURL: localFileURL), resetRetryState: resetRetryState)
        currentShow = show
        localPlaybackURL = localFileURL

        if let localFileURL {
            availableQualities = []
            selectedQuality = quality ?? .high
            loadVideo(
                url: localFileURL,
                show: show,
                startTime: startTime,
                resetRetryState: resetRetryState
            )
            return
        }

        availableQualities = show.supportedQualities
        selectedQuality = quality ?? availableQualities.last ?? .high

        guard let url = show.url(for: selectedQuality) else { return }
        loadVideo(
            url: url,
            show: show,
            channel: nil,
            startTime: startTime,
            resetRetryState: resetRetryState
        )
    }

    func loadLiveStream(
        _ channel: Channel,
        startTime: TimeInterval = 0,
        qualityOverride: MediathekShow.Quality? = nil,
        resetRetryState: Bool = true
    ) {
        guard let url = channel.streamUrl else { return }
        registerLoadSource(.live(channel: channel), resetRetryState: resetRetryState)
        let liveQualities = MediathekShow.Quality.allCases
        availableQualities = liveQualities
        if let qualityOverride {
            selectedQuality = qualityOverride
        } else {
            selectedQuality = AppSettings.shared.preferredQuality(available: liveQualities)
        }
        loadVideo(
            url: url,
            show: nil,
            channel: channel,
            startTime: startTime,
            resetRetryState: resetRetryState
        )
    }

    private func applyLivePreferredBitRate(to item: AVPlayerItem?) {
        guard let item else { return }
        item.preferredPeakBitRate = livePreferredPeakBitRate(for: selectedQuality)
    }

    private func disableSubtitlesIfNeeded(on item: AVPlayerItem) {
        func deselectLegibleTracks(for item: AVPlayerItem, in group: AVMediaSelectionGroup) {
            DispatchQueue.main.async {
                item.select(nil, in: group)
            }
        }

        guard #available(iOS 16.0, *) else {
            // Best effort: older systems keep current subtitle selection.
            return
        }

        item.asset.loadMediaSelectionGroup(for: .legible) { [weak item] group, _ in
            guard let item = item, let group = group else { return }
            deselectLegibleTracks(for: item, in: group)
        }
    }

    private func livePreferredPeakBitRate(for quality: MediathekShow.Quality) -> Double {
        switch quality {
        case .low:
            return 700_000
        case .medium:
            return 1_800_000
        case .high:
            return 3_000_000
        }
    }
    
    func play() {
        activateAudioSessionIfNeeded()
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
    }
    
    func changeQuality(_ quality: MediathekShow.Quality) {
        if let channel = currentChannel {
            let resumeTime = currentTime
            selectedQuality = quality
            loadLiveStream(channel, startTime: resumeTime, qualityOverride: quality)
            play()
            return
        }

        guard localPlaybackURL == nil else { return }
        guard let show = currentShow, let url = show.url(for: quality) else { return }
        let currentPos = currentTime
        selectedQuality = quality
        loadVideo(url: url, show: show, channel: nil, startTime: currentPos)
        play()
    }

    private func attemptResumePlayback() {
        guard player != nil else { return }
        activateAudioSessionIfNeeded()
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    func startSleepTimer(minutes: Int) {
        sleepTimer?.invalidate()
        sleepTimerRemaining = TimeInterval(minutes * 60)
        
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let remaining = self.sleepTimerRemaining else { return }
            
            if remaining <= 1 {
                self.pause()
                self.sleepTimer?.invalidate()
                self.sleepTimerRemaining = nil
            } else {
                self.sleepTimerRemaining = remaining - 1
            }
        }
    }
    
    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimerRemaining = nil
    }
    
    func retryLastLoad() {
        guard let source = lastPlaybackSource else { return }
        playbackErrorState = nil
        retryCount = 0
        cancelLoadTracking()

        switch source {
        case .live(let channel):
            loadLiveStream(
                channel,
                startTime: currentTime,
                qualityOverride: selectedQuality,
                resetRetryState: true
            )
        case .show(let show, let localFileURL):
            loadShow(
                show,
                localFileURL: localFileURL,
                quality: selectedQuality,
                startTime: currentTime,
                resetRetryState: true
            )
        case .direct(let url, let show, let channel):
            loadVideo(
                url: url,
                show: show,
                channel: channel,
                startTime: currentTime,
                resetRetryState: true
            )
        }
    }

    func dismissPlaybackError() {
        playbackErrorState = nil
    }

    func savePlaybackPosition() {
        guard let show = currentShow, currentTime > 0 else { return }
        var totalDuration = duration
        if totalDuration <= 0, let showDuration = show.duration, showDuration > 0 {
            totalDuration = TimeInterval(showDuration)
        }
        guard totalDuration > 0 else { return }
        let clampedTime = min(currentTime, totalDuration)
        Task { @MainActor in
            PersistenceManager.shared.savePlaybackPosition(show: show, position: clampedTime, duration: totalDuration)
        }
    }
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            if let duration = self.player?.currentItem?.duration.seconds, !duration.isNaN {
                self.duration = duration
            }
            self.refreshSeekableRange()
        }
    }

    private func registerLoadSource(_ source: PlaybackSource, resetRetryState: Bool) {
        lastPlaybackSource = source
        if resetRetryState {
            retryCount = 0
            playbackErrorState = nil
        }
        cancelLoadTracking()
    }

    private func scheduleInitialLoadTimeout() {
        guard let source = lastPlaybackSource, !source.isLocal else { return }
        loadTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.playbackErrorState == nil else { return }
            if self.isLoadingStream {
                self.handlePlaybackFailure(trigger: "timeout")
            }
        }
        loadTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    private func cancelLoadTracking() {
        loadTimeoutWorkItem?.cancel()
        loadTimeoutWorkItem = nil
        pendingRetryWorkItem?.cancel()
        pendingRetryWorkItem = nil
    }

    private func refreshSeekableRange() {
        guard let rangeValue = player?.currentItem?.seekableTimeRanges.last?.timeRangeValue else {
            if seekableRange != nil {
                seekableRange = nil
            }
            return
        }

        let start = rangeValue.start.seconds
        let duration = rangeValue.duration.seconds
        guard start.isFinite, duration.isFinite, duration > 0 else {
            if seekableRange != nil {
                seekableRange = nil
            }
            return
        }

        let end = start + duration
        let newRange = start...end
        if seekableRange != newRange {
            seekableRange = newRange
        }
    }

    private func markStreamReady() {
        loadTimeoutWorkItem?.cancel()
        loadTimeoutWorkItem = nil
        if retryCount != 0 {
            retryCount = 0
        }
    }

    private func handlePlaybackFailure(trigger: String, error: Error? = nil) {
        guard let source = lastPlaybackSource, !source.isLocal else { return }
        guard playbackErrorState == nil else { return }

        cancelLoadTracking()
        isBuffering = false

        if let error {
            playerLogger.error("Playback failure (\(trigger)): \(error.localizedDescription)")
        } else {
            playerLogger.error("Playback failure (\(trigger))")
        }

        if retryCount < maxRetryAttempts {
            retryCount += 1
            isLoadingStream = true
            scheduleRetry(after: min(4.0, pow(1.5, Double(retryCount))))
        } else {
            isLoadingStream = false
            isPlaying = false
            playbackErrorState = PlaybackErrorState(context: source.context)
            playerLogger.error("Playback failed after retries (trigger: \(trigger))")
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        pendingRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.retryCurrentSource()
        }
        pendingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func retryCurrentSource() {
        guard let source = lastPlaybackSource else { return }
        switch source {
        case .live(let channel):
            loadLiveStream(
                channel,
                startTime: currentTime,
                qualityOverride: selectedQuality,
                resetRetryState: false
            )
        case .show(let show, let localFileURL):
            loadShow(
                show,
                localFileURL: localFileURL,
                quality: selectedQuality,
                startTime: currentTime,
                resetRetryState: false
            )
        case .direct(let url, let show, let channel):
            loadVideo(
                url: url,
                show: show,
                channel: channel,
                startTime: currentTime,
                resetRetryState: false
            )
        }
    }

    private func registerPlayerItemNotifications(for item: AVPlayerItem) {
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleItemFailedToPlay(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: item
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlaybackStalled(_:)),
            name: .AVPlayerItemPlaybackStalled,
            object: item
        )
    }

    @objc private func handleItemFailedToPlay(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              item == player?.currentItem else { return }
        handlePlaybackFailure(trigger: "failedToPlayToEnd")
    }

    @objc private func handlePlaybackStalled(_ notification: Notification) {
        guard let item = notification.object as? AVPlayerItem,
              item == player?.currentItem else { return }
        handlePlaybackFailure(trigger: "stalled")
    }

    private func observeBuffering(for item: AVPlayerItem) {
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if item.status == .failed {
                    self.isPlaying = false
                    self.isBuffering = false
                    self.isLoadingStream = false
                    self.handlePlaybackFailure(trigger: "itemStatus", error: item.error)
                } else if item.status == .readyToPlay {
                    self.markStreamReady()
                }
            }
        }

        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if item.isPlaybackBufferEmpty {
                    self.isBuffering = true
                }
            }
        }

        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let ready = item.isPlaybackLikelyToKeepUp
                self.isBuffering = !ready
                if ready {
                    self.isLoadingStream = false
                    self.markStreamReady()
                }
                if ready && self.isPlaying {
                    self.player?.play()
                }
            }
        }

        bufferFullObserver = item.observe(\.isPlaybackBufferFull, options: [.initial, .new]) { [weak self] item, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if item.isPlaybackBufferFull {
                    self.isLoadingStream = false
                }
            }
        }
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: event.positionTime)
            return .success
        }
        
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            let newTime = min(self.currentTime + 15, self.duration)
            self.seek(to: newTime)
            return .success
        }
        
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            let newTime = max(self.currentTime - 15, 0)
            self.seek(to: newTime)
            return .success
        }
    }

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard player != nil else { return }
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            let wasPlaying = isActuallyPlaying
            shouldResumeAfterRouteChange = wasPlaying
            if wasPlaying {
                isPlaying = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self else { return }
                    guard self.shouldResumeAfterRouteChange else { return }
                    self.shouldResumeAfterRouteChange = false
                    self.attemptResumePlayback()
                }
            }
        case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep, .noSuitableRouteForCategory:
            guard shouldResumeAfterRouteChange else { return }
            shouldResumeAfterRouteChange = false
            DispatchQueue.main.async { [weak self] in
                self?.attemptResumePlayback()
            }
        default:
            break
        }
    }

    @objc private func handleAudioInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            shouldResumeAfterInterruption = isActuallyPlaying
            if shouldResumeAfterInterruption {
                isPlaying = false
            }
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            let canResume = shouldResumeAfterInterruption || options.contains(.shouldResume)
            guard canResume else { return }
            shouldResumeAfterInterruption = false
            DispatchQueue.main.async { [weak self] in
                self?.attemptResumePlayback()
            }
        @unknown default:
            break
        }
    }

    private var isActuallyPlaying: Bool {
        if let player, player.timeControlStatus == .playing {
            return true
        }
        return isPlaying
    }
    
    private func updateNowPlayingInfo() {
        var nowPlayingInfo = [String: Any]()
        
        if let show = currentShow {
            nowPlayingInfo[MPMediaItemPropertyTitle] = show.title
            nowPlayingInfo[MPMediaItemPropertyArtist] = show.topic
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = show.channel
        } else if let channel = currentChannel {
            nowPlayingInfo[MPMediaItemPropertyTitle] = channel.name
            nowPlayingInfo[MPMediaItemPropertyArtist] = channel.subtitle ?? "Livestream"
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = channel.name
        }
        
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func cleanup() {
        player?.pause()
        cancelLoadTracking()
        playbackErrorState = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemPlaybackStalled, object: nil)

        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        itemStatusObserver = nil
        bufferEmptyObserver = nil
        likelyToKeepUpObserver = nil
        bufferFullObserver = nil

        sleepTimer?.invalidate()
        savePlaybackPosition()

        player?.replaceCurrentItem(with: nil)
        player = nil

        isPlaying = false
        isBuffering = false
        isLoadingStream = false
        seekableRange = nil
        currentTime = 0
        duration = 0
        currentShow = nil
        currentChannel = nil
        localPlaybackURL = nil
        updateNowPlayingInfo()

        deactivateAudioSessionIfNeeded()
        shouldResumeAfterRouteChange = false
        shouldResumeAfterInterruption = false
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanup()
    }

}
