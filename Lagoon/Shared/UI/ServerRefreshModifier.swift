import SwiftUI
#if os(tvOS)
import Symbols
import UIKit
#endif

/// Refresh for a visible top-level destination: foreground reconciliation,
/// a five-minute cadence, and the manual control. Tied to visibility and
/// scene activity, so a hidden tab never polls.
private struct ServerRefreshModifier: ViewModifier {
    let target: ServerSyncTarget
    let isActive: Bool
    let isEnabled: Bool
    let isPaused: Bool
    let action: @MainActor () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(ServerSyncState.self) private var serverSync
    @State private var isVisible = false
    @State private var isRefreshing = false
    // Baselined on first appearance, so a bump that arrives while hidden
    // is replayed when the tab comes back.
    @State private var handledGeneration: Int?

    private var canRefresh: Bool {
        isActive && isEnabled && !isPaused && isVisible && scenePhase == .active
    }

    func body(content: Content) -> some View {
        #if os(tvOS)
        managed(content)
        #else
        managed(content)
            .refreshable {
                await refresh(trigger: .manual)
            }
        #endif
    }

    private func managed(_ content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                if handledGeneration == nil { handledGeneration = serverSync.generation }
            }
            .onDisappear {
                isVisible = false
                serverSync.deactivate(target)
            }
            .onChange(of: canRefresh, initial: true) { _, available in
                if available {
                    serverSync.activate(target)
                    if let handled = handledGeneration, serverSync.generation > handled {
                        handledGeneration = serverSync.generation
                        Task { await refresh(trigger: .foreground) }
                    }
                } else {
                    serverSync.deactivate(target)
                }
            }
            .onChange(of: serverSync.generation) { _, generation in
                guard canRefresh else { return }
                handledGeneration = generation
                Task { await refresh(trigger: .foreground) }
            }
            .onChange(of: serverSync.manualRefreshGeneration) { _, _ in
                guard canRefresh, serverSync.manualRefreshTarget == target else { return }
                Task { await refresh(trigger: .manual) }
            }
            .task(id: canRefresh) {
                guard canRefresh else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: ServerRefreshPolicy.interval())
                    } catch {
                        return
                    }
                    guard canRefresh else { return }
                    await refresh(trigger: .periodic)
                }
            }
    }

    @MainActor
    private func refresh(trigger: ServerRefreshTrigger) async {
        guard canRefresh, !isRefreshing else { return }
        isRefreshing = true
        serverSync.beginRefresh(target)
        #if DEBUG
        serverSync.recordRefresh(target, trigger: trigger)
        #endif
        defer {
            isRefreshing = false
            serverSync.endRefresh(target)
        }
        await action()
    }
}

#if os(tvOS)
/// The manual Refresh sits in MainTabView's full-screen space, not a
/// NavigationStack toolbar: on tvOS a toolbar adds a second bar and puts
/// Refresh in the hero's Down path.
struct ServerRefreshButton: View {
    let target: ServerSyncTarget?
    /// Nonisolated storage for an immutable value passed to the UIKit
    /// control; the action itself runs on the main actor.
    nonisolated let moveDownAction: (@MainActor @Sendable () -> Void)?
    @Binding var topChromeOffset: CGFloat
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var allowsFocus = false

    var body: some View {
        TVServerRefreshControl(
            target: target,
            isRefreshing: target.map(serverSync.isRefreshing) ?? false,
            allowsFocus: allowsFocus && target != nil,
            reduceMotion: reduceMotion,
            moveDownAction: moveDownAction,
            topChromeOffsetChanged: { topChromeOffset = $0 },
            action: {
                guard let target else { return }
                serverSync.requestManualRefresh(for: target)
            }
        )
        // Stay mounted while a detail is pushed, or the tab bar offset is
        // lost and Refresh comes back at zero over the content on Back.
        .opacity(target == nil ? 0 : 1)
        .allowsHitTesting(target != nil)
        .accessibilityHidden(target == nil)
        // Follows the tab bar as TabView scrolls it out with the content.
        .offset(y: topChromeOffset)
        // Grows to about the tab capsule's height under focus expansion.
        .frame(
            width: Metrics.Space.xxl + Metrics.Space.xl,
            height: Metrics.Space.xxl + Metrics.Space.xl
        )
        .task {
            // Let the selected tab take launch focus first.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            allowsFocus = true
        }
    }
}

private struct TVServerRefreshControl: UIViewRepresentable {
    let target: ServerSyncTarget?
    let isRefreshing: Bool
    let allowsFocus: Bool
    let reduceMotion: Bool
    let moveDownAction: (@MainActor @Sendable () -> Void)?
    let topChromeOffsetChanged: @MainActor @Sendable (CGFloat) -> Void
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            action: action,
            moveDownAction: moveDownAction,
            topChromeOffsetChanged: topChromeOffsetChanged
        )
    }

    func makeUIView(context: Context) -> DelayedFocusButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 24
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 16,
            leading: 16,
            bottom: 16,
            trailing: 16
        )
        let button = DelayedFocusButton(configuration: configuration, primaryAction: UIAction { _ in
            guard !context.coordinator.isRefreshing else { return }
            context.coordinator.action()
        })
        button.installMoveDownAction(from: context.coordinator, isAvailable: moveDownAction != nil)
        button.topChromeOffsetChanged = { context.coordinator.topChromeOffsetChanged($0) }
        return button
    }

    func updateUIView(_ button: DelayedFocusButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.moveDownAction = moveDownAction
        context.coordinator.topChromeOffsetChanged = topChromeOffsetChanged
        button.installMoveDownAction(from: context.coordinator, isAvailable: moveDownAction != nil)
        context.coordinator.isRefreshing = isRefreshing
        button.tracksTopChrome = target != nil
        button.allowsFocus = allowsFocus
        button.setIconSpinning(isRefreshing && !reduceMotion)
        button.accessibilityLabel = "Refresh"
        button.accessibilityValue = isRefreshing ? "In progress" : nil
        button.accessibilityIdentifier = target.map { "server.refresh.\($0.identifier)" }
            ?? "server.refresh.inactive"
    }

    final class Coordinator {
        var action: @MainActor () -> Void
        var moveDownAction: (@MainActor @Sendable () -> Void)?
        var topChromeOffsetChanged: @MainActor @Sendable (CGFloat) -> Void
        var isRefreshing = false

        init(
            action: @escaping @MainActor () -> Void,
            moveDownAction: (@MainActor @Sendable () -> Void)?,
            topChromeOffsetChanged: @escaping @MainActor @Sendable (CGFloat) -> Void
        ) {
            self.action = action
            self.moveDownAction = moveDownAction
            self.topChromeOffsetChanged = topChromeOffsetChanged
        }
    }
}

private final class DelayedFocusButton: UIButton {
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
    /// Defensive: unreachable while Refresh sits left of Home.
    func installMoveDownAction(
        from coordinator: TVServerRefreshControl.Coordinator,
        isAvailable: Bool
    ) {
        moveDownAction = isAvailable ? { coordinator.moveDownAction?() } : nil
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

extension View {
    func serverRefreshable(
        _ target: ServerSyncTarget,
        isActive: Bool,
        isEnabled: Bool = true,
        isPaused: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(ServerRefreshModifier(
            target: target,
            isActive: isActive,
            isEnabled: isEnabled,
            isPaused: isPaused,
            action: action
        ))
    }
}
