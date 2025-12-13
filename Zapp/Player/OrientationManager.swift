import UIKit
import OSLog

final class OrientationManager {
    static let shared = OrientationManager()
    private(set) var currentMask: UIInterfaceOrientationMask = .portrait
    private var geometryUpdateInFlight = false
    private var pendingGeometryMask: UIInterfaceOrientationMask?
    private var pendingCompletionBlocks: [() -> Void] = []
    @available(iOS 16.0, *)
    private var geometryCompletionWorkItem: DispatchWorkItem?

    private init() {}

    private let orientationLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Zapp", category: "Orientation")

    private func addCompletion(_ completion: (() -> Void)?) {
        guard let completion else { return }
        pendingCompletionBlocks.append(completion)
    }

    private func runPendingCompletions() {
        guard !pendingCompletionBlocks.isEmpty else { return }
        let completions = pendingCompletionBlocks
        pendingCompletionBlocks.removeAll()
        completions.forEach { $0() }
    }

    func lock(to mask: UIInterfaceOrientationMask, rotateTo orientation: UIInterfaceOrientation? = nil, completion: (() -> Void)? = nil) {
        let work = {
            self.addCompletion(completion)

            guard mask != self.currentMask else {
                if let orientation { self.setDeviceOrientation(orientation) }
                if #available(iOS 16.0, *), self.geometryUpdateInFlight { return }
                self.runPendingCompletions()
                return
            }

            self.currentMask = mask
            self.updateOrientation(mask)
            if let orientation { self.setDeviceOrientation(orientation) }
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    func forceLandscape(completion: (() -> Void)? = nil) {
        lock(to: .landscape, rotateTo: .landscapeRight, completion: completion)
    }

    func allowPortrait(completion: (() -> Void)? = nil) {
        lock(to: .portrait, rotateTo: .portrait, completion: completion)
    }

    var preferredInterfaceOrientation: UIInterfaceOrientation {
        preferredInterfaceOrientation(for: currentMask)
    }

    func preferredInterfaceOrientation(for mask: UIInterfaceOrientationMask) -> UIInterfaceOrientation {
        if mask.contains(.landscapeRight) { return .landscapeRight }
        if mask.contains(.landscapeLeft) { return .landscapeLeft }
        if mask.contains(.portraitUpsideDown) { return .portraitUpsideDown }
        return .portrait
    }

    private func updateOrientation(_ mask: UIInterfaceOrientationMask) {
        let performUpdate = {
            self.notifyControllersAboutOrientationChange()

            guard #available(iOS 16.0, *) else {
                self.runPendingCompletions()
                return
            }

            self.enqueueGeometryUpdate(for: mask)
        }

        if Thread.isMainThread {
            performUpdate()
        } else {
            DispatchQueue.main.async { performUpdate() }
        }
    }

    @available(iOS 16.0, *)
    private func enqueueGeometryUpdate(for mask: UIInterfaceOrientationMask) {
        guard !geometryUpdateInFlight else {
            pendingGeometryMask = mask
            return
        }

        guard let scene = activeScene() else { return }

        geometryUpdateInFlight = true
        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
        scheduleGeometryCompletion()

        scene.requestGeometryUpdate(preferences) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.geometryCompletionWorkItem?.cancel()
                self.geometryCompletionWorkItem = nil
                self.geometryUpdateInFlight = false
                self.orientationLogger.error("Orientation update error: \(String(describing: error))")
                self.runPendingCompletions()
                if self.pendingGeometryMask == nil {
                    self.pendingGeometryMask = mask
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let nextMask = self.pendingGeometryMask {
                        self.pendingGeometryMask = nil
                        self.enqueueGeometryUpdate(for: nextMask)
                    }
                }
            }
        }
    }

    @available(iOS 16.0, *)
    private func scheduleGeometryCompletion() {
        geometryCompletionWorkItem?.cancel()
        let completion = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.geometryCompletionWorkItem = nil
            self.geometryUpdateInFlight = false
            self.runPendingCompletions()
            if let nextMask = self.pendingGeometryMask {
                self.pendingGeometryMask = nil
                self.enqueueGeometryUpdate(for: nextMask)
            }
        }
        geometryCompletionWorkItem = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: completion)
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
    }

    private func setDeviceOrientation(_ orientation: UIInterfaceOrientation) {
        guard #unavailable(iOS 16.0) else { return }
        UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
        notifyControllersAboutOrientationChange()
    }

    private func notifyControllersAboutOrientationChange() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })

        guard let rootViewController = (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController else { return }

        let updateBlock = {
            if #available(iOS 16.0, *) {
                rootViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
            } else {
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }

        if Thread.isMainThread {
            updateBlock()
        } else {
            DispatchQueue.main.async { updateBlock() }
        }
    }
}
