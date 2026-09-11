import Foundation
import Testing
@testable import Lagoon

@Suite("Retired subtitle provider cleanup")
@MainActor
struct RetiredSubtitleProviderCleanupTests {
    @Test func storedProviderStateIsRemovedOnLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RetiredSubtitleProviderCleanupTests-\(UUID().uuidString)")
        let subtitlesDirectory = tempDirectory.appending(path: RetiredSubtitleProviderCleanup.cacheSubdirectory)
        try FileManager.default.createDirectory(at: subtitlesDirectory, withIntermediateDirectories: true)
        let sidecar = subtitlesDirectory.appending(path: "example.srt")
        try Data("1\n00:00:00,000 --> 00:00:01,000\nHi\n".utf8).write(to: sidecar)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        RetiredSubtitleProviderCleanup.run(defaults: fixture.defaults, credentials: fixture.credentials, cachesDirectory: tempDirectory)

        for key in RetiredSubtitleProviderCleanup.defaultsKeys {
            #expect(fixture.defaults.object(forKey: key) == nil)
        }
        #expect(fixture.credentials.string(for: RetiredSubtitleProviderCleanup.keychainAccount) == nil)
        #expect(!FileManager.default.fileExists(atPath: subtitlesDirectory.path))
    }

    @Test func constructingASessionStoreRunsTheCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        _ = fixture.store()

        for key in RetiredSubtitleProviderCleanup.defaultsKeys {
            #expect(fixture.defaults.object(forKey: key) == nil)
        }
        #expect(fixture.credentials.string(for: RetiredSubtitleProviderCleanup.keychainAccount) == nil)
    }

    private final class Fixture {
        let suite = "RetiredSubtitleProviderCleanupTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let credentials = MemoryAccountCredentials()

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            for key in RetiredSubtitleProviderCleanup.defaultsKeys {
                defaults.set("stale", forKey: key)
            }
            try credentials.set("stale-token", for: RetiredSubtitleProviderCleanup.keychainAccount)
        }

        func store() -> SessionStore {
            SessionStore(defaults: defaults, credentials: credentials)
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}
