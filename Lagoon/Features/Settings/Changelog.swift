import Foundation

nonisolated enum ChangelogCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case newFeatures = "New features"
    case improvements = "Improvements"
    case bugFixes = "Bug fixes"

    var id: String { rawValue }
}

nonisolated struct ChangelogSection: Identifiable, Equatable, Sendable {
    let category: ChangelogCategory
    let changes: [String]

    var id: String { category.id }
}

/// One shipped build.
///
/// Curated by hand rather than generated from the commit log: a changelog
/// answers what changed *for the viewer*, which a few hundred `feat:` and
/// `fix:` subjects do not. Build numbers are part of the identity because one
/// marketing version spans many builds.
///
/// **See docs/release.md, "Version and changelog", before adding an entry.**
/// The short version: say what changed for someone watching, one line per
/// thing they would notice, and leave out everything invisible.
nonisolated struct ChangelogEntry: Identifiable, Equatable, Sendable {
    let version: String
    let build: String
    /// A month, not a day. Builds reach TestFlight continuously and a precise
    /// date would imply a release cadence Lagoon does not have.
    let released: String
    let headline: String
    let sections: [ChangelogSection]

    /// Flattened notes retained for release-hygiene checks and callers that
    /// need to inspect all viewer-visible changes in display order.
    var changes: [String] { sections.flatMap(\.changes) }

    var id: String { "\(version) (\(build))" }
    var displayVersion: String { "\(version) (\(build))" }
}

nonisolated enum Changelog {
    /// Notes merged since the last release, under `## Unreleased`. The
    /// release workflow's prepare action moves them into a new entry, so a
    /// pull request never bumps the build or edits a shipped entry.
    static var unreleased: [ChangelogSection] { document.unreleased }

    /// Newest first. What's New shows whichever one matches the running
    /// bundle.
    static var entries: [ChangelogEntry] { document.entries }

    private static let document = ChangelogDocument.bundled()

    static func version(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    static func build(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// "0.1 (13)"; the build is dropped when empty or equal to the version.
    /// Not `JellyfinClient.appVersion`, which goes in the auth header as-is.
    static func runningDisplayVersion(from bundle: Bundle = .main) -> String {
        let short = version(from: bundle)
        let number = build(from: bundle)
        return number.isEmpty || number == short ? short : "\(short) (\(number))"
    }

    /// The comparison takes plain strings so it can be exercised without
    /// standing up a bundle whose Info.plist says what a test needs.
    static func isRunning(_ entry: ChangelogEntry, version: String, build: String) -> Bool {
        entry.version == version && entry.build == build
    }

    static func isRunning(_ entry: ChangelogEntry, bundle: Bundle = .main) -> Bool {
        isRunning(entry, version: version(from: bundle), build: build(from: bundle))
    }

    /// A development build can lack notes until its release is prepared.
    /// Saying so is better than quietly omitting the installed build.
    static func isListed(version: String, build: String) -> Bool {
        entries.contains { isRunning($0, version: version, build: build) }
    }

    static func runningBuildIsListed(bundle: Bundle = .main) -> Bool {
        isListed(version: version(from: bundle), build: build(from: bundle))
    }
}

/// `CHANGELOG.md`, read as it is written: `## <version> (<build>)`, the
/// month, the bold headline, then `###` categories of `- ` notes.
/// `## Unreleased` holds categories alone.
nonisolated struct ChangelogDocument: Sendable {
    var unreleased: [ChangelogSection] = []
    var entries: [ChangelogEntry] = []
    /// `ChangelogTests` requires none, so a typo fails the suite instead of
    /// dropping a note.
    var unreadable: [String] = []

    static func bundled(_ bundle: Bundle = .main) -> ChangelogDocument {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return ChangelogDocument() }
        return parse(text)
    }

    static func parse(_ text: String) -> ChangelogDocument {
        var document = ChangelogDocument()
        var heading: String?
        var released = ""
        var headline = ""
        var sections: [ChangelogSection] = []
        var category: ChangelogCategory?
        var changes: [String] = []

        func closeSection() {
            if let category {
                sections.append(ChangelogSection(category: category, changes: changes))
            }
            category = nil
            changes = []
        }

        func closeEntry() {
            closeSection()
            defer { released = ""; headline = ""; sections = [] }
            guard let heading else { return }
            if heading == "Unreleased" {
                document.unreleased = sections
                document.unreadable += [released, headline].filter { !$0.isEmpty }
            } else if let match = heading.wholeMatch(of: /(\d+(?:\.\d+)*) \((\d+)\)/) {
                document.entries.append(ChangelogEntry(
                    version: String(match.1),
                    build: String(match.2),
                    released: released,
                    headline: headline,
                    sections: sections
                ))
            } else {
                document.unreadable.append("## \(heading)")
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("## ") {
                closeEntry()
                heading = String(line.dropFirst(3))
                continue
            }
            // The introduction above the first build, and blank lines.
            guard heading != nil, !line.isEmpty else { continue }

            if line.hasPrefix("### ") {
                closeSection()
                category = ChangelogCategory(rawValue: String(line.dropFirst(4)))
                if category == nil { document.unreadable.append(line) }
            } else if line.hasPrefix("- ") {
                if category == nil {
                    document.unreadable.append(line)
                } else {
                    changes.append(String(line.dropFirst(2)))
                }
            } else if category == nil, headline.isEmpty,
                      line.count > 4, line.hasPrefix("**"), line.hasSuffix("**") {
                headline = String(line.dropFirst(2).dropLast(2))
            } else if category == nil, headline.isEmpty, released.isEmpty {
                released = line
            } else {
                document.unreadable.append(line)
            }
        }
        closeEntry()
        return document
    }
}

/// What's New presents itself once after a minor or major update, never for
/// a patch, a fresh install or a build without notes.
nonisolated enum WhatsNew {
    static let lastSeenVersionKey = "whatsNew.lastSeenVersion"

    /// Builds before What's New recorded nothing, so an install with
    /// accounts but no record presents only on a minor or major version.
    static func presents(running: String, lastSeen: String?, isExistingInstall: Bool) -> Bool {
        let now = components(running)
        guard let lastSeen else { return isExistingInstall && now[2] == 0 }
        return now.prefix(2) != components(lastSeen).prefix(2)
    }

    /// Records the running version whatever it decides, so one version never
    /// presents twice.
    static func presentsAtLaunch(isExistingInstall: Bool, defaults: UserDefaults = .standard) -> Bool {
        let running = Changelog.version()
        let lastSeen = defaults.string(forKey: lastSeenVersionKey)
        defaults.set(running, forKey: lastSeenVersionKey)
        return Changelog.runningBuildIsListed()
            && presents(running: running, lastSeen: lastSeen, isExistingInstall: isExistingInstall)
    }

    /// The running build's notes, or the newest for a build that has none yet.
    static var entry: ChangelogEntry? {
        Changelog.entries.first { Changelog.isRunning($0) } ?? Changelog.entries.first
    }

    private static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return parts + Array(repeating: 0, count: max(0, 3 - parts.count))
    }
}
