import SwiftUI
import Testing
@testable import Lagoon

/// The servers that answered the local network search, in each state the
/// connect screen shows them.
@Suite("Discovered server snapshots", .serialized)
@MainActor
struct DiscoveredServerSnapshotTests {
    #if os(tvOS)
    private static let list = CGSize(width: Metrics.readableWidth + 80, height: 420)
    #else
    private static let list = CGSize(width: 402, height: 300)
    #endif

    private static let servers = [
        DiscoveredServer(id: "living-room", name: "Living Room", address: URL(string: "http://192.168.1.20:8096")!),
        DiscoveredServer(id: "study", name: "Study", address: URL(string: "https://media.home.arpa/jellyfin")!),
    ]

    @Test func serversOnTheNetworkSitAboveTheAddress() async throws {
        try await Snapshot.verify(
            ServerList(servers: Self.servers, isSearching: false).padding(), named: "servers-found", size: Self.list
        )
    }

    @Test func aSearchInProgressSaysSo() async throws {
        try await Snapshot.verify(
            ServerList(servers: Array(Self.servers.prefix(1)), isSearching: true).padding(),
            named: "servers-searching", size: Self.list
        )
    }

    @Test func noServerFoundOffersAnotherLook() async throws {
        try await Snapshot.verify(
            ServerList(servers: [], isSearching: false).padding(), named: "servers-none", size: Self.list
        )
    }
}

/// Holds the focus binding the tvOS list needs, focused nowhere.
private struct ServerList: View {
    let servers: [DiscoveredServer]
    let isSearching: Bool
    #if os(tvOS)
    @FocusState private var focused: String?
    #endif

    var body: some View {
        #if os(tvOS)
        DiscoveredServersView(
            servers: servers, isSearching: isSearching, isConnecting: false,
            focusedServer: $focused, select: { _ in }, searchAgain: {}
        )
        #else
        DiscoveredServersView(
            servers: servers, isSearching: isSearching, isConnecting: false, select: { _ in }, searchAgain: {}
        )
        #endif
    }
}
