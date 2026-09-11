#if os(tvOS)
import SwiftUI
import UIKit

/// Hosts the tvOS player behind the UIKit input hooks SwiftUI cannot express.
///
/// tvOS 26 never delivers the Menu press to SwiftUI's `onExitCommand`
/// inside a fullScreenCover — UIKit's presentation controller consumes it
/// and dismisses the cover directly (verified with instrumented handlers:
/// arrows and play/pause reach SwiftUI, Menu does not, and
/// `interactiveDismissDisabled` doesn't gate it). The hosting controller
/// intercepts that press so panel-open vs exit is our decision.
///
/// It also distinguishes a light tap on the Siri Remote's touch surface from
/// a Select press (HEL-134). SwiftUI's `onTapGesture` receives Select on tvOS;
/// UIKit exposes a touch-only tap by giving `UITapGestureRecognizer` an empty
/// `allowedPressTypes` array. Keeping these paths separate lets a light tap
/// reveal the transport without toggling playback.
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
        // Forwarding `context.transaction` around this assignment was tried
        // (2026-08-17) and does **not** make transitions inside the hosted
        // tree animate — frame-by-frame capture showed the panel still
        // appearing whole between two frames 0.04 s apart. Insertions across
        // this boundary can't animate; animate a value instead, as
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

    // Hardware finding (Jaagop's Apple TV): a real Siri Remote .menu press
    // is consumed by UIKit's presentation-dismissal *gesture recognizer*
    // before press delivery ever reaches the responder chain — the
    // pressesBegan/Ended overrides below never see it (the simulator's
    // keyboard Escape takes the responder path, which is why the sim
    // passed). Our own recognizer inside the hierarchy preempts the
    // system's, making the panel-open-vs-exit policy ours on hardware too.
    override func viewDidLoad() {
        super.viewDidLoad()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(menuRecognized))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        view.addGestureRecognizer(recognizer)

        // A UITapGestureRecognizer defaults to Select on tvOS. Emptying the
        // press list switches it to taps on a touchpad-like surface; limiting
        // the touch list to `.indirect` makes that Siri Remote intent
        // explicit. It does not cancel delivery to the hosted SwiftUI view,
        // so directional swipes and its focus ownership keep their existing
        // paths (HEL-134).
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

    // The simulator's hardware keyboard sends a keyboard press (type =
    // 2000 + HID usage) whose UIKey is Escape — no gesture recognizer
    // matches it, so it arrives here via the responder chain; UIKit would
    // translate it to cancel/dismiss, so it must be caught too.
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
