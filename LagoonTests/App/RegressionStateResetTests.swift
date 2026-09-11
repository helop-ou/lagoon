import Foundation
import Testing
@testable import Lagoon

/// The regression lane's clean slate (HEL-144, audit A18): scoped to what a
/// previous run could leak into the next, and nothing else.
@Suite("Regression state reset")
struct RegressionStateResetTests {
    private func freshDefaults() throws -> UserDefaults {
        let suite = "ee.helop.lagoon.tests.reset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func removesAccountAndServerScopedRecordsAndKeepsAppSettings() throws {
        let defaults = try freshDefaults()
        let scoped = [
            "accounts", "accounts.pendingCredentialRemoval", "session.activeAccountId",
            "session.expiredAccountIds", "server.url", "server.name",
            "libraries.acct", "library.selection.acct", "subtitles.preferences.acct",
            "playback.trackPreferences.acct", "home.sectionPreferences.acct",
            "search.recents", "search.recents.acct",
            "seerr.server.https://jellyfin.example", "seerr.pendingCookieRemoval",
        ]
        let appWide = ["playback.skipMode", "playback.autoplayMode", "subtitles.captionStyle", "debug.frameLossBench"]
        for key in scoped + appWide { defaults.set("value", forKey: key) }

        let credentials = MemoryAccountCredentials()
        try credentials.set("device", for: "deviceId")
        try credentials.set("tok", for: "token:acct")
        try credentials.set("cookie", for: "seerr.cookie:acct|https://seerr.example")
        try credentials.set("legacy", for: "accessToken")

        let removed = RegressionStateReset.run(defaults: defaults, credentials: credentials)

        #expect(Set(removed.defaultsKeys) == Set(scoped))
        for key in scoped { #expect(defaults.object(forKey: key) == nil, "\(key) should be gone") }
        for key in appWide { #expect(defaults.string(forKey: key) == "value", "\(key) should survive") }
        #expect(Set(removed.credentialNames) == ["token:acct", "seerr.cookie:acct|https://seerr.example", "accessToken"])
        #expect(credentials.string(for: "deviceId") == "device")
        #expect(credentials.string(for: "token:acct") == nil)
    }

    @Test func runsOnlyWhenBothLaneFlagsAreSet() throws {
        let arguments = try freshDefaults()
        #expect(!RegressionStateReset.isRequested(arguments: arguments))
        arguments.set(true, forKey: "debug.regressionResetState")
        #expect(!RegressionStateReset.isRequested(arguments: arguments), "the reset alone must not fire")
        arguments.set(true, forKey: "debug.regressionBootstrapPublicDemo")
        #expect(RegressionStateReset.isRequested(arguments: arguments))
    }

    @Test func aCleanStoreRemovesNothing() throws {
        let removed = RegressionStateReset.run(defaults: try freshDefaults(), credentials: MemoryAccountCredentials())
        #expect(removed == RegressionStateReset.Removed(defaultsKeys: [], credentialNames: []))
    }
}
