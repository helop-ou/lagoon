import SwiftUI

/// The red failure line under an onboarding screen's controls.
struct OnboardingErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
    }
}

#if os(iOS)
/// The iPhone and iPad onboarding column: centred while everything fits, and
/// scrolling once the custom headers, the heading or the keyboard take the room.
struct OnboardingColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Metrics.Space.xl) {
                    content
                }
                .frame(maxWidth: Metrics.onboardingColumnWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.xl)
                .frame(minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}

/// Onboarding text fields as one rounded card with a hairline between rows,
/// like the system's own sign-in screens. Give each field `OnboardingField`.
struct OnboardingFieldGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(spacing: 0) {
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview
                    if index < subviews.count - 1 {
                        Divider().padding(.leading, Metrics.Space.l)
                    }
                }
            }
            .background(
                Theme.surface ?? Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: Metrics.onboardingFieldCornerRadius, style: .continuous)
            )
        }
    }
}

/// One row of an `OnboardingFieldGroup`. tvOS keeps its system fields.
struct OnboardingField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Metrics.Space.l)
            .frame(minHeight: Metrics.onboardingFieldHeight)
    }
}
#endif
