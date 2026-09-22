import SwiftUI

/// Full-screen spinner. `.focusable()` matters on tvOS: a screen with no
/// focusable element makes the Menu button quit the app instead of popping
/// the navigation stack.
struct LoadingView: View {
    var body: some View {
        ProgressView("Loading")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
            .accessibilityIdentifier("state.loading")
    }
}

/// A next-page failure shown inline, so loaded content stays and the list
/// doesn't look finished.
struct InlineRetryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: Metrics.Space.l) {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.Space.l)

            Button("Try Again", action: retry)
                .buttonStyle(.glass)
        }
        .padding(Metrics.Space.l)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
        .accessibilityIdentifier("state.paginationError")
    }
}

/// Full-screen error with a retry button (which also keeps focus on-screen).
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(Typography.glyph)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            Button("Try Again", action: retry)
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
