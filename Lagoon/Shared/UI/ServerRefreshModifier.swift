import SwiftUI

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

    func makeUIView(context: Context) -> TopChromeButton {
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
        let button = TopChromeButton(configuration: configuration, primaryAction: UIAction { _ in
            guard !context.coordinator.isRefreshing else { return }
            context.coordinator.action()
        })
        let coordinator = context.coordinator
        button.installMoveDownAction(isAvailable: moveDownAction != nil) {
            coordinator.moveDownAction?()
        }
        button.topChromeOffsetChanged = { context.coordinator.topChromeOffsetChanged($0) }
        return button
    }

    func updateUIView(_ button: TopChromeButton, context: Context) {
        context.coordinator.action = action
        context.coordinator.moveDownAction = moveDownAction
        context.coordinator.topChromeOffsetChanged = topChromeOffsetChanged
        let coordinator = context.coordinator
        button.installMoveDownAction(isAvailable: moveDownAction != nil) {
            coordinator.moveDownAction?()
        }
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
