#if os(tvOS)
import SwiftUI
import UIKit

/// The active profile at the top right, opening "Who's watching?". It
/// mirrors Refresh at the top left on the same control, so it is reached
/// from the tab bar (Right from the last tab) and never takes focus from
/// content.
struct ProfileButton: View {
    let image: UIImage?
    let profileName: String
    /// False over pushed details. Stays mounted there, or the tab bar
    /// offset is lost, as with Refresh.
    let isAvailable: Bool
    nonisolated let moveDownAction: (@MainActor @Sendable () -> Void)?
    let action: @MainActor () -> Void
    @State private var allowsFocus = false
    @State private var topChromeOffset: CGFloat = 0

    var body: some View {
        TVProfileControl(
            image: image,
            profileName: profileName,
            allowsFocus: allowsFocus && isAvailable,
            tracksTopChrome: isAvailable,
            moveDownAction: moveDownAction,
            topChromeOffsetChanged: { [offset = $topChromeOffset] in offset.wrappedValue = $0 },
            action: { action() }
        )
        .opacity(isAvailable ? 1 : 0)
        .allowsHitTesting(isAvailable)
        .accessibilityHidden(!isAvailable)
        .offset(y: topChromeOffset)
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

private struct TVProfileControl: UIViewRepresentable {
    let image: UIImage?
    let profileName: String
    let allowsFocus: Bool
    let tracksTopChrome: Bool
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
        let button = TopChromeButton(configuration: .glass(), primaryAction: UIAction { _ in
            context.coordinator.action()
        })
        let coordinator = context.coordinator
        button.installMoveDownAction(isAvailable: moveDownAction != nil) {
            coordinator.moveDownAction?()
        }
        button.topChromeOffsetChanged = { coordinator.topChromeOffsetChanged($0) }
        return button
    }

    func updateUIView(_ button: TopChromeButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.action = action
        coordinator.moveDownAction = moveDownAction
        coordinator.topChromeOffsetChanged = topChromeOffsetChanged
        button.installMoveDownAction(isAvailable: moveDownAction != nil) {
            coordinator.moveDownAction?()
        }
        if coordinator.image !== image || button.configuration?.image == nil {
            coordinator.image = image
            button.configuration = configuration(for: image)
        }
        button.tracksTopChrome = tracksTopChrome
        button.allowsFocus = allowsFocus
        button.accessibilityLabel = "Switch Profile"
        button.accessibilityValue = profileName
        button.accessibilityIdentifier = "profile.button"
        // SwiftUI's accessibilityHidden does not reach the UIKit button.
        button.isAccessibilityElement = tracksTopChrome
        button.accessibilityElementsHidden = !tracksTopChrome
    }

    /// The portrait inside a thin glass ring, the size of Refresh's circle;
    /// a person glyph until the portrait has rendered.
    private func configuration(for image: UIImage?) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.glass()
        if let image {
            configuration.image = image
            let inset = (Metrics.Space.xxl + Metrics.Space.l - Metrics.chromeProfilePortraitSize) / 2
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: inset, leading: inset, bottom: inset, trailing: inset
            )
        } else {
            configuration.image = UIImage(systemName: "person.fill")
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 24)
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        }
        return configuration
    }

    final class Coordinator {
        var action: @MainActor () -> Void
        var moveDownAction: (@MainActor @Sendable () -> Void)?
        var topChromeOffsetChanged: @MainActor @Sendable (CGFloat) -> Void
        var image: UIImage?

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
