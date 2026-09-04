import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// Adds all refresh entry points owned by a visible top-level destination:
/// foreground reconciliation, a five-minute active-session cadence, and the
/// platform's explicit manual affordance. The task is tied to visibility and
/// scene activity, so a mounted but hidden tab never polls in the background
/// (HEL-135).
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
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                serverSync.deactivate(target)
            }
            .onChange(of: canRefresh, initial: true) { _, available in
                if available {
                    serverSync.activate(target)
                } else {
                    serverSync.deactivate(target)
                }
            }
            .onChange(of: serverSync.generation) { _, _ in
                guard canRefresh else { return }
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
    let target: ServerSyncTarget
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var allowsFocus = false

    var body: some View {
        TVServerRefreshControl(
            target: target,
            isRefreshing: serverSync.isRefreshing(target),
            allowsFocus: allowsFocus,
            reduceMotion: reduceMotion,
            action: { serverSync.requestManualRefresh(for: target) }
        )
        // UIKit's glass content inset gives the 28pt symbol the same 80pt
        // visual and focus footprint as the tabs.
        .frame(width: Metrics.Space.xxl * 2, height: Metrics.Space.xxl * 2)
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
    let target: ServerSyncTarget
    let isRefreshing: Bool
    let allowsFocus: Bool
    let reduceMotion: Bool
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> DelayedFocusButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 28
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 20,
            leading: 20,
            bottom: 20,
            trailing: 20
        )
        return DelayedFocusButton(configuration: configuration, primaryAction: UIAction { _ in
            guard !context.coordinator.isRefreshing else { return }
            context.coordinator.action()
        })
    }

    func updateUIView(_ button: DelayedFocusButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.isRefreshing = isRefreshing
        button.allowsFocus = allowsFocus
        var configuration = button.configuration ?? .glass()
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.showsActivityIndicator = false
        button.configuration = configuration
        button.setIconSpinning(isRefreshing && !reduceMotion)
        button.accessibilityLabel = "Refresh"
        button.accessibilityValue = isRefreshing ? "In progress" : nil
        button.accessibilityIdentifier = "server.refresh.\(target.identifier)"
    }

    final class Coordinator {
        var action: @MainActor () -> Void
        var isRefreshing = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }
}

private final class DelayedFocusButton: UIButton {
    private static let rotationAnimationKey = "server-refresh.rotation"
    private var shouldSpinIcon = false
    private var isTopChromeFocused = false
    private var observesFocusUpdates = false

    var allowsFocus = false {
        didSet {
            guard allowsFocus != oldValue else { return }
            updateTopChromeFocusState(
                using: UIFocusSystem.focusSystem(for: self)?.focusedItem
            )
            setNeedsFocusUpdate()
        }
    }

    override var canBecomeFocused: Bool {
        allowsFocus && isTopChromeFocused && super.canBecomeFocused
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
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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
    }

    private func updateTopChromeFocusState(using focusedItem: (any UIFocusItem)?) {
        guard let focusedView = focusedItem as? UIView else {
            isTopChromeFocused = false
            return
        }

        var ancestor: UIView? = focusedView
        while let view = ancestor {
            if view === self || view is UITabBar {
                isTopChromeFocused = true
                return
            }
            ancestor = view.superview
        }
        isTopChromeFocused = false
    }

    private func updateIconAnimation() {
        guard let layer = imageView?.layer else { return }
        if shouldSpinIcon {
            guard layer.animation(forKey: Self.rotationAnimationKey) == nil else { return }
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = Double.pi * 2
            rotation.duration = 0.8
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(rotation, forKey: Self.rotationAnimationKey)
        } else {
            layer.removeAnimation(forKey: Self.rotationAnimationKey)
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
