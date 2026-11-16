import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Home rows settings snapshots", .serialized)
@MainActor
struct HomeRowsSettingsSnapshotTests {
    /// The watched titles switch, on, above the first row. Only the top of
    /// the page: across the whole screen a renamed switch is within the
    /// tolerance.
    @Test func watchedTitlesSwitchAboveTheRows() async throws {
        let defaults = try #require(UserDefaults(suiteName: "home-rows-settings-snapshot"))
        defaults.removePersistentDomain(forName: "home-rows-settings-snapshot")
        let store = HomeSectionPreferencesStore(defaults: defaults)
        store.configure(accountID: "snapshot")
        store.setShowsWatched(true)
        try await Snapshot.verify(
            HomeRowsSettingsView(preferences: store),
            named: "home-rows-settings",
            size: Self.size,
            tolerance: Self.tolerance
        )
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 1920, height: 300)
        #else
        CGSize(width: 402, height: 170)
        #endif
    }

    /// The tvOS page is wide, so its share has to be smaller for one word.
    private static var tolerance: Double {
        #if os(tvOS)
        0.0005
        #else
        0.002
        #endif
    }
}
