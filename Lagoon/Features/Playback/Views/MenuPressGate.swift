#if os(tvOS)
import LagoonEngine
import SwiftUI
import UIKit

/// Hosts the tvOS player behind UIKit input hooks SwiftUI cannot express.
///
/// Inside a fullScreenCover, tvOS 26 never delivers Menu to `onExitCommand`:
/// UIKit dismisses the cover itself, ignoring `interactiveDismissDisabled`.
/// Intercepting it here makes panel-open vs exit our decision.
///
/// It also keeps a light Siri Remote touch-surface tap apart from Select.
/// The two must never share a path: a tap reveals the transport, Select
/// toggles playback.
struct MenuPressGate<Content: View>: UIViewControllerRepresentable {
    let onMenu: () -> Void
    let onRemoteTouchTap: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        onMenu: @escaping () -> Void,
        onRemoteTouchTap: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onMenu = onMenu
        self.onRemoteTouchTap = onRemoteTouchTap
        self.content = content
    }

    func makeUIViewController(context: Context) -> MenuGateHostingController<Content> {
        let controller = MenuGateHostingController(rootView: content())
        controller.onMenu = onMenu
        controller.onRemoteTouchTap = onRemoteTouchTap
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: MenuGateHostingController<Content>, context: Context) {
        // Insertions across this boundary cannot animate, even with
        // `context.transaction` forwarded. Animate a value instead, as
        // CustomPlayerView's panel does.
        controller.rootView = content()
        controller.onMenu = onMenu
        controller.onRemoteTouchTap = onRemoteTouchTap
    }
}

final class MenuGateHostingController<Content: View>: UIHostingController<Content> {
    var onMenu: (() -> Void)?
    var onRemoteTouchTap: (() -> Void)?
    private(set) var remoteTouchTapRecognizer: UITapGestureRecognizer?

    // On hardware, UIKit's dismissal gesture recognizer takes Menu before
    // the responder chain, so the presses overrides never see it (the
    // simulator's Escape does). Our own recognizer preempts the system's.
    override func viewDidLoad() {
        super.viewDidLoad()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(menuRecognized))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(recognizer)

        // A tap recognizer defaults to Select on tvOS. No press types plus
        // `.indirect` touches makes it a touch-surface tap only. It does not
        // cancel delivery, so swipes and focus keep their paths.
        let touchTap = UITapGestureRecognizer(
            target: self,
            action: #selector(remoteTouchTapRecognized)
        )
        touchTap.allowedPressTypes = []
        touchTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        touchTap.cancelsTouchesInView = false
        view.addGestureRecognizer(touchTap)
        remoteTouchTapRecognizer = touchTap
    }

    @objc private func menuRecognized() {
        onMenu?()
    }

    @objc func remoteTouchTapRecognized() {
        onRemoteTouchTap?()
    }

    // The simulator keyboard's Escape reaches here via the responder chain,
    // and UIKit would turn it into dismiss, so catch it too.
    private func isMenuPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { $0.type == .menu || $0.key?.keyCode == .keyboardEscape }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !isMenuPress(presses) else { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isMenuPress(presses) {
            onMenu?()
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !isMenuPress(presses) else { return }
        super.pressesCancelled(presses, with: event)
    }
}
#endif
