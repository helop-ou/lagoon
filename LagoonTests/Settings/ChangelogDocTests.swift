import Foundation
import Testing
@testable import Lagoon

/// Renders `Changelog.entries` as the published `CHANGELOG.md`.
/// `Changelog.swift` is the source of truth, checked by `ChangelogTests`.
///
/// `scripts/generate-changelog.sh` runs this and copies the result into
/// `CHANGELOG.md`; `--check` fails on drift instead.
@Suite("Changelog document")
struct ChangelogDocTests {
    @Test func writesTheChangelogDocument() throws {
        let markdown = ChangelogDocument.render(Changelog.entries)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CHANGELOG.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        // The script reads this line rather than guessing the sandbox path.
        print("CHANGELOG_DOC \(url.path)")
    }

    /// Guards the renderer against silently dropping a build.
    @Test func everyBuildAndEveryNoteReachesTheDocument() {
        let markdown = ChangelogDocument.render(Changelog.entries)
        #expect(!Changelog.entries.isEmpty)
        for entry in Changelog.entries {
            #expect(markdown.contains("## \(entry.displayVersion)"),
                    "\(entry.id) missing from the generated changelog")
            #expect(markdown.contains(entry.headline),
                    "\(entry.id) headline missing from the generated changelog")
            for change in entry.changes {
                #expect(markdown.contains(change),
                        "A \(entry.id) note missing from the generated changelog")
            }
        }
    }

    /// `--notes` splits on heading depth alone.
    @Test func buildHeadingsAreTheOnlyLevelTwoHeadings() {
        let markdown = ChangelogDocument.render(Changelog.entries)
        let levelTwo = markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.hasPrefix("## ") }
        #expect(levelTwo.count == Changelog.entries.count)
    }

    @Test func notesForOneBuildCarryThatBuildAlone() throws {
        let newest = try #require(Changelog.entries.first)
        let notes = ChangelogDocument.section(newest)
        #expect(notes.contains(newest.headline))
        for change in newest.changes {
            #expect(notes.contains(change))
        }
        for other in Changelog.entries.dropFirst() {
            #expect(!notes.contains(other.headline))
        }
    }
}

/// Turns the curated entries into the Markdown published as `CHANGELOG.md`.
enum ChangelogDocument {
    static func render(_ entries: [ChangelogEntry]) -> String {
        entries.reduce(into: header()) { out, entry in out += section(entry) }
    }

    /// One build; `scripts/generate-changelog.sh --notes` lifts it out for a
    /// GitHub release.
    static func section(_ entry: ChangelogEntry) -> String {
        var out = "## \(entry.displayVersion)\n\n"
        out += "\(entry.released)\n\n"
        out += "**\(entry.headline)**\n\n"
        for section in entry.sections {
            out += "### \(section.category.rawValue)\n\n"
            for change in section.changes {
                out += "- \(change)\n"
            }
            out += "\n"
        }
        return out
    }

    private static func header() -> String {
        """
        # Changelog

        **Generated file. Do not edit.** Run `scripts/generate-changelog.sh`
        after changing
        [`Changelog.swift`](Lagoon/Features/Settings/Changelog.swift), which is
        the source of truth. This file, the About screen inside the app, and
        the notes on a GitHub release are all renderings of it.

        These notes are written for someone watching rather than someone
        reading the diff. They say what changed on screen and leave out
        refactors, tests and documentation, so a build that changed nothing a
        viewer would notice has no entry here. The commit log is the record of
        everything else.

        Builds are newest first. The number in brackets is the build, which is
        what identifies a binary: it is what About shows, what a release tag
        carries, and what to quote in a bug report. One marketing version spans
        many builds.


        """
    }
}
