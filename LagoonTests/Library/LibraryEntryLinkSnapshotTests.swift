#if os(iOS)
import SwiftUI
import Testing
@testable import Lagoon

@Suite("Library entry snapshots", .serialized)
@MainActor
struct LibraryEntryLinkSnapshotTests {
    @Test func theTitleKeepsWholeWordsAtTheLargestTextSize() async throws {
        try await Snapshot.verify(
            LibraryEntryLink(
                route: .playlists,
                title: "Playlists",
                subtitle: "1 playlist",
                systemImage: "list.and.film"
            )
            .padding(Metrics.screenGutter)
            .environment(\.dynamicTypeSize, .accessibility5),
            named: "playlists-accessibility-size",
            size: CGSize(width: 402, height: 260)
        )
    }
}
#endif
