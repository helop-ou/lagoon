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

    // The Siri Remote sends .menu; the simulator's hardware keyboard sends
    // a keyboard press (type = 2000 + HID usage) whose UIKey is Escape —
    // UIKit translates that to cancel/dismiss too, so both must be caught.
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
