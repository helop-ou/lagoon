#if os(tvOS)
import Symbols
import UIKit

/// A glass control in the tvOS top chrome, beside the tab bar: focusable
/// only while the tab bar (or the control itself) has focus, so it never
/// takes focus from content, and it follows the tab bar as TabView scrolls
/// it away with the content.
final class TopChromeButton: UIButton {
    private var shouldSpinIcon = false
    private weak var animatedImageView: UIImageView?
    private var isTopChromeFocused = false
    private var observesFocusUpdates = false
    private weak var tabBar: UITabBar?
    private var tabBarRestingMinY: CGFloat?
    private var tabBarDisplayLink: CADisplayLink?
    private var tabBarTrackingFramesRemaining = 0
    private var lastReportedTopChromeOffset: CGFloat = 0

    var moveDownAction: (@MainActor @Sendable () -> Void)?
    var topChromeOffsetChanged: (@MainActor @Sendable (CGFloat) -> Void)?

    /// Installs the Down override only where the destination has a hero. A
    /// forwarding closure to an absent action still reads as non-nil to
    /// `shouldUpdateFocus`, which then cancels the move and strands focus.
    func installMoveDownAction(
        isAvailable: Bool,
        forward: @escaping @MainActor @Sendable () -> Void
    ) {
        if isAvailable {
            moveDownAction = forward
        } else {
            moveDownAction = nil
        }
    }

    var tracksTopChrome = false {
        didSet {
            guard tracksTopChrome != oldValue else { return }
            if tracksTopChrome {
                discoverTabBarIfNeeded()
                startTrackingTabBar()
            } else {
                // NavigationStack briefly restores the tab bar's frame while
                // pushing a detail. Freeze at the root's last offset.
                stopTrackingTabBar()
            }
        }
    }

    var allowsFocus = false {
        didSet {
            guard allowsFocus != oldValue else { return }
            updateTopChromeFocusState(
                using: UIFocusSystem.focusSystem(for: self)?.focusedItem
            )
            discoverTabBarIfNeeded()
            setNeedsFocusUpdate()
        }
    }

    override var canBecomeFocused: Bool {
        allowsFocus && isTopChromeFocused && super.canBecomeFocused
    }

    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        guard context.focusHeading.contains(.down),
              isFocused,
              moveDownAction != nil else {
            return super.shouldUpdateFocus(in: context)
        }

        // Cancel only this Down move (TabView would pick its tab bar) and
        // let FocusState select the hero. Up stays with the tab hierarchy.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFocused else { return }
            self.moveDownAction?()
        }
        return false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !observesFocusUpdates {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(focusDidUpdate(_:)),
                name: UIFocusSystem.didUpdateNotification,
                object: nil
            )
            observesFocusUpdates = true
            updateTopChromeFocusState(
                using: UIFocusSystem.focusSystem(for: self)?.focusedItem
            )
        } else if window == nil, observesFocusUpdates {
            NotificationCenter.default.removeObserver(self)
            observesFocusUpdates = false
            isTopChromeFocused = false
            stopTrackingTabBar()
            tabBar = nil
            tabBarRestingMinY = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        discoverTabBarIfNeeded()
        updateIconAnimation()
    }

    func setIconSpinning(_ spinning: Bool) {
        shouldSpinIcon = spinning
        updateIconAnimation()
    }

    @objc private func focusDidUpdate(_ notification: Notification) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
            as? UIFocusUpdateContext else { return }
        updateTopChromeFocusState(using: context.nextFocusedItem)
        startTrackingTabBar()
    }

    private func updateTopChromeFocusState(using focusedItem: (any UIFocusItem)?) {
        guard let focusedView = focusedItem as? UIView else {
            isTopChromeFocused = false
            return
        }

        var ancestor: UIView? = focusedView
        while let view = ancestor {
            if view === self {
                isTopChromeFocused = true
                return
            }
            if let tabBar = view as? UITabBar {
                self.tabBar = tabBar
                captureRestingPosition(of: tabBar)
                isTopChromeFocused = true
                startTrackingTabBar()
                return
            }
            ancestor = view.superview
        }
        isTopChromeFocused = false
    }

    private func captureRestingPosition(of tabBar: UITabBar) {
        guard tabBarRestingMinY == nil,
              let window,
              let superview = tabBar.superview else { return }
        tabBarRestingMinY = superview.convert(tabBar.frame, to: window).minY
    }

    private func discoverTabBarIfNeeded() {
        guard tracksTopChrome, tabBar == nil, let window,
              let discovered = firstTabBar(in: window) else { return }
        tabBar = discovered
        tabBarRestingMinY = nil
        captureRestingPosition(of: discovered)
        startTrackingTabBar()
    }

    private func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for subview in view.subviews {
            if let tabBar = firstTabBar(in: subview) { return tabBar }
        }
        return nil
    }

    private func startTrackingTabBar() {
        guard tracksTopChrome, tabBar != nil, tabBarRestingMinY != nil else { return }
        // Focus scrolling animates after the notification; sample the
        // presentation frame so the overlay follows the chrome.
        tabBarTrackingFramesRemaining = 120
        guard tabBarDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(sampleTabBarPosition))
        displayLink.add(to: .main, forMode: .common)
        tabBarDisplayLink = displayLink
    }

    private func stopTrackingTabBar() {
        tabBarDisplayLink?.invalidate()
        tabBarDisplayLink = nil
        tabBarTrackingFramesRemaining = 0
    }

    @objc private func sampleTabBarPosition() {
        guard let window,
              let tabBar,
              let superview = tabBar.superview,
              let tabBarRestingMinY else {
            stopTrackingTabBar()
            return
        }

        let frame = tabBar.layer.presentation()?.frame ?? tabBar.frame
        let minY = superview.convert(frame, to: window).minY
        let offset = minY - tabBarRestingMinY
        if abs(offset - lastReportedTopChromeOffset) >= 0.5 {
            lastReportedTopChromeOffset = offset
            topChromeOffsetChanged?(offset)
        }

        tabBarTrackingFramesRemaining -= 1
        if tabBarTrackingFramesRemaining <= 0 {
            stopTrackingTabBar()
        }
    }

    private func updateIconAnimation() {
        guard let imageView else { return }
        if shouldSpinIcon {
            guard animatedImageView !== imageView else { return }
            animatedImageView?.removeSymbolEffect(ofType: .rotate)
            imageView.addSymbolEffect(
                .rotate,
                options: .repeating.speed(0.6)
            )
            animatedImageView = imageView
        } else if let animatedImageView {
            animatedImageView.removeSymbolEffect(ofType: .rotate)
            self.animatedImageView = nil
        }
    }
}
#endif
