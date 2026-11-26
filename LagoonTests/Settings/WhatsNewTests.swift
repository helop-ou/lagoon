import Foundation
import Testing
@testable import Lagoon

@Suite("What's New")
struct WhatsNewTests {
    @Test func theSheetShowsTheRunningBuildOrTheNewest() throws {
        let entry = try #require(WhatsNew.entry)
        if Changelog.runningBuildIsListed() {
            #expect(Changelog.isRunning(entry))
        } else {
            #expect(entry == Changelog.entries.first)
        }
    }
}
