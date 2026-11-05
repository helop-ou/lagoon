import Foundation
import Testing
@testable import Lagoon

@Suite("What's New")
struct WhatsNewTests {
    @Test(arguments: [
        ("0.9.0", "0.8.1", true),
        ("1.0.0", "0.9.3", true),
        ("0.9.1", "0.9.0", false),
        ("0.9.0", "0.9.0", false),
        ("0.9", "0.9.0", false),
    ])
    func presentsOnlyWhenTheMinorOrMajorVersionChanges(running: String, lastSeen: String, presents: Bool) {
        #expect(WhatsNew.presents(running: running, lastSeen: lastSeen, isExistingInstall: true) == presents)
    }

    @Test func aFreshInstallStaysQuiet() {
        #expect(!WhatsNew.presents(running: "0.9.0", lastSeen: nil, isExistingInstall: false))
    }

    /// Builds before What's New recorded no version.
    @Test func anUnrecordedExistingInstallPresentsOnlyForAMinorOrMajorVersion() {
        #expect(WhatsNew.presents(running: "0.9.0", lastSeen: nil, isExistingInstall: true))
        #expect(!WhatsNew.presents(running: "0.8.2", lastSeen: nil, isExistingInstall: true))
    }

    @Test @MainActor func launchRecordsTheVersionSoItPresentsOnce() throws {
        let suite = "WhatsNewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("0.0.1", forKey: WhatsNew.lastSeenVersionKey)

        let first = WhatsNew.presentsAtLaunch(isExistingInstall: true, defaults: defaults)
        #expect(first == Changelog.runningBuildIsListed())
        #expect(defaults.string(forKey: WhatsNew.lastSeenVersionKey) == Changelog.version())
        #expect(!WhatsNew.presentsAtLaunch(isExistingInstall: true, defaults: defaults))
    }

    @Test func theSheetShowsTheRunningBuildOrTheNewest() throws {
        let entry = try #require(WhatsNew.entry)
        if Changelog.runningBuildIsListed() {
            #expect(Changelog.isRunning(entry))
        } else {
            #expect(entry == Changelog.entries.first)
        }
    }
}
