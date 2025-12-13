import SwiftUI
import UIKit

@MainActor
final class PlayerPresentationManager: NSObject, UIAdaptivePresentationControllerDelegate {
    static let shared = PlayerPresentationManager()

    private weak var hostingController: OrientationHostingController<AnyView>?
    private weak var channelRepository: ChannelRepository?
    private var liveNowPlayingRefreshTask: Task<Void, Never>?

    func register(channelRepository: ChannelRepository) {
        self.channelRepository = channelRepository
    }

    func presentChannel(
        _ channel: Channel,
        nowPlaying: ChannelNowPlayingState? = nil,
        startTime: TimeInterval = 0
    ) {
        let preferredQuality = AppSettings.shared.preferredQuality()
        let resolvedNowPlaying = nowPlaying ?? channelRepository?.nowPlayingState(for: channel.id)

        if let repo = channelRepository {
            startLiveNowPlayingRefresh(for: channel.id, repository: repo)
        } else {
            stopLiveNowPlayingRefresh()
        }

        present {
            FullScreenPlayerView(
                channel: channel,
                nowPlayingState: resolvedNowPlaying,
                quality: preferredQuality,
                startTime: startTime
            ) { [weak self] in
                self?.dismissPresented()
            }
        }
    }

    func presentShow(
        _ show: MediathekShow,
        quality: MediathekShow.Quality,
        startTime: TimeInterval = 0,
        channel: Channel? = nil,
        localFileURL: URL? = nil
    ) {
        stopLiveNowPlayingRefresh()
        let resolvedStartTime = resolveStartTime(for: show, requestedStartTime: startTime)
        present {
            FullScreenPlayerView(
                show: show,
                channel: channel,
                quality: quality,
                startTime: resolvedStartTime,
                localFileURL: localFileURL
            ) { [weak self] in
                self?.dismissPresented()
            }
        }
    }

    func dismissPresented(animated: Bool = true) {
        guard let controller = hostingController else { return }

        PlayerOrientationShield.shared.show()
        let fadeDuration: TimeInterval = animated ? 0.15 : 0
        controller.view?.isUserInteractionEnabled = false
        UIView.animate(withDuration: fadeDuration) {
            controller.view?.alpha = 0
        }

        var didCompleteDismissal = false
        let performDismissal: () -> Void = { [weak self] in
            guard let self else { return }
            guard !didCompleteDismissal else { return }
            didCompleteDismissal = true

            controller.dismiss(animated: false) {
                controller.view?.alpha = 1
                controller.view?.isUserInteractionEnabled = true
                self.cleanUpAfterDismissal()
            }
        }

        OrientationManager.shared.allowPortrait {
            performDismissal()
        }
    }

    func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
        PlayerOrientationShield.shared.show()

        let transitionCoordinator = presentationController.presentedViewController.transitionCoordinator

        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in
                OrientationManager.shared.allowPortrait()
            }, completion: { context in
                if context.isCancelled {
                    OrientationManager.shared.lock(to: .landscape, rotateTo: .landscapeRight) {
                        PlayerOrientationShield.shared.hide()
                    }
                }
            })
        } else {
            OrientationManager.shared.allowPortrait()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        cleanUpAfterDismissal()
    }

    private func present<Content: View>(@ViewBuilder content: () -> Content) {
        let wrappedView = AnyView(content())

        guard hostingController == nil else {
            hostingController?.rootView = wrappedView
            return
        }

        PlayerOrientationShield.shared.show()

        OrientationManager.shared.lock(to: .landscape, rotateTo: .landscapeRight) { [weak self] in
            guard let self else { return }
            self.presentController(with: wrappedView, animated: false) { controller in
                controller.view?.alpha = 0
                UIView.animate(withDuration: 0.18, animations: {
                    controller.view?.alpha = 1
                }, completion: { _ in
                    PlayerOrientationShield.shared.hide()
                })
            }
        }
    }

    private func presentController(
        with view: AnyView,
        animated: Bool = true,
        onPresented: ((OrientationHostingController<AnyView>) -> Void)? = nil
    ) {
        guard hostingController == nil else {
            hostingController?.rootView = view
            return
        }

        guard let presenter = Self.topViewController() else {
            OrientationManager.shared.allowPortrait()
            PlayerOrientationShield.shared.hide()
            return
        }

        let controller = OrientationHostingController(rootView: view)
        controller.modalPresentationStyle = .fullScreen
        hostingController = controller
        presenter.present(controller, animated: animated) { [weak controller] in
            controller?.presentationController?.delegate = self
            if let controller {
                onPresented?(controller)
            }
        }
    }

    private func cleanUpAfterDismissal() {
        stopLiveNowPlayingRefresh()
        hostingController = nil
        OrientationManager.shared.allowPortrait()
        PlayerOrientationShield.shared.hide()
    }

    private func startLiveNowPlayingRefresh(for channelId: String, repository: ChannelRepository) {
        liveNowPlayingRefreshTask?.cancel()
        liveNowPlayingRefreshTask = Task {
            while !Task.isCancelled {
                await repository.ensureNowPlaying(for: channelId, priority: .userInitiated)
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            }
        }
    }

    private func stopLiveNowPlayingRefresh() {
        liveNowPlayingRefreshTask?.cancel()
        liveNowPlayingRefreshTask = nil
    }

    private func resolveStartTime(for show: MediathekShow, requestedStartTime: TimeInterval) -> TimeInterval {
        guard requestedStartTime <= 0 else { return requestedStartTime }
        return PersistenceManager.shared.playbackPosition(for: show.id) ?? 0
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              let root = window.rootViewController else { return nil }
        return topViewController(from: root)
    }

    private static func topViewController(from root: UIViewController?) -> UIViewController? {
        if let navigationController = root as? UINavigationController {
            return topViewController(from: navigationController.visibleViewController)
        }
        if let tabBarController = root as? UITabBarController {
            return topViewController(from: tabBarController.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}
