import LagoonEngine
import SwiftUI

extension View {
    /// tvOS keeps SwiftUI's full-screen presentation and remote grammar on
    /// whichever screen started playback. iOS only *requests* playback here:
    /// the one `playerPresentationHost` at the tab root presents it, so the
    /// player never depends on the screen that asked for it staying mounted.
    /// `onDismiss` still reaches the requesting screen once the
    /// player has closed, PiP included.
    func playerPresentation(item: Binding<PlayerItem?>, onDismiss: @escaping () -> Void) -> some View {
        #if os(iOS)
        modifier(PlayerPresentationRequest(item: item, onDismiss: onDismiss))
        #else
        fullScreenCover(item: item, onDismiss: onDismiss) { player in
            VideoPlayerView(playerItem: player).preferredColorScheme(.dark)
        }
        #endif
    }

    #if os(iOS)
    /// Mount exactly once, outside every `NavigationStack`, and put the hub
    /// in the environment of everything that may call `playerPresentation`.
    func playerPresentationHost(_ hub: PlayerPresentationHub) -> some View {
        background(PlayerPresentationBridge(hub: hub))
    }
    #endif
}

#if os(iOS)
/// The single place iOS playback is presented from. A pushed detail page
/// used to host its own presenting controller; presenting from inside a
/// `NavigationStack` destination made the stack briefly show its root, and
/// any view update in that window dropped the destination, which dismantled
/// the presenter and closed the player about a second after it opened.
/// The tab root is outside every stack, so it has none of that.
@MainActor
@Observable
final class PlayerPresentationHub {
    struct Request {
        let item: PlayerItem
        /// Clears the requesting screen's item and runs its `onDismiss`.
        let finish: () -> Void
    }

    private(set) var request: Request?

    func present(_ item: PlayerItem, finish: @escaping () -> Void) {
        // The UI cannot ask for a second player while one is up; a repeat of
        // the same request (a screen re-evaluating its item) is a no-op.
        guard request == nil else { return }
        request = Request(item: item, finish: finish)
    }

    /// The requesting screen dropped its item (an account switch clears
    /// them, for instance): the host closes the player it is showing.
    func withdraw(_ id: PlayerItem.ID) {
        guard request?.item.id == id else { return }
        request = nil
    }

    /// The host has closed the player; hand the outcome back to the screen.
    func finished() {
        let finished = request
        request = nil
        finished?.finish()
    }
}

private struct PlayerPresentationRequest: ViewModifier {
    @Binding var item: PlayerItem?
    let onDismiss: () -> Void
    @Environment(PlayerPresentationHub.self) private var hub

    func body(content: Content) -> some View {
        content.onChange(of: item?.id, initial: true) { previous, current in
            if let item, current != nil {
                hub.present(item) {
                    self.item = nil
                    onDismiss()
                }
            } else if let previous {
                hub.withdraw(previous)
            }
        }
    }
}

/// iOS retains the hosting controller while PiP owns its display layer.
private struct PlayerPresentationBridge: UIViewControllerRepresentable {
    let hub: PlayerPresentationHub
    @Environment(SessionStore.self) private var session
    /// The hosted player is outside SwiftUI's environment, so everything
    /// it reads is re-injected below — Watch Together included.
    @Environment(SyncPlayStore.self) private var syncPlay

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ presenter: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.finish = { hub.finished() }
        guard let item = hub.request?.item else {
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
        ).environment(session).environment(syncPlay).preferredColorScheme(.dark)
        let host = UIHostingController(rootView: AnyView(player))
        // `.overFullScreen`, never `.fullScreen`: a full-screen presentation
        // removes the presenting hierarchy from the window once its
        // transition ends, and SwiftUI answers by re-running the `.task`s of
        // everything underneath — the root view's regression bootstrap
        // included. Keeping the hierarchy is also what lets
        // `restore` find the presenter in a window after PiP.
        host.modalPresentationStyle = .overFullScreen
        // The player paints its own black; a clear host lets the requesting
        // screen show through while a swipe carries the player down.
        host.view.backgroundColor = .clear
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
