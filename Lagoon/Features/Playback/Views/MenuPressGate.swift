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
///
/// Select is taken here too, not by the surface's `onTapGesture`. On a Siri
/// Remote every click also touches the clickpad, and the swipe gesture behind
/// `onMoveCommand` then beats the tap: a lone click did nothing and only a
/// double-click got through. The simulator sends no touch, so it
/// never showed.
struct MenuPressGate<Content: View>: UIViewControllerRepresentable {
    let onMenu: () -> Void
    let canTakeSelect: () -> Bool
    let onSelect: () -> Void
    let onRemoteTouchTap: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        onMenu: @escaping () -> Void,
        canTakeSelect: @escaping () -> Bool = { false },
        onSelect: @escaping () -> Void = {},
        onRemoteTouchTap: @escaping () -> Void = {},
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onMenu = onMenu
        self.canTakeSelect = canTakeSelect
        self.onSelect = onSelect
        self.onRemoteTouchTap = onRemoteTouchTap
        self.content = content
    }

    func makeUIViewController(context: Context) -> MenuGateHostingController<Content> {
        let controller = MenuGateHostingController(rootView: content())
        controller.onMenu = onMenu
        controller.canTakeSelect = canTakeSelect
        controller.onSelect = onSelect
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
        controller.canTakeSelect = canTakeSelect
        controller.onSelect = onSelect
        controller.onRemoteTouchTap = onRemoteTouchTap
    }
}

final class MenuGateHostingController<Content: View>: UIHostingController<Content> {
    var onMenu: (() -> Void)?
    var canTakeSelect: (() -> Bool)?
    var onSelect: (() -> Void)?
    var onRemoteTouchTap: (() -> Void)?
    /// Decided when the press begins. By the time it ends, a panel button's
    /// action may already have changed the state the check reads.
    private var selectArmed = false
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
        PlayerInputTrace.log("menu via=gate-recognizer")
        onMenu?()
    }

    @objc func remoteTouchTapRecognized() {
        PlayerInputTrace.log("touch-tap via=gate-recognizer")
        onRemoteTouchTap?()
    }

    // The simulator keyboard's Escape reaches here via the responder chain,
    // and UIKit would turn it into dismiss, so catch it too.
    private func isMenuPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { $0.type == .menu || $0.key?.keyCode == .keyboardEscape }
    }

    private func isSelectPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { $0.type == .select }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        PlayerInputTrace.log("began \(Self.describe(presses)) via=pressesBegan")
        guard !isMenuPress(presses) else { return }
        if isSelectPress(presses) {
            selectArmed = canTakeSelect?() ?? false
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        PlayerInputTrace.log("ended \(Self.describe(presses)) via=pressesEnded")
        if isMenuPress(presses) {
            onMenu?()
            return
        }
        if isSelectPress(presses), selectArmed {
            selectArmed = false
            onSelect?()
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        PlayerInputTrace.log("cancelled \(Self.describe(presses)) via=pressesCancelled")
        guard !isMenuPress(presses) else { return }
        if isSelectPress(presses) {
            selectArmed = false
        }
        super.pressesCancelled(presses, with: event)
    }

    private static func describe(_ presses: Set<UIPress>) -> String {
        presses.map { press in
            let name = switch press.type {
            case .menu: "menu"
            case .select: "select"
            case .playPause: "playPause"
            case .upArrow: "up"
            case .downArrow: "down"
            case .leftArrow: "left"
            case .rightArrow: "right"
            case .pageUp: "pageUp"
            case .pageDown: "pageDown"
            default: "type\(press.type.rawValue)"
            }
            return press.key.map { "\(name)(key \($0.keyCode.rawValue))" } ?? name
        }
        .sorted()
        .joined(separator: ",")
    }
}
#endif
