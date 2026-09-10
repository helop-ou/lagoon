import SwiftUI

extension View {
    /// iOS retains the hosting controller while PiP owns its display layer.
    /// tvOS keeps SwiftUI's existing full-screen presentation and remote grammar.
    func playerPresentation(item: Binding<PlayerItem?>, onDismiss: @escaping () -> Void) -> some View {
        #if os(iOS)
        background(PlayerPresentationBridge(item: item, onDismiss: onDismiss))
        #else
        fullScreenCover(item: item, onDismiss: onDismiss) { player in
            VideoPlayerView(playerItem: player).preferredColorScheme(.dark)
        }
        #endif
    }
}

#if os(iOS)
private struct PlayerPresentationBridge: UIViewControllerRepresentable {
    @Binding var item: PlayerItem?
    let onDismiss: () -> Void
    @Environment(SessionStore.self) private var session

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ presenter: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.finish = { item = nil; onDismiss() }
        guard let item else {
            coordinator.close()
            return
        }
        guard coordinator.host == nil else { return }
        let player = VideoPlayerView(
            playerItem: item,
            registerPresentationCleanup: { [weak coordinator] cleanup in coordinator?.cleanup = cleanup },
            onPresentationClose: { [weak coordinator] in coordinator?.close() },
            onPictureInPictureStarted: { [weak coordinator] in coordinator?.hide() },
            onPictureInPictureRestore: { [weak coordinator] completion in
                coordinator?.restore(completion: completion)
            }
        ).environment(session).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: AnyView(player))
        host.modalPresentationStyle = .fullScreen
        coordinator.host = host
        coordinator.presenter = presenter
        // Representable updates can precede insertion in the window hierarchy.
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.restore(completion: { _ in })
        }
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.finish = nil
        coordinator.close()
    }

    final class Coordinator {
        var host: UIViewController?
        weak var presenter: UIViewController?
        var finish: (() -> Void)?
        var cleanup: (() -> Void)?

        func hide() {
            host?.dismiss(animated: true)
        }

        func restore(completion: @escaping (Bool) -> Void) {
            guard let host, let presenter, presenter.view.window != nil else {
                completion(false)
                return
            }
            guard host.presentingViewController == nil else { completion(true); return }
            presenter.present(host, animated: true) { completion(true) }
        }

        func close() {
            guard let host else { return }
            self.host = nil
            cleanup?()
            cleanup = nil
            if host.presentingViewController != nil {
                host.dismiss(animated: true) { [weak self] in self?.finish?() }
            } else {
                finish?()
            }
        }
    }
}
#endif
