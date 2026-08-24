import Foundation

/// One shipped build.
///
/// Curated by hand rather than generated from the commit log: a changelog
/// answers what changed *for the viewer*, which 250 commits of `feat:` and
/// `fix:` do not. Build numbers are part of the identity because TestFlight
/// assigns them per upload, so one marketing version covers many builds.
nonisolated struct ChangelogEntry: Identifiable, Equatable, Sendable {
    let version: String
    let build: String
    /// A month, not a day. Builds reach TestFlight continuously and a precise
    /// date would imply a release cadence Lagoon does not have.
    let released: String
    let headline: String
    let changes: [String]

    var id: String { "\(version) (\(build))" }
    var displayVersion: String { "\(version) (\(build))" }
}

nonisolated enum Changelog {
    /// Newest first. Add an entry at the top when a build goes out; the About
    /// screen highlights whichever one matches the running bundle.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "0.1",
            build: "1",
            released: "August 2026",
            headline: "First TestFlight build.",
            // Written short on purpose: tvOS fixes the changelog panel's
            // width, so long sentences wrap every few words in it.
            changes: [
                "A playback engine of Lagoon's own, with no AVPlayer in the path.",
                "Direct play for H.264, HEVC, VC-1, MPEG-4 Part 2 and anamorphic sources.",
                "HDR10 and Dolby Vision, with tvOS display-mode matching.",
                "Dolby Digital, Atmos and TrueHD passthrough.",
                "PGS, VobSub and text subtitles, plus provider search.",
                "Trickplay scrubbing and intro skipping.",
                "Autoplay into the next episode without leaving the player.",
                "Direct-play files buffer ahead of the playhead.",
                "Home rails, genre discovery, search and Top Shelf.",
                "Seerr: browse, request and manage requests in-app.",
            ]
        ),
    ]

    static func version(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    static func build(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static func isRunning(_ entry: ChangelogEntry, bundle: Bundle = .main) -> Bool {
        entry.version == version(from: bundle) && entry.build == build(from: bundle)
    }

    /// TestFlight increments the build number at upload, so the running build
    /// routinely has no entry yet. Saying so is better than showing a list
    /// that quietly omits the build the viewer is actually on.
    static func runningBuildIsListed(bundle: Bundle = .main) -> Bool {
        entries.contains { isRunning($0, bundle: bundle) }
    }
}
