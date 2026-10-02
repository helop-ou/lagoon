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
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.xl)
                .frame(minHeight: proxy.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
}
#endif
