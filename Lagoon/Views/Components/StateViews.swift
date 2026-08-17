import SwiftUI

/// Full-screen spinner. `.focusable()` matters on tvOS: a screen with no
/// focusable element makes the Menu button quit the app instead of popping
/// the navigation stack.
struct LoadingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusable()
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
