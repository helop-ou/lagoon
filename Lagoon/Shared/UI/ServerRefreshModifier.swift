import SwiftUI
#if os(tvOS)
import Symbols
import UIKit
#endif

/// Adds all refresh entry points owned by a visible top-level destination:
/// foreground reconciliation, a five-minute active-session cadence, and the
/// platform's explicit manual affordance. The task is tied to visibility and
/// scene activity, so a mounted but hidden tab never polls in the background.
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
    // Baselined on first appearance so a bump that arrives while this
    // destination is hidden is replayed when it comes back, rather than
    // leaving the tab on pre-background content until its own cadence.
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
/// The manual action sits in MainTabView's full-screen coordinate space, not
/// in a NavigationStack toolbar. A native toolbar adds a second horizontal
/// bar below tvOS's tabs and puts Refresh directly in the hero's Down path.
/// This separate control shares the top chrome without changing layout.
struct ServerRefreshButton: View {
    let target: ServerSyncTarget?
    /// Handed straight to the UIKit control below. The action itself is main
    /// actor work — its type says so, and the coordinator only ever calls it
    /// from a focus callback — but the value passing through this view is
    /// immutable and belongs to no actor, so the storage is nonisolated.
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
        // Keep the UIKit control mounted while a detail is pushed so it can
        // retain and follow the native tab bar's presentation offset. Merely
        // removing it here loses that measurement and recreates Refresh at
        // offset zero over the root content when Back is pressed.
        .opacity(target == nil ? 0 : 1)
        .allowsHitTesting(target != nil)
        .accessibilityHidden(target == nil)
        // TabView scrolls its native tab bar out with the content. The
        // separate Refresh overlay mirrors that movement instead of staying
        // pinned over whichever rail the user reaches.
        .offset(y: topChromeOffset)
        // The 64pt base grows to roughly the tab capsule's visual height when
        // tvOS applies its native focus expansion.
        .frame(
            width: Metrics.Space.xxl + Metrics.Space.xl,
            height: Metrics.Space.xxl + Metrics.Space.xl
        )
        .task {
            // Let the selected tab receive launch focus before this separate
            // overlay joins the focus graph.
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

    /// Installs the Down override only where the destination actually has a
    /// hero to move to. A wrapper closure that merely forwards to an absent
    /// coordinator action still reads as non-nil to `shouldUpdateFocus`,
    /// which then cancels the move and returns focus to nowhere — Discover
    /// and the library tabs have no hero binding.
    ///
    /// Defensive rather than a fix for a reachable bug: Refresh sits left of
    /// Home, tab selection follows focus, so focus cannot arrive here without
    /// having selected Home on the way and made `.home` the active target.
    /// A UI test for the trap was written and removed for that reason. This
    /// keeps the override honest if the control ever moves.
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
                // NavigationStack briefly restores the tab bar's own frame
                // while replacing the root with a detail. Freeze Refresh at
                // the root's last scroll offset during that transition; the
                // control is hidden and inert until the root is active again.
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

        // TabView normally resolves this move to its own tab bar. Cancel only
        // that Down update and let SwiftUI's FocusState select the current
        // hero. Up from the hero remains wholly owned by the tab hierarchy.
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
        // Focus-driven scrolling can begin after the focus notification and
        // runs as an animation. Sample its presentation frame briefly so the
        // SwiftUI overlay follows the actual chrome rather than jumping to
        // the tab bar's final model position.
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
