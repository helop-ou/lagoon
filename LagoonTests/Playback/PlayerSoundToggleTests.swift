import Foundation
import LagoonEngine
import Testing
@testable import Lagoon

/// Night Mode and Dialogue Boost switched from the player.
@Suite("Player sound toggles")
@MainActor
struct PlayerSoundToggleTests {
    /// With nothing playing there is no engine to shape, and the choice
    /// still holds for the next title and the next launch.
    @Test func aToggleFromThePlayerIsKeptInTheViewersPreferences() throws {
        let suite = "player-sound-toggle-tests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TrackPreferencesStore(defaults: defaults)
        store.configure(accountID: "account-1")
        let controller = PlaybackController()
        controller.trackPreferencesStore = store

        controller.adjustments.setNightMode(true)
        #expect(controller.audioShaping == AudioShaping(nightMode: true))
        #expect(store.values.nightMode)
        #expect(!store.values.dialogueBoost)

        controller.adjustments.setDialogueBoost(true)
        controller.adjustments.setNightMode(false)
        #expect(controller.audioShaping == AudioShaping(dialogueBoost: true))

        let reopened = TrackPreferencesStore(defaults: defaults)
        reopened.configure(accountID: "account-1")
        #expect(!reopened.values.nightMode)
        #expect(reopened.values.dialogueBoost)
    }
}
