import SwiftUI

/// A Quick Connect code waiting to be entered elsewhere, with its
/// instructions and a spinner while the caller polls. Display only: each
/// caller owns its polling and its policy.
struct QuickConnectCodeView: View {
    let code: String
    let instructions: LocalizedStringKey
    /// For UI tests that read the code.
    var codeIdentifier: String?

    var body: some View {
        VStack(spacing: Metrics.Space.m) {
            codeText
            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
        }
    }

    @ViewBuilder
    private var codeText: some View {
        let text = Text(code)
            .font(Typography.quickConnectCode)
            .tracking(Typography.quickConnectCodeTracking)
        if let codeIdentifier {
            text.accessibilityIdentifier(codeIdentifier)
        } else {
            text
        }
    }
}
