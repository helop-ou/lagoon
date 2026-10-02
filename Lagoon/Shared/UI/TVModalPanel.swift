#if os(tvOS)
import SwiftUI

/// The tvOS modal panel: title, scrolling content, then Done, in sequence.
/// Not `safeAreaInset` overlays, which draw over the content and need their
/// own material. It owns the panel's fixed size, because a sheet with custom
/// content ignores `presentationSizing` on tvOS and content that changes
/// while open would otherwise resize the panel under focus.
///
/// Menu dismisses, so it agrees with Done. A panel with levels of its own
/// passes `onExit` to take Menu a level back first.
struct TVModalPanel<Leading: View, Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: Text
    let subtitle: LocalizedStringKey?
    let doneIdentifier: String?
    /// Resets the scroll position when it changes, for content that swaps
    /// wholesale.
    let scrollIdentity: AnyHashable?
    let onExit: (() -> Void)?
    @ViewBuilder let leadingActions: Leading
    @ViewBuilder let content: Content

    init(
        title: Text,
        subtitle: LocalizedStringKey? = nil,
        doneIdentifier: String? = nil,
        scrollIdentity: AnyHashable? = nil,
        onExit: (() -> Void)? = nil,
        @ViewBuilder leadingActions: () -> Leading,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.doneIdentifier = doneIdentifier
        self.scrollIdentity = scrollIdentity
        self.onExit = onExit
        self.leadingActions = leadingActions()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                content
                    .padding(.horizontal, Metrics.Space.xl)
                    .padding(.bottom, Metrics.Space.xl)
            }
            .id(scrollIdentity)

            HStack(spacing: Metrics.Space.l) {
                leadingActions
                doneButton
            }
            .padding(Metrics.Space.l)
        }
        .frame(
            width: Metrics.modalPanelSize.width,
            height: Metrics.modalPanelSize.height
        )
        .presentationSizing(.fitted)
        .onExitCommand {
            if let onExit { onExit() } else { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: Metrics.Space.s) {
            title
                .font(.title3.bold())

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.Space.l)
    }

    @ViewBuilder
    private var doneButton: some View {
        let button = Button("Done") { dismiss() }
            .buttonStyle(.glass)
        if let doneIdentifier {
            button.accessibilityIdentifier(doneIdentifier)
        } else {
            button
        }
    }
}

extension TVModalPanel where Leading == EmptyView {
    init(
        title: Text,
        subtitle: LocalizedStringKey? = nil,
        doneIdentifier: String? = nil,
        scrollIdentity: AnyHashable? = nil,
        onExit: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            doneIdentifier: doneIdentifier,
            scrollIdentity: scrollIdentity,
            onExit: onExit,
            leadingActions: { EmptyView() },
            content: content
        )
    }
}
#endif
