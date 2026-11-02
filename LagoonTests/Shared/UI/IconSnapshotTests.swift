import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The glyphs a viewer sees most: the detail page's watched and favourite
/// toggles, and on iOS the Settings categories.
@Suite("Icon snapshots", .serialized)
@MainActor
struct IconSnapshotTests {
    private static let defaults = UserDefaults(suiteName: "icon-snapshot-tests")!

    private let session: SessionStore = {
        let session = SessionStore(
            defaults: defaults, credentials: MemoryAccountCredentials(), stores: .isolated(defaults: defaults)
        )
        session.client.configure(serverURL: URL(string: "https://jellyfin.snapshot.test")!)
        session.client.activateSession(token: "token", userId: "user")
        return session
    }()

    @Test func favouritesAreAHeart() async throws {
        let notFavorite = try item(favorite: false), favorite = try item(favorite: true)
        let rows = VStack(alignment: .leading, spacing: Metrics.Space.l) {
            ItemActionRow(item: notFavorite) { true }
            ItemActionRow(item: favorite) { true }
        }
        .padding(Metrics.screenGutter)
        .environment(session)

        try await Snapshot.verify(rows, named: "item-action-row", size: Self.actionRowSize)
    }

    #if os(iOS)
    @Test func everySettingsCategoryHasItsOwnGlyph() async throws {
        let seerr = SeerrSessionStore(
            defaults: Self.defaults,
            localData: AccountLocalData(defaults: Self.defaults, credentials: MemoryAccountCredentials())
        )
        try await Snapshot.verify(
            SettingsView()
                .themedControls()
                .environment(session)
                .environment(seerr),
            named: "settings-categories",
            size: CGSize(width: 402, height: 900),
            // One swapped glyph is about 0.1% of this page.
            tolerance: 0.0003
        )
    }
    #endif

    // MARK: - Fixtures

    private func item(favorite: Bool) throws -> MediaItem {
        try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"arrival","Name":"Arrival","Type":"Movie","UserData":{"Played":false,"IsFavorite":\#(favorite)}}"#.utf8)
        )
    }

    private static var actionRowSize: CGSize {
        #if os(tvOS)
        CGSize(width: 520, height: 320)
        #else
        CGSize(width: 260, height: 160)
        #endif
    }
}
