#if os(tvOS)
import SwiftUI
import UIKit

/// tvOS 26 never delivers the Menu press to SwiftUI's `onExitCommand`
/// inside a fullScreenCover — UIKit's presentation controller consumes it
/// and dismisses the cover directly (verified with instrumented handlers:
/// arrows and play/pause reach SwiftUI, Menu does not, and
/// `interactiveDismissDisabled` doesn't gate it). This gate hosts the
/// player content in a UIHostingController that intercepts the Menu press
/// at the responder-chain level, so panel-open vs exit is our decision.
struct MenuPressGate<Content: View>: UIViewControllerRepresentable {
    let onMenu: () -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> MenuGateHostingController<Content> {
        let controller = MenuGateHostingController(rootView: content())
        controller.onMenu = onMenu
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: MenuGateHostingController<Content>, context: Context) {
        controller.rootView = content()
        controller.onMenu = onMenu
    }
}

final class MenuGateHostingController<Content: View>: UIHostingController<Content> {
    var onMenu: (() -> Void)?

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
    }

    @objc private func menuRecognized() {
        onMenu?()
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
