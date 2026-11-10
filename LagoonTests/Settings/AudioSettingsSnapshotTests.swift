import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Audio settings snapshots", .serialized)
@MainActor
struct AudioSettingsSnapshotTests {
    @Test func languageAndChannelLimit() async throws {
        let defaults = try #require(UserDefaults(suiteName: "audio-settings-snapshot"))
        defaults.removePersistentDomain(forName: "audio-settings-snapshot")
        let store = TrackPreferencesStore(defaults: defaults)
        // Explicit, so the device's own language list cannot change the
        // picture.
        store.values.audioLanguageOverrides = ["en", "de"]
        store.values.channelLimit = .stereo
        try await Snapshot.verify(
            AudioSettingsView(trackPreferences: store),
            named: "audio-settings",
            size: Self.size
        )
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 1920, height: 1080)
        #else
        CGSize(width: 402, height: 874)
        #endif
    }
}
