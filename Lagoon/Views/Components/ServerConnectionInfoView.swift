import SwiftUI

/// Keeps the selected scheme, port, and proxy path visible before either
/// password or Quick Connect authentication, including on restored sessions.
struct ServerConnectionInfoView: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text(ServerAddress.displayString(for: url))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("server.connectionAddress")
            if url.scheme?.lowercased() == "http" {
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Label("Connection Not Encrypted", systemImage: "lock.open")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("This server uses HTTP. People with access to your network could read your password, sign-in tokens, and activity. Use HTTPS if your server supports it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("server.httpWarning")
            }
        }
    }
}
