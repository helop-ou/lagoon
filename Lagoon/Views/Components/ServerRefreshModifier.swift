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
/// A UIKit focus guide fills the otherwise empty safe-zone strip beside the
/// hero and redirects a rightward Siri Remote move to the visible Refresh
/// button. SwiftUI's `focusSection` also participates in default and vertical
/// focus selection, which makes a full-width guide steal Up from the tab bar.
struct ServerRefreshFocusGuide: UIViewRepresentable {
    let destination: ServerSyncTarget

    func makeUIView(context: Context) -> ServerRefreshFocusGuideView {
        ServerRefreshFocusGuideView(identifier: destination.identifier)
    }

    func updateUIView(_ view: ServerRefreshFocusGuideView, context: Context) {
        view.destinationIdentifier = destination.identifier
        view.resolveDestination()
    }
}

final class ServerRefreshFocusGuideView: UIView {
    var destinationIdentifier: String {
        didSet { resolveDestination() }
    }

    private let focusGuide = UIFocusGuide()

    init(identifier: String) {
        destinationIdentifier = identifier
        super.init(frame: .zero)
        backgroundColor = .clear
        addLayoutGuide(focusGuide)
        NSLayoutConstraint.activate([
            focusGuide.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusGuide.trailingAnchor.constraint(equalTo: trailingAnchor),
            focusGuide.topAnchor.constraint(equalTo: topAnchor),
            focusGuide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveDestination()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if focusGuide.preferredFocusEnvironments.isEmpty {
            resolveDestination()
        }
    }

    func resolveDestination() {
        guard let window else {
            focusGuide.preferredFocusEnvironments = []
            return
        }
        let identifier = "server.refresh.\(destinationIdentifier)"
        focusGuide.preferredFocusEnvironments = window.firstSubview(with: identifier).map { [$0] } ?? []
    }
}

private extension UIView {
    func firstSubview(with identifier: String) -> UIView? {
        if accessibilityIdentifier == identifier { return self }
        for subview in subviews {
            if let match = subview.firstSubview(with: identifier) { return match }
        }
        return nil
    }
}

/// The manual action sits in MainTabView's full-screen coordinate space, not
/// in a NavigationStack toolbar. A native toolbar adds a second horizontal
/// bar below tvOS's tabs and puts Refresh directly in the hero's Down path.
/// This separate control shares the top chrome without changing layout.
struct ServerRefreshButton: View {
    let target: ServerSyncTarget
    @Environment(ServerSyncState.self) private var serverSync
    @State private var allowsFocus = false

    var body: some View {
        TVServerRefreshControl(
            target: target,
            isRefreshing: serverSync.isRefreshing(target),
            allowsFocus: allowsFocus,
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
            context.coordinator.action()
        })
    }

    func updateUIView(_ button: DelayedFocusButton, context: Context) {
        context.coordinator.action = action
        button.allowsFocus = allowsFocus
        var configuration = button.configuration ?? .glass()
        configuration.image = isRefreshing ? nil : UIImage(systemName: "arrow.clockwise")
        configuration.showsActivityIndicator = isRefreshing
        button.configuration = configuration
        button.isEnabled = !isRefreshing
        button.accessibilityLabel = isRefreshing ? "Refreshing" : "Refresh"
        button.accessibilityIdentifier = "server.refresh.\(target.identifier)"
    }

    final class Coordinator {
        var action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }
}

private final class DelayedFocusButton: UIButton {
    var allowsFocus = false {
        didSet {
            guard allowsFocus != oldValue else { return }
            setNeedsFocusUpdate()
        }
    }

    override var canBecomeFocused: Bool {
        allowsFocus && super.canBecomeFocused
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
