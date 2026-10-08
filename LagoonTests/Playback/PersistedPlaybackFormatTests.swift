import Foundation
import Testing
@testable import Lagoon

/// What earlier builds wrote to `UserDefaults` must still load, and what this
/// build writes must still be readable by them. The keys and JSON are spelled
/// out literally on purpose.
@Suite("Persisted playback formats")
struct PersistedPlaybackFormatTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "persisted-format.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    @Test func aStoredAudioChoiceLoadsFromTheFrozenKeyAndShape() throws {
        try withDefaults { defaults in
            defaults.set(Data(#"""
            {"series-1":{"language":"eng","title":"Main","ordinal":3,"layout":"3:dts1:6","updatedAt":12.5}}
            """#.utf8), forKey: "playback.audioTrackMemory.account-1")

            let store = AudioTrackMemoryStore(defaults: defaults)
            store.configure(accountID: "account-1")
            #expect(store.choice(for: "series-1") == RememberedAudioChoice(
                language: "eng", title: "Main", ordinal: 3, layout: "3:dts1:6", updatedAt: 12.5
            ))
        }
    }

    @MainActor
    @Test func aStoredSubtitleChoiceLoadsFromTheFrozenKeyAndShape() throws {
        try withDefaults { defaults in
            defaults.set(Data(#"""
            {"series-1":{"isOff":false,"language":"fra","ordinal":2,"layout":"3:fra","updatedAt":7},
             "film-1":{"isOff":true,"ordinal":0,"layout":"","updatedAt":8}}
            """#.utf8), forKey: "playback.subtitleTrackMemory.account-1")

            let store = SubtitleTrackMemoryStore(defaults: defaults)
            store.configure(accountID: "account-1")
            #expect(store.choice(for: "series-1") == RememberedSubtitleChoice(
                language: "fra", ordinal: 2, layout: "3:fra", updatedAt: 7
            ))
            #expect(store.choice(for: "film-1") == RememberedSubtitleChoice(
                isOff: true, ordinal: 0, layout: "", updatedAt: 8
            ))
        }
    }

    @MainActor
    @Test func aRememberedChoiceIsWrittenUnderTheFrozenKeyWithPlainFields() throws {
        try withDefaults { defaults in
            let store = AudioTrackMemoryStore(defaults: defaults)
            store.configure(accountID: "account-1")
            store.remember(
                RememberedAudioChoice(language: "eng", title: nil, ordinal: 4, layout: "x", updatedAt: 9),
                for: "series-1"
            )

            let data = try #require(defaults.data(forKey: "playback.audioTrackMemory.account-1"))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
            let entry = try #require(root["series-1"])
            #expect(entry["language"] as? String == "eng")
            #expect(entry["ordinal"] as? Int == 4)
            #expect(entry["layout"] as? String == "x")
            #expect(entry["updatedAt"] as? Double == 9)
        }
    }

    @MainActor
    @Test func storedTrackPreferencesLoadFromTheFrozenKeyAndShape() throws {
        try withDefaults { defaults in
            defaults.set(Data(#"""
            {"audioMode":"original","audioLanguageOverrides":["et","en"],"subtitleMode":"forcedOnly"}
            """#.utf8), forKey: "playback.trackPreferences.account-1")

            let store = TrackPreferencesStore(defaults: defaults)
            store.configure(accountID: "account-1")
            #expect(store.values == TrackPreferenceValues(
                audioMode: .original,
                audioLanguageOverrides: ["et", "en"],
                subtitleMode: .forcedOnly
            ))
        }
    }

    @MainActor
    @Test func trackPreferencesAreWrittenUnderTheFrozenKeyWithRawValues() throws {
        try withDefaults { defaults in
            let store = TrackPreferencesStore(defaults: defaults)
            store.configure(accountID: "account-1")
            store.values.audioMode = .preferredLanguage
            store.values.subtitleMode = .always

            let data = try #require(defaults.data(forKey: "playback.trackPreferences.account-1"))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(root["audioMode"] as? String == "preferredLanguage")
            #expect(root["subtitleMode"] as? String == "always")
        }
    }

    @MainActor
    @Test func storedSubtitlePreferencesLoadFromTheFrozenKeyAndShape() throws {
        try withDefaults { defaults in
            defaults.set(Data(#"""
            {"followsSystemAppearance":false,"textSize":"extraLarge","edgeStyle":"outline",
             "background":"dark","verticalPosition":"high","languageOverrides":["et"],
             "missingMode":"automaticSearch"}
            """#.utf8), forKey: "subtitles.preferences.account-1")

            let store = SubtitlePreferencesStore(defaults: defaults)
            store.configure(accountID: "account-1")
            #expect(store.values == SubtitlePreferenceValues(
                followsSystemAppearance: false,
                textSize: .extraLarge,
                edgeStyle: .outline,
                background: .dark,
                verticalPosition: .high,
                languageOverrides: ["et"],
                missingMode: .automaticSearch
            ))
        }
    }

    @MainActor
    @Test func subtitlePreferencesAreWrittenUnderTheFrozenKeyWithRawValues() throws {
        try withDefaults { defaults in
            let store = SubtitlePreferencesStore(defaults: defaults)
            store.configure(accountID: "account-1")
            store.values.textSize = .large
            store.values.missingMode = .off

            let data = try #require(defaults.data(forKey: "subtitles.preferences.account-1"))
            let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(root["textSize"] as? String == "large")
            #expect(root["missingMode"] as? String == "off")
        }
    }
}
