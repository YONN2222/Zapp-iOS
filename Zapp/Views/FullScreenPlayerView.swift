import SwiftUI
import AVKit
import Combine

struct FullScreenPlayerView: View {
    let show: MediathekShow?
    let channel: Channel?
    let quality: MediathekShow.Quality
    let startTime: TimeInterval
    let localFileURL: URL?
    
    @StateObject private var playerManager = VideoPlayerManager.shared
    @ObservedObject private var nowPlayingState: ChannelNowPlayingState
    private let onDismiss: () -> Void
    
    init(show: MediathekShow? = nil,
         channel: Channel? = nil,
         nowPlayingState: ChannelNowPlayingState? = nil,
         quality: MediathekShow.Quality = .high,
         startTime: TimeInterval = 0,
         localFileURL: URL? = nil,
         onDismiss: @escaping () -> Void = {}) {
        let resolvedNowPlaying = nowPlayingState ?? ChannelNowPlayingState(channelId: channel?.id ?? UUID().uuidString)
        _nowPlayingState = ObservedObject(wrappedValue: resolvedNowPlaying)
        self.show = show
        self.channel = channel
        self.quality = quality
        self.startTime = startTime
        self.localFileURL = localFileURL
        self.onDismiss = onDismiss
    }

    private var currentLiveShowTitle: String? {
        guard show == nil else { return nil }
        guard let rawTitle = nowPlayingState.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
            return nil
        }
        return rawTitle
    }
    
    var body: some View {
        ZStack {
            CustomPlayerViewRepresentable(
                playerManager: playerManager,
                show: show,
                channel: channel,
                liveNowPlayingTitle: currentLiveShowTitle,
                quality: quality,
                startTime: startTime,
                localFileURL: localFileURL,
                onDismiss: onDismiss
            )

            if playerManager.isLoadingStream {
                PlayerLoadingOverlay()
            }

            if let error = playerManager.playbackErrorState {
                PlayerErrorOverlay(
                    titleKey: LocalizedStringKey("player_error_title"),
                    messageKey: LocalizedStringKey(error.messageKey),
                    retryAction: {
                        playerManager.retryLastLoad()
                    },
                    closeAction: {
                        playerManager.dismissPlaybackError()
                        playerManager.cleanup()
                        onDismiss()
                    }
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: playerManager.isLoadingStream)
        .animation(.easeInOut(duration: 0.2), value: playerManager.playbackErrorState != nil)
    }
}

struct CustomPlayerViewRepresentable: UIViewControllerRepresentable {
    let playerManager: VideoPlayerManager
    let show: MediathekShow?
    let channel: Channel?
    let liveNowPlayingTitle: String?
    let quality: MediathekShow.Quality
    let startTime: TimeInterval
    let localFileURL: URL?
    let onDismiss: () -> Void
    
    func makeUIViewController(context: Context) -> CustomPlayerViewController {
        let controller = CustomPlayerViewController()
        controller.onDismiss = onDismiss
        controller.configure(with: playerManager,
                              show: show,
                              channel: channel,
                              liveNowPlayingTitle: liveNowPlayingTitle,
                              quality: quality,
                              startTime: startTime,
                              localFileURL: localFileURL)
        return controller
    }
    
    func updateUIViewController(_ controller: CustomPlayerViewController, context: Context) {
        controller.configure(with: playerManager,
                              show: show,
                              channel: channel,
                              liveNowPlayingTitle: liveNowPlayingTitle,
                              quality: quality,
                              startTime: startTime,
                              localFileURL: localFileURL)
        controller.onDismiss = onDismiss
    }
}

private struct PlayerLoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.8)
                Text(LocalizedStringKey("player_loading_stream"))
                    .font(.title)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(36)
            .background(Color.black.opacity(0.65))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.45), radius: 30, x: 0, y: 14)
            .frame(maxWidth: 720)
            .padding(.horizontal, 20)
        }
        .transition(.opacity)
        .allowsHitTesting(true)
        .zIndex(2)
    }
}

private struct PlayerErrorOverlay: View {
    let titleKey: LocalizedStringKey
    let messageKey: LocalizedStringKey
    let retryAction: () -> Void
    let closeAction: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.yellow)
                VStack(spacing: 6) {
                    Text(titleKey)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(messageKey)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(Color.white.opacity(0.85))
                }
                HStack(spacing: 12) {
                    Button(action: closeAction) {
                        Text("player_error_close_button")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundColor(.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                            )
                    }

                    Button(action: retryAction) {
                        Text("player_error_retry_button")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.black.opacity(0.4), radius: 30, y: 20)
        }
        .transition(.opacity)
    }
}

class CustomPlayerViewController: UIViewController, UIGestureRecognizerDelegate, AVPictureInPictureControllerDelegate {
    var playerManager: VideoPlayerManager?
    var show: MediathekShow?
    var channel: Channel?
    var localFileURL: URL?
    var liveNowPlayingTitle: String?
    var onDismiss: (() -> Void)?
    
    private var playerLayer: AVPlayerLayer?
    private var controlsView: UIView?
    private let topBar = UIVisualEffectView()
    private let bottomBar = UIVisualEffectView()
    private let glassEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let playPauseButton = UIButton(type: .system)
    private let skipBackwardButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let scrubber = LargeHitSlider()
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let liveBadge = UIButton(type: .custom)
    private let qualityButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let qualitySymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold, scale: .medium)
    private var gradientLayer = CAGradientLayer()
    private var controlsVisible = true
    private var controlsTimer: Timer?
    private var controlsLockedVisible = false
    private var pendingQuality: MediathekShow.Quality = .high
    private var pendingStartTime: TimeInterval = 0
    private var hasStartedPlayback = false
    private var shouldBlockPlayback = false
    private var isPreparingPlayback = false
    private var isScrubbing = false
    private var cancellables = Set<AnyCancellable>()
    private var liveSeekableRange: ClosedRange<TimeInterval>?
    private var lastTimeSnapshot: (current: TimeInterval, duration: TimeInterval)?
    private var pipController: AVPictureInPictureController?
    private var pipPossibleObserver: NSKeyValueObservation?
    private let liveEdgeTolerance: TimeInterval = 7
    private var pendingSeekTarget: TimeInterval?
    private var pendingSeekStart: Date?
    private var lockedScrubberValue: Float?
    private lazy var liveClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "HHmm", options: 0, locale: .current)
        return formatter
    }()

    private var isLiveStream: Bool {
        show == nil && channel != nil
    }

    private var hasLiveTimeline: Bool {
        guard isLiveStream, let range = liveSeekableRange else { return false }
        return range.upperBound - range.lowerBound > 1
    }

    func configure(with playerManager: VideoPlayerManager,
                   show: MediathekShow?,
                   channel: Channel?,
                   liveNowPlayingTitle: String?,
                   quality: MediathekShow.Quality,
                   startTime: TimeInterval,
                   localFileURL: URL?) {
        let showChanged = self.show?.id != show?.id
        let channelChanged = self.channel?.id != channel?.id
        let managerChanged = self.playerManager !== playerManager
        let qualityChanged = pendingQuality != quality
        let startChanged = pendingStartTime != startTime
        let localFileChanged = self.localFileURL != localFileURL
        self.playerManager = playerManager
        self.show = show
        self.channel = channel
        self.localFileURL = localFileURL
        self.liveNowPlayingTitle = liveNowPlayingTitle
        pendingQuality = quality
        pendingStartTime = startTime

        shouldBlockPlayback = false
        updateMetadataLabels()

        if managerChanged {
            bindToPlayer(playerManager)
        }

        if showChanged || channelChanged || managerChanged || qualityChanged || startChanged || localFileChanged {
            hasStartedPlayback = false
            startPlaybackIfNeeded()
        }
    }
    
    override var prefersStatusBarHidden: Bool {
        !controlsVisible
    }
    
    override var prefersHomeIndicatorAutoHidden: Bool {
        !controlsVisible
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationManager.shared.currentMask
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        OrientationManager.shared.preferredInterfaceOrientation
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        controlsVisible ? [] : [.bottom]
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPlayerLayer()
        setupControls()
        setupGestures()
        startPlaybackIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.playerLayer?.frame = CGRect(origin: .zero, size: size)
        }) { [weak self] _ in
            self?.startPlaybackIfNeeded()
        }
    }
    
    private func setupPlayerLayer() {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(layer)
        playerLayer = layer
        configurePictureInPictureController(for: layer)
    }

    private func setupControls() {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = .clear
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controlsView = overlay
        controlsView?.alpha = controlsVisible ? 1 : 0
        
        configureTopBar(in: overlay)
        configureBottomBar(in: overlay)
    }

    private func configureTopBar(in overlay: UIView) {
        guard let safeArea = view?.safeAreaLayoutGuide else { return }
        overlay.addSubview(topBar)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        applyLiquidGlassStyle(to: topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 68)
        ])

        closeButton.tintColor = .white
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        closeButton.layer.cornerRadius = 20
        closeButton.layer.cornerCurve = .continuous
        closeButton.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        closeButton.layer.borderWidth = 0.5
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 14),
            closeButton.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 16)
        ])
        let textTrailingConstraint = textStack.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -16)
        textTrailingConstraint.priority = .defaultLow
        textTrailingConstraint.isActive = true

        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        subtitleLabel.numberOfLines = 2
        configureLiveBadge()
        configureQualityButtonAppearance()
        qualityButton.addTarget(self, action: #selector(qualityButtonTapped), for: .touchUpInside)
        configurePiPButton()

        let qualityWrapper = UIView()
        qualityWrapper.translatesAutoresizingMaskIntoConstraints = false
        qualityWrapper.addSubview(qualityButton)
        NSLayoutConstraint.activate([
            qualityButton.centerXAnchor.constraint(equalTo: qualityWrapper.centerXAnchor),
            qualityButton.centerYAnchor.constraint(equalTo: qualityWrapper.centerYAnchor),
            qualityWrapper.widthAnchor.constraint(equalToConstant: 44),
            qualityWrapper.heightAnchor.constraint(equalToConstant: 44)
        ])

        let pipWrapper = UIView()
        pipWrapper.translatesAutoresizingMaskIntoConstraints = false
        pipWrapper.addSubview(pipButton)
        NSLayoutConstraint.activate([
            pipButton.centerXAnchor.constraint(equalTo: pipWrapper.centerXAnchor),
            pipButton.centerYAnchor.constraint(equalTo: pipWrapper.centerYAnchor),
            pipWrapper.widthAnchor.constraint(equalToConstant: 44),
            pipWrapper.heightAnchor.constraint(equalToConstant: 44)
        ])

        let actionsStack = UIStackView(arrangedSubviews: [liveBadge, pipWrapper, qualityWrapper])
        actionsStack.axis = .horizontal
        actionsStack.alignment = .center
        actionsStack.spacing = 10
        actionsStack.distribution = .equalSpacing
        actionsStack.isLayoutMarginsRelativeArrangement = false
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(actionsStack)
        NSLayoutConstraint.activate([
            actionsStack.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -14),
            actionsStack.centerYAnchor.constraint(equalTo: topBar.contentView.centerYAnchor)
        ])

        pipButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pipButton.widthAnchor.constraint(equalToConstant: 40),
            pipButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        qualityButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qualityButton.widthAnchor.constraint(equalToConstant: 40),
            qualityButton.heightAnchor.constraint(equalToConstant: 40)
        ])

        liveBadge.setContentHuggingPriority(.required, for: .horizontal)
        pipButton.setContentHuggingPriority(.required, for: .horizontal)
        qualityButton.setContentHuggingPriority(.required, for: .horizontal)

        textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -12).isActive = true
    }

    private func configureBottomBar(in overlay: UIView) {
        guard let safeArea = view?.safeAreaLayoutGuide else { return }
        overlay.addSubview(bottomBar)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        applyLiquidGlassStyle(to: bottomBar)
        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -8)
        ])
        bottomBar.layer.cornerRadius = 14
        bottomBar.contentView.layer.cornerRadius = 14
        let minimumHeight = bottomBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        minimumHeight.priority = .defaultHigh
        minimumHeight.isActive = true

        gradientLayer.removeFromSuperlayer()
        gradientLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.18).cgColor]
        gradientLayer.locations = [0.0, 1.0]
        bottomBar.contentView.layer.insertSublayer(gradientLayer, at: 0)

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 6),
            contentStack.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor, constant: -6)
        ])
        // Make the interior background of the bottom bar very subtle so it blocks less of the video
        bottomBar.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.015)

    let scrubStack = UIStackView(arrangedSubviews: [currentTimeLabel, scrubber, durationLabel])
    scrubStack.axis = .horizontal
    scrubStack.spacing = 10
    scrubStack.alignment = .center
    scrubStack.distribution = .fill
        currentTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        durationLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        currentTimeLabel.textColor = .white
        durationLabel.textColor = .white
        currentTimeLabel.text = "00:00"
        durationLabel.text = "--:--"
    currentTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
    durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        scrubber.minimumValue = 0
        scrubber.maximumValue = 1
        scrubber.value = 0
        scrubber.minimumTrackTintColor = .white
        scrubber.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        scrubber.thumbTintColor = .white
        let thumbNormal = makeThumbImage(diameter: 20, color: .white)
        let thumbHighlighted = makeThumbImage(diameter: 20, color: UIColor.white.withAlphaComponent(0.85))
        scrubber.setThumbImage(thumbNormal, for: .normal)
        scrubber.setThumbImage(thumbHighlighted, for: .highlighted)
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
    scrubber.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrubber.addTarget(self, action: #selector(scrubberTouchDown), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberValueChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubberTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // allow tap-to-seek gesture; handler checks AppSettings.shared.allowTapToSeek
        let tap = UITapGestureRecognizer(target: self, action: #selector(scrubberTapped(_:)))
        tap.delegate = self
        scrubber.addGestureRecognizer(tap)

        contentStack.addArrangedSubview(scrubStack)

        let compactSymbolConfig = UIImage.SymbolConfiguration(pointSize: 34, weight: .medium, scale: .medium)
        skipBackwardButton.setImage(UIImage(systemName: "gobackward.5"), for: .normal)
        skipBackwardButton.setPreferredSymbolConfiguration(compactSymbolConfig, forImageIn: .normal)
        skipBackwardButton.tintColor = .white
        skipBackwardButton.addTarget(self, action: #selector(skipBackwardTapped), for: .touchUpInside)
        skipForwardButton.setImage(UIImage(systemName: "goforward.15"), for: .normal)
        skipForwardButton.setPreferredSymbolConfiguration(compactSymbolConfig, forImageIn: .normal)
        skipForwardButton.tintColor = .white
        skipForwardButton.addTarget(self, action: #selector(skipForwardTapped), for: .touchUpInside)

        playPauseButton.tintColor = .white
        playPauseButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold, scale: .large), forImageIn: .normal)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)

        let leftWrapper = UIView()
        leftWrapper.translatesAutoresizingMaskIntoConstraints = false
        leftWrapper.addSubview(skipBackwardButton)
        skipBackwardButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            skipBackwardButton.centerXAnchor.constraint(equalTo: leftWrapper.centerXAnchor),
            skipBackwardButton.centerYAnchor.constraint(equalTo: leftWrapper.centerYAnchor)
        ])
        NSLayoutConstraint.activate([
            leftWrapper.widthAnchor.constraint(equalToConstant: 64),
            leftWrapper.heightAnchor.constraint(equalToConstant: 64)
        ])

        let centerWrapper = UIView()
        centerWrapper.translatesAutoresizingMaskIntoConstraints = false
        centerWrapper.addSubview(playPauseButton)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playPauseButton.centerXAnchor.constraint(equalTo: centerWrapper.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: centerWrapper.centerYAnchor)
        ])
        NSLayoutConstraint.activate([
            centerWrapper.widthAnchor.constraint(equalToConstant: 88),
            centerWrapper.heightAnchor.constraint(equalToConstant: 88)
        ])

        let rightWrapper = UIView()
        rightWrapper.translatesAutoresizingMaskIntoConstraints = false
        rightWrapper.addSubview(skipForwardButton)
        skipForwardButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            skipForwardButton.centerXAnchor.constraint(equalTo: rightWrapper.centerXAnchor),
            skipForwardButton.centerYAnchor.constraint(equalTo: rightWrapper.centerYAnchor)
        ])
        NSLayoutConstraint.activate([
            rightWrapper.widthAnchor.constraint(equalToConstant: 64),
            rightWrapper.heightAnchor.constraint(equalToConstant: 64)
        ])

        let centerControls = UIStackView(arrangedSubviews: [leftWrapper, centerWrapper, rightWrapper])
        centerControls.axis = .horizontal
        centerControls.alignment = .center
        centerControls.spacing = 36
        centerControls.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(centerControls)
        NSLayoutConstraint.activate([
            centerControls.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            centerControls.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])

        updatePlayPauseIcon(isPlaying: playerManager?.isPlaying ?? false)
        updateControlAvailability()
    }

    private func applyLiquidGlassStyle(to effectView: UIVisualEffectView) {
        effectView.effect = glassEffect
        effectView.layer.cornerRadius = 24
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
        effectView.alpha = 0.95
        effectView.contentView.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        effectView.contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        effectView.contentView.layer.borderWidth = 0.5
    }

    private func configureQualityButtonAppearance() {
        qualityButton.tintColor = .white
        qualityButton.setTitle(nil, for: .normal)
        qualityButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        qualityButton.semanticContentAttribute = .forceLeftToRight
        qualityButton.accessibilityLabel = NSLocalizedString("player_quality_button_accessibility", comment: "Accessibility label for quality button")
        qualityButton.accessibilityHint = NSLocalizedString("player_quality_button_hint", comment: "Accessibility hint for quality button")
        qualityButton.layer.shadowColor = UIColor.black.cgColor
        qualityButton.layer.shadowOpacity = 0.35
        qualityButton.layer.shadowRadius = 14
        qualityButton.layer.shadowOffset = CGSize(width: 0, height: 6)
        qualityButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        qualityButton.layer.cornerRadius = 20
        qualityButton.layer.cornerCurve = .continuous
        qualityButton.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        qualityButton.layer.borderWidth = 0.8
    }

    private func configureLiveBadge() {
        liveBadge.setTitle(NSLocalizedString("player_live_badge", comment: "Live stream indicator"), for: .normal)
        liveBadge.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        liveBadge.setTitleColor(.white, for: .normal)
        liveBadge.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .disabled)
        liveBadge.tintColor = .white
        liveBadge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        liveBadge.layer.cornerRadius = 10
        liveBadge.layer.cornerCurve = .continuous
        liveBadge.layer.masksToBounds = true
        liveBadge.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
        liveBadge.layer.borderWidth = 0.5
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            liveBadge.configuration = config
        } else {
            liveBadge.contentEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        }
        liveBadge.isHidden = true
        liveBadge.addTarget(self, action: #selector(liveBadgeTapped), for: .touchUpInside)
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            liveBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            liveBadge.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    private func configurePiPButton() {
        pipButton.tintColor = .white
        pipButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        pipButton.layer.cornerRadius = 20
        pipButton.layer.cornerCurve = .continuous
        pipButton.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        pipButton.layer.borderWidth = 0.5
        pipButton.isHidden = false
        pipButton.isEnabled = false
        pipButton.alpha = 0.35
        pipButton.addTarget(self, action: #selector(pipButtonTapped), for: .touchUpInside)
        updatePiPButtonIcon(isActive: false)
    }

    private func makeThumbImage(diameter: CGFloat, color: UIColor) -> UIImage? {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            color.setFill()
            UIBezierPath(ovalIn: rect).fill()
            context.cgContext.setShadow(offset: .zero, blur: 2, color: UIColor.black.withAlphaComponent(0.2).cgColor)
        }
    }

    @objc private func skipBackwardTapped() {
        animateSkip(button: skipBackwardButton, clockwise: false)
        performSkip(by: -5)
    }

    @objc private func skipForwardTapped() {
        animateSkip(button: skipForwardButton, clockwise: true)
        performSkip(by: 15)
    }

    @objc private func liveBadgeTapped() {
        seekToLiveEdge()
    }

    @objc private func scrubberTouchDown() {
        isScrubbing = true
        controlsTimer?.invalidate()
        lockedScrubberValue = scrubber.value
    }

    @objc private func scrubberValueChanged() {
        guard isScrubbing else { return }
        let currentValue = TimeInterval(scrubber.value)
        lockedScrubberValue = scrubber.value
        if isLiveStream, let range = liveSeekableRange {
            let absoluteTime = range.lowerBound + currentValue
            let distanceToLive = max(0, range.upperBound - absoluteTime)
            currentTimeLabel.text = "-\(formatTime(distanceToLive))"
        } else {
            currentTimeLabel.text = formatTime(currentValue)
        }
    }

    @objc private func scrubberTouchUp() {
        guard let manager = playerManager else { return }
        let newTime: TimeInterval
        if isLiveStream, let range = liveSeekableRange {
            newTime = range.lowerBound + TimeInterval(scrubber.value)
        } else {
            newTime = TimeInterval(scrubber.value)
        }
        
        pendingSeekTarget = newTime
        pendingSeekStart = Date()

        if isLiveStream, let range = liveSeekableRange {
            let positionInWindow = newTime - range.lowerBound
            scrubber.value = Float(positionInWindow)
        } else {
            scrubber.value = Float(newTime)
        }

        lockedScrubberValue = scrubber.value

        isScrubbing = false

        manager.seek(to: newTime)
        if manager.isPlaying {
            manager.play()
        }
        startControlsTimer()
    }

    private func seekToLiveEdge() {
        guard isLiveStream,
              let manager = playerManager,
              let range = liveSeekableRange else { return }
        let liveEdge = max(range.lowerBound, range.upperBound - 2)
        manager.seek(to: liveEdge)
        if !manager.isPlaying {
            manager.play()
        }
        startControlsTimer()
    }

    @objc private func scrubberTapped(_ gesture: UITapGestureRecognizer) {
        guard AppSettings.shared.allowTapToSeek else { return }
        guard let manager = playerManager, scrubber.isEnabled else { return }
        let location = gesture.location(in: scrubber)
        let width = scrubber.bounds.width
        guard width > 0 else { return }
        var ratio = Double(location.x / width)
        ratio = max(0, min(1, ratio))

        let newTime: TimeInterval
        if isLiveStream, let range = liveSeekableRange {
            let windowDuration = max(0, range.upperBound - range.lowerBound)
            let positionInWindow = ratio * windowDuration
            newTime = range.lowerBound + positionInWindow
            scrubber.setValue(Float(positionInWindow), animated: true)
        } else {
            // VOD: scrubber.maximumValue holds duration
            let duration = Double(scrubber.maximumValue)
            newTime = ratio * duration
            scrubber.setValue(Float(newTime), animated: true)
        }

        pendingSeekTarget = newTime
        pendingSeekStart = Date()
        lockedScrubberValue = scrubber.value

        manager.seek(to: newTime)
        if manager.isPlaying {
            manager.play()
        }
        startControlsTimer()
    }

    private func performSkip(by offset: TimeInterval) {
        guard let manager = playerManager else { return }
        let newTime: TimeInterval

        if isLiveStream, let range = liveSeekableRange {
            let clampedCurrent = max(range.lowerBound, min(range.upperBound, manager.currentTime))
            let tentative = clampedCurrent + offset
            newTime = max(range.lowerBound, min(range.upperBound, tentative))
        } else {
            let duration = manager.duration
            var target = manager.currentTime + offset
            if duration.isFinite && duration > 0 {
                target = min(duration, max(0, target))
            } else {
                target = max(0, target)
            }
            newTime = target
        }

        manager.seek(to: newTime)
        keepControlsVisibleDuringRapidAction()
    }

    private func animateSkip(button: UIButton, clockwise: Bool) {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = (clockwise ? 1 : -1) * 2 * Double.pi
        animation.duration = 0.35
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer.add(animation, forKey: "skipRotation")
    }

    private func keepControlsVisibleDuringRapidAction() {
        if !controlsVisible {
            controlsVisible = true
            UIView.animate(withDuration: 0.2) {
                self.controlsView?.alpha = 1
                self.setNeedsStatusBarAppearanceUpdate()
                self.setNeedsUpdateOfHomeIndicatorAutoHidden()
                self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            }
        } else {
            controlsView?.alpha = 1
        }
        startControlsTimer(after: 8.0)
    }

    @objc private func qualityButtonTapped() {
        guard let manager = playerManager else { return }
        let qualities = manager.availableQualities
        guard qualities.count > 1 else { return }
        controlsLockedVisible = true
        keepControlsVisibleDuringRapidAction()

        let alertTitle = NSLocalizedString("player_quality_picker_title", comment: "Title for the quality picker sheet")
        let cancelTitle = NSLocalizedString("player_quality_picker_cancel", comment: "Cancel button in the quality picker")
        let alert = UIAlertController(title: alertTitle, message: nil, preferredStyle: .actionSheet)
        qualities.forEach { quality in
            let suffix = quality == manager.selectedQuality ? " ✓" : ""
            let optionTitle = "\(quality.localizedName)\(suffix)"
            let action = UIAlertAction(title: optionTitle, style: .default) { [weak manager, weak self] _ in
                manager?.changeQuality(quality)
                self?.controlsLockedVisible = false
                self?.hideControls()
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { [weak self] _ in
            self?.controlsLockedVisible = false
            self?.startControlsTimer()
        })

        if let popover = alert.popoverPresentationController {
            popover.sourceView = qualityButton
            popover.sourceRect = qualityButton.bounds
        }

        present(alert, animated: true) {
            self.keepControlsVisibleDuringRapidAction()
        }
    }

    private func bindToPlayer(_ manager: VideoPlayerManager) {
        cancellables.removeAll()

        manager.$player
            .receive(on: RunLoop.main)
            .sink { [weak self] player in
                self?.playerLayer?.player = player
                if let layer = self?.playerLayer {
                    self?.configurePictureInPictureController(for: layer)
                }
            }
            .store(in: &cancellables)

        manager.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                self?.updatePlayPauseIcon(isPlaying: isPlaying)
            }
            .store(in: &cancellables)

        manager.$currentTime
            .combineLatest(manager.$duration)
            .receive(on: RunLoop.main)
            .sink { [weak self] current, duration in
                self?.updateTimeUI(current: current, duration: duration)
            }
            .store(in: &cancellables)

        manager.$selectedQuality
            .combineLatest(manager.$availableQualities)
            .receive(on: RunLoop.main)
            .sink { [weak self] selected, available in
                self?.updateQualityButton(selected: selected, available: available)
            }
            .store(in: &cancellables)

        manager.$currentShow
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                guard let self = self else { return }
                guard self.hasStartedPlayback else { return }
                self.show = show
                self.updateMetadataLabels()
            }
            .store(in: &cancellables)

        manager.$seekableRange
            .receive(on: RunLoop.main)
            .sink { [weak self] range in
                guard let self = self else { return }
                self.liveSeekableRange = range
                self.updateControlAvailability()
                if let snapshot = self.lastTimeSnapshot {
                    self.updateTimeUI(current: snapshot.current, duration: snapshot.duration)
                }
            }
            .store(in: &cancellables)
    }

    private func updatePlayPauseIcon(isPlaying: Bool) {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: symbolName), for: .normal)
    }

    private func updateTimeUI(current: TimeInterval, duration: TimeInterval) {
        lastTimeSnapshot = (current: current, duration: duration)
        if isLiveStream {
            updateLiveTimeline(current: current)
            return
        }

        // If a seek was just requested by the user, suppress updating the
        // scrubber/current time display until the player reports a position
        // close to the requested target or a short timeout elapses. This
        // prevents a visual jump back to the old position while seeking.
        if let target = pendingSeekTarget, let started = pendingSeekStart {
            let elapsed = Date().timeIntervalSince(started)
            if abs(current - target) <= 0.5 || elapsed > 2.0 {
                // player has caught up or timeout - clear the pending flag
                pendingSeekTarget = nil
                pendingSeekStart = nil
                lockedScrubberValue = nil
            } else {
                // still seeking - update duration but keep scrubber at user's value
                durationLabel.isHidden = false
                durationLabel.text = formatTime(duration)
                if let lockedValue = lockedScrubberValue {
                    scrubber.setValue(lockedValue, animated: false)
                }
                // don't modify scrubber.value or currentTimeLabel yet
                return
            }
        }

        durationLabel.isHidden = false
        // Do not override the user's scrubber time display while scrubbing
        if !isScrubbing {
            currentTimeLabel.text = formatTime(current)
        }

        guard duration.isFinite, duration > 0 else {
            durationLabel.text = "--:--"
            if !isScrubbing, pendingSeekTarget == nil {
                scrubber.value = 0
            }
            scrubber.isEnabled = false
            scrubber.isHidden = false
            return
        }

        durationLabel.text = formatTime(duration)
        scrubber.isHidden = false
        scrubber.isEnabled = true
        scrubber.maximumValue = Float(duration)
        if !isScrubbing, pendingSeekTarget == nil {
            scrubber.value = Float(current)
        }
    }

    private func updateLiveTimeline(current: TimeInterval) {
        guard hasLiveTimeline, let range = liveSeekableRange else {
            currentTimeLabel.text = liveClockFormatter.string(from: Date())
            durationLabel.text = ""
            durationLabel.isHidden = true
            scrubber.isHidden = true
            scrubber.isEnabled = false
            scrubber.alpha = 0.35
            if !isScrubbing, pendingSeekTarget == nil {
                scrubber.value = 0
            }
            updateLiveBadgeState(distanceToLive: nil)
            return
        }

        let windowDuration = max(0, range.upperBound - range.lowerBound)
        let liveEdge = range.upperBound
        let absoluteCurrent = max(range.lowerBound, min(liveEdge, current))
        let distanceToLive = max(0, liveEdge - absoluteCurrent)
        let positionInWindow = max(0, min(windowDuration, absoluteCurrent - range.lowerBound))

        scrubber.isHidden = false
        scrubber.isEnabled = true
        scrubber.alpha = 1
        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(windowDuration)
        // If the user just performed a seek, suppress automatic updates until
        // the player reports a position near the pending target or a timeout.
        if let target = pendingSeekTarget, let started = pendingSeekStart {
            let elapsed = Date().timeIntervalSince(started)
            if abs(current - target) <= 0.5 || elapsed > 2.0 {
                pendingSeekTarget = nil
                pendingSeekStart = nil
                lockedScrubberValue = nil
                if !isScrubbing {
                    scrubber.value = Float(positionInWindow)
                }
            } else {
                // still seeking - keep the scrubber at the user's released position
                if let lockedValue = lockedScrubberValue {
                    scrubber.setValue(lockedValue, animated: false)
                }
            }
        } else {
            if !isScrubbing {
                scrubber.value = Float(positionInWindow)
            }
        }

        durationLabel.isHidden = false
        // When the user is actively scrubbing, keep the scrubber's displayed time
        // instead of overwriting it with continuous player updates.
        if !isScrubbing {
            currentTimeLabel.text = "-\(formatTime(distanceToLive))"
        }
        durationLabel.text = formatTime(windowDuration)
        updateLiveBadgeState(distanceToLive: distanceToLive)
    }

    private func updateLiveBadgeState(distanceToLive: TimeInterval?) {
        guard isLiveStream else { return }
        let distance = distanceToLive ?? 0
        let isNearLive = distance <= liveEdgeTolerance
        let canJump = !isNearLive && distance > 0.1

        liveBadge.isEnabled = canJump
        liveBadge.alpha = canJump ? 0.95 : 1.0

        let liveColor = UIColor.systemRed.withAlphaComponent(0.9)
        let bufferedColor = UIColor.systemGray3.withAlphaComponent(0.85)
        liveBadge.backgroundColor = isNearLive ? liveColor : bufferedColor
        liveBadge.setTitleColor(isNearLive ? .white : UIColor.white.withAlphaComponent(0.85), for: .normal)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && !time.isNaN else { return "--:--" }
        let totalSeconds = Int(max(0, floor(time)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    private func updateQualityButton(selected: MediathekShow.Quality, available: [MediathekShow.Quality]) {
        let shouldHide = available.count <= 1
        qualityButton.isHidden = shouldHide
        qualityButton.isEnabled = !shouldHide
        qualityButton.alpha = shouldHide ? 0.4 : 1
        guard !shouldHide else {
            qualityButton.accessibilityValue = nil
            return
        }

        let qualityName = selected.localizedName
        qualityButton.accessibilityValue = qualityName
    }

    private func updateMetadataLabels() {
        if let show = show {
            titleLabel.text = show.title
            subtitleLabel.text = show.topic.isEmpty ? show.channel : "\(show.topic) · \(show.channel)"
            liveBadge.isHidden = true
        } else if let channel = channel {
            titleLabel.text = channel.name
            subtitleLabel.text = resolvedLiveSubtitle(for: channel)
            liveBadge.isHidden = false
            updateLiveBadgeState(distanceToLive: nil)
        } else {
            titleLabel.text = NSLocalizedString("app_name", comment: "App name fallback")
            subtitleLabel.text = ""
            liveBadge.isHidden = true
        }
        updateControlAvailability()
    }

    private func resolvedLiveSubtitle(for channel: Channel) -> String {
        if let liveTitle = liveNowPlayingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !liveTitle.isEmpty {
            return liveTitle
        }
        if let subtitle = channel.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            return subtitle
        }
        return NSLocalizedString("player_live_subtitle", comment: "Fallback subtitle for live streams")
    }

    private func updateControlAvailability() {
        let live = isLiveStream
        let allowsSkip = !live || hasLiveTimeline
        let controlsAlpha: CGFloat = allowsSkip ? 1.0 : 0.35
        [skipBackwardButton, skipForwardButton].forEach { button in
            button.isEnabled = allowsSkip
            button.alpha = controlsAlpha
        }
        let allowsScrubbing = !live || hasLiveTimeline
        scrubber.isHidden = live && !allowsScrubbing
        scrubber.isUserInteractionEnabled = allowsScrubbing
        scrubber.alpha = allowsScrubbing ? 1.0 : 0.35

        liveBadge.isHidden = !live
    }
    
    @objc private func playPauseTapped() {
        playerManager?.togglePlayPause()
        startControlsTimer()
    }
    
    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }
    
    @objc private func handleTap() {
        toggleControls()
    }
    
    @objc private func closeTapped() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
        resetPictureInPictureController()
        playerLayer?.player = nil
        shouldBlockPlayback = true
        playerManager?.cleanup()
        hasStartedPlayback = false
        isPreparingPlayback = false
        onDismiss?()
    }

    @objc private func pipButtonTapped() {
        guard let controller = pipController, controller.isPictureInPicturePossible else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
        keepControlsVisibleDuringRapidAction()
    }
    
    private func toggleControls() {
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.3) {
            self.controlsView?.alpha = self.controlsVisible ? 1 : 0
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
        
        if controlsVisible {
            startControlsTimer()
        } else {
            controlsTimer?.invalidate()
        }
    }
    
    private func startControlsTimer(after interval: TimeInterval = 5.0) {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }
    
    private func hideControls() {
        guard controlsVisible else { return }
        guard !controlsLockedVisible else { return }
        controlsVisible = false
        UIView.animate(withDuration: 0.3) {
            self.controlsView?.alpha = 0
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }
    
    func setupPlayer(quality: MediathekShow.Quality, startTime: TimeInterval) {
        pendingQuality = quality
        pendingStartTime = startTime
        hasStartedPlayback = false
        startPlaybackIfNeeded()
    }

    private func startPlaybackIfNeeded() {
        guard !hasStartedPlayback, !isPreparingPlayback, !shouldBlockPlayback else { return }
        guard playerLayer != nil, let playerManager else { return }

        let targetShow = show
        let targetChannel = channel
        isPreparingPlayback = true
        controlsTimer?.invalidate()

        DispatchQueue.main.async { [weak self, weak playerManager] in
            guard let self = self, let playerManager = playerManager else { return }
            self.isPreparingPlayback = false

            if let show = targetShow {
                playerManager.loadShow(
                    show,
                    localFileURL: self.localFileURL,
                    quality: self.pendingQuality,
                    startTime: self.pendingStartTime
                )
                self.hasStartedPlayback = true
            } else if let channel = targetChannel {
                playerManager.loadLiveStream(
                    channel,
                    startTime: self.pendingStartTime,
                    qualityOverride: self.pendingQuality
                )
                self.hasStartedPlayback = true
            } else {
                self.hasStartedPlayback = false
                return
            }

            self.playerLayer?.player = playerManager.player
            playerManager.play()
            self.startControlsTimer()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer?.frame = view.bounds
        gradientLayer.frame = bottomBar.contentView.bounds
        startPlaybackIfNeeded()
    }

    deinit {
        pipPossibleObserver = nil
        pipController?.delegate = nil
    }

    private func configurePictureInPictureController(for layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            updatePictureInPictureAvailability(isAvailable: false)
            return
        }

        pipPossibleObserver = nil
        pipController?.delegate = nil

        if #available(iOS 15.0, *) {
            pipController = AVPictureInPictureController(
                contentSource: AVPictureInPictureController.ContentSource(playerLayer: layer)
            )
        } else {
            pipController = AVPictureInPictureController(playerLayer: layer)
        }

        pipController?.delegate = self
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true

        pipPossibleObserver = pipController?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.updatePictureInPictureAvailability(isAvailable: controller.isPictureInPicturePossible)
            }
        }
    }

    private func updatePictureInPictureAvailability(isAvailable: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.pipButton.isEnabled = isAvailable
            self.pipButton.alpha = isAvailable ? 1 : 0.35
        }
        updatePiPButtonIcon(isActive: pipController?.isPictureInPictureActive ?? false)
    }

    private func updatePiPButtonIcon(isActive: Bool) {
        let symbolName: String
        if #available(iOS 15.0, *) {
            symbolName = isActive ? "pip.exit" : "pip.enter"
        } else {
            symbolName = isActive ? "rectangle.fill.on.rectangle.fill" : "rectangle.fill.on.rectangle"
        }
        let image = UIImage(systemName: symbolName) ?? UIImage(systemName: "rectangle.on.rectangle")
        pipButton.setImage(image, for: .normal)
        let labelKey = isActive ? "player_pip_button_stop" : "player_pip_button_start"
        pipButton.accessibilityLabel = NSLocalizedString(labelKey, comment: "Accessibility label for PiP toggle")
    }

    private func resetPictureInPictureController() {
        pipPossibleObserver = nil
        pipController?.delegate = nil
        pipController = nil
        updatePictureInPictureAvailability(isAvailable: false)
    }
}

extension CustomPlayerViewController {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer else { return true }
        var view: UIView? = touch.view
        while let current = view {
            // Erlaube Tap-Gesten explizit auf dem scrubber (Slider)
            if let slider = current as? UISlider, slider === scrubber {
                return true
            }
            if current is UIControl {
                return false
            }
            view = current.superview
        }
        return true
    }
}

extension CustomPlayerViewController {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        updatePiPButtonIcon(isActive: true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        updatePiPButtonIcon(isActive: true)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        updatePiPButtonIcon(isActive: false)
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        updatePiPButtonIcon(isActive: false)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        updatePiPButtonIcon(isActive: false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

struct FullScreenPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        FullScreenPlayerView(channel: Channel(id: "test", name: "Test", stream_url: nil, logo_name: nil, color: nil, subtitle: nil))
    }
}


private class LargeHitSlider: UISlider {
    private let expansionInsets = UIEdgeInsets(top: -14, left: -20, bottom: -14, right: -20)

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let expandedBounds = bounds.inset(by: expansionInsets)
        return expandedBounds.contains(point)
    }
}
