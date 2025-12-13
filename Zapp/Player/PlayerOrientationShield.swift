import UIKit

final class PlayerOrientationShield {
    static let shared = PlayerOrientationShield()

    private weak var shieldView: UIView?

    private init() {}

    func show() {
        DispatchQueue.main.async {
            guard self.shieldView == nil, let hostWindow = self.keyWindow else { return }
            let overlay = UIView(frame: hostWindow.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = UIColor.black
            overlay.alpha = 0
            hostWindow.addSubview(overlay)
            self.shieldView = overlay

            UIView.animate(withDuration: 0.12) {
                overlay.alpha = 1
            }
        }
    }

    func hide(animated: Bool = true) {
        DispatchQueue.main.async {
            guard let shield = self.shieldView else { return }
            self.shieldView = nil
            let animations = {
                shield.alpha = 0
            }
            let completion: (Bool) -> Void = { _ in
                shield.removeFromSuperview()
            }

            if animated {
                UIView.animate(withDuration: 0.15, animations: animations, completion: completion)
            } else {
                animations()
                completion(true)
            }
        }
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) ??
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })
    }
}
