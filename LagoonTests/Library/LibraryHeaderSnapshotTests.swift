#if os(iOS)
import SwiftUI
import Testing
@testable import Lagoon

/// The entries and controls above the Library's grid. On an iPad they once
/// ran edge to edge, as the phone's do.
@Suite("Library header snapshots", .serialized)
@MainActor
struct LibraryHeaderSnapshotTests {
    @Test func anIPadPutsTheEntriesSideBySideAndTheControlsInOneRow() async throws {
        try await Snapshot.verify(
            header(.regular, .regular),
            named: "header-ipad",
            size: CGSize(width: 1376, height: 260)
        )
    }

    @Test func anOpenDuoFitsTheSameRows() async throws {
        try await Snapshot.verify(
            header(.regular, .regular),
            named: "header-duo-open",
            size: CGSize(width: 669, height: 260)
        )
    }

    @Test func aPhoneStacksThemAtFullWidth() async throws {
        try await Snapshot.verify(
            header(.compact, .regular),
            named: "header-phone",
            size: CGSize(width: 402, height: 400)
        )
    }

    private func header(_ horizontal: UserInterfaceSizeClass, _ vertical: UserInterfaceSizeClass) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
            LibraryEntryStack {
                LibraryEntryLink(
                    route: .downloads,
                    title: "Downloads",
                    subtitle: "2 titles · 64.2 MB",
                    systemImage: "arrow.down.circle.fill"
                )
                LibraryEntryLink(
                    route: .playlists,
                    title: "Playlists",
                    subtitle: "1 playlist",
                    systemImage: "list.and.film"
                )
            }
            LibraryControlsLayout {
                Picker("Media Type", selection: .constant(0)) {
                    Text("All").tag(0)
                    Text("Movies").tag(1)
                    Text("Shows").tag(2)
                }
                .pickerStyle(.segmented)
            } actions: {
                Button {} label: { Label("Title", systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(.glass)
                Button {} label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                    .buttonStyle(.glass)
            }
        }
        .padding(Metrics.screenGutter)
        .environment(\.horizontalSizeClass, horizontal)
        .environment(\.verticalSizeClass, vertical)
    }
}
#endif
