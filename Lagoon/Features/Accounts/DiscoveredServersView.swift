import SwiftUI

/// Servers that answered the local network broadcast, above the address
/// field, so setup on a TV needs no typing.
struct DiscoveredServersView: View {
    let servers: [DiscoveredServer]
    let isSearching: Bool
    let isConnecting: Bool
    #if os(tvOS)
    let focusedServer: FocusState<String?>.Binding
    #endif
    let select: (DiscoveredServer) -> Void
    let searchAgain: () -> Void

    var body: some View {
        if !servers.isEmpty || isSearching {
            VStack(spacing: Metrics.Space.m) {
                ForEach(servers) { server in
                    serverButton(server)
                }
                if isSearching {
                    HStack(spacing: Metrics.Space.s) {
                        ProgressView()
                        Text("Looking for servers on your network")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("server.discovery.searching")
                }
                Text("or")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            Button("Look for Servers Again", action: searchAgain)
                .buttonStyle(.glass)
                .accessibilityIdentifier("server.discovery.retry")
        }
    }

    private func serverButton(_ server: DiscoveredServer) -> some View {
        Button {
            select(server)
        } label: {
            VStack(spacing: Metrics.Space.xs) {
                Text(server.name)
                    .font(.headline)
                Text(ServerAddress.displayString(for: server.address))
                    .font(.caption)
                    // A tvOS glass lozenge turns inherited colours white on white.
                    #if os(iOS)
                    .foregroundStyle(.secondary)
                    #endif
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .disabled(isConnecting)
        #if os(tvOS)
        .focused(focusedServer, equals: server.id)
        #endif
        .accessibilityIdentifier("server.discovered.\(server.id)")
    }
}
