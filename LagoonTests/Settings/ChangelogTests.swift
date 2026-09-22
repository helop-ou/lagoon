import Foundation
import Testing
@testable import Lagoon

@Suite("Changelog")
struct ChangelogTests {
    /// `Bundle.main` is Lagoon.app here, so no build ships without notes.
    /// Only a real gate while Xcode never manages the build number at upload
    /// (docs/release.md).
    @Test @MainActor func theBuildThisProjectDeclaresHasChangelogNotes() {
        let version = Changelog.version()
        let build = Changelog.build()
        #expect(
            Changelog.runningBuildIsListed(),
            """
            No Changelog entry for \(version) (\(build)).
            Add one at the top of Changelog.entries in \
            Lagoon/Features/Settings/Changelog.swift before shipping this build.
            """
        )
    }

    /// House style; see docs/release.md.
    @Test @MainActor func notesAvoidEmDashes() {
        let emDash = "\u{2014}"
        for entry in Changelog.entries {
            #expect(
                !entry.headline.contains(emDash),
                "Em-dash in the \(entry.displayVersion) headline: \(entry.headline)"
            )
            for change in entry.changes {
                let note = "Em-dash in a \(entry.displayVersion) note; use a comma, "
                    + "a colon or a full stop instead: \(change)"
                #expect(!change.contains(emDash), Comment(rawValue: note))
            }
        }
    }

    @Test func anEntryIsIdentifiedByVersionAndBuildTogether() {
        // One marketing version spans many builds.
        let first = ChangelogEntry(
            version: "1.0", build: "1", released: "January 2027",
            headline: "First.",
            sections: [ChangelogSection(category: .newFeatures, changes: ["Something."])]
        )
        let second = ChangelogEntry(
            version: "1.0", build: "2", released: "January 2027",
            headline: "Second.",
            sections: [ChangelogSection(category: .improvements, changes: ["Something else."])]
        )
        #expect(first.id != second.id)
        #expect(first.displayVersion == "1.0 (1)")
    }

    @Test func entriesAreWellFormedAndUnique() {
        #expect(!Changelog.entries.isEmpty)

        let identifiers = Changelog.entries.map(\.id)
        #expect(Set(identifiers).count == identifiers.count, "Duplicate changelog entry")

        for entry in Changelog.entries {
            #expect(!entry.version.isEmpty)
            #expect(!entry.build.isEmpty)
            #expect(!entry.released.isEmpty)
            #expect(!entry.headline.isEmpty)
            // An empty entry claims a build is documented when it is not.
            #expect(!entry.changes.isEmpty, "\(entry.id) has no notes")
            #expect(entry.changes.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            #expect(!entry.sections.isEmpty, "\(entry.id) has no sections")
            #expect(Set(entry.sections.map(\.category)).count == entry.sections.count,
                    "\(entry.id) repeats a changelog category")
        }
    }

    @Test func everyBuildUsesNonemptySectionsInTheSameOrder() {
        for entry in Changelog.entries {
            let categories = entry.sections.map(\.category)
            let expectedOrder = ChangelogCategory.allCases.filter { categories.contains($0) }
            #expect(categories == expectedOrder, "\(entry.id) puts categories out of order")
            for section in entry.sections {
                #expect(!section.changes.isEmpty,
                        "\(entry.id) has an empty \(section.category.rawValue) section")
            }
        }
    }

    @Test func aBuildWithNoEntryIsReportedRatherThanHidden() throws {
        // The panel and the About row both admit an unlisted build.
        let firstEntry: ChangelogEntry? = Changelog.entries.first
        let known = try #require(firstEntry)
        #expect(Changelog.isListed(version: known.version, build: known.build))

        // A build uploaded but not yet documented.
        #expect(!Changelog.isListed(version: known.version, build: "999999"))
        // And a marketing version alone is not enough to count as listed.
        #expect(!Changelog.isListed(version: "99.0", build: known.build))
    }
}
