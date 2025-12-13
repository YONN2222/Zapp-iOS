import SwiftUI

final class OrientationHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        OrientationManager.shared.currentMask
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        OrientationManager.shared.preferredInterfaceOrientation
    }

    override var shouldAutorotate: Bool { true }
}

struct OrientationRootView<Content: View>: UIViewControllerRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> OrientationHostingController<Content> {
        OrientationHostingController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: OrientationHostingController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}
