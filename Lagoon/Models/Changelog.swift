import Foundation

/// One shipped build.
///
/// Curated by hand rather than generated from the commit log: a changelog
/// answers what changed *for the viewer*, which a few hundred `feat:` and
/// `fix:` subjects do not. Build numbers are part of the identity because one
/// marketing version spans many builds.
///
/// **See docs/release.md, "How to write the notes", before adding an entry.**
/// The short version: say what changed for someone watching, one line per
/// thing they would notice, and leave out everything invisible.
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
            build: "53",
            released: "August 2026",
            headline: "Subtitle errors say what the server said.",
            changes: [
                "When a subtitle download fails, Lagoon now shows the reason your server gave — an exhausted provider allowance, say — instead of guessing between causes.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "52",
            released: "August 2026",
            headline: "Subtitle search works for server administrators again.",
            changes: [
                "If you administer your Jellyfin server, Lagoon no longer refuses to search for subtitles before it has even asked the server.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "51",
            released: "August 2026",
            headline: "Seerr signs itself in.",
            changes: [
                "If your Seerr uses Jellyfin accounts, Discover now just works — no second login to type, since you are already signed in to Jellyfin.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "50",
            released: "August 2026",
            headline: "Playback, subtitles and requests.",
            changes: [
                "A long film no longer starts stuttering partway through: the disk buffer now travels with the playhead instead of filling up and giving out.",
                "Subtitle failures say what actually went wrong — a missing server permission, an expired session or a timeout — rather than always blaming the provider.",
                "Subtitles can be fetched straight from OpenSubtitles when your Jellyfin account isn't allowed to manage them. Add a key in Settings -> Subtitles.",
                "Subtitles that aren't UTF-8 now decode by language instead of rendering as garbage.",
                "Seerr requests are a poster grid, and opening one gives a proper page with the actions that apply to it.",
                "This About screen, with a changelog.",
                "Build numbers now come from the project rather than being assigned at upload, so builds between 1 and 50 predate this list and aren't itemised.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "1",
            released: "August 2026",
            headline: "First TestFlight build.",
            changes: [
                "A playback engine of Lagoon's own — libavformat demuxing straight into AVSampleBufferDisplayLayer, with no AVPlayer in the path.",
                "Direct play for H.264, HEVC, VC-1, MPEG-4 Part 2 and anamorphic sources, so far fewer titles fall back to transcoding.",
                "HDR10 and Dolby Vision with tvOS display-mode matching, plus Dolby Digital, Atmos and TrueHD passthrough.",
                "Embedded PGS, VobSub and text subtitles, external sidecars, and provider search when a title has none.",
                "Trickplay scrubbing, intro and recap skipping, and autoplay into the next episode without leaving the player.",
                "Direct-play files buffer ahead of the playhead over HTTP range requests.",
                "Home rails, genre discovery, library browsing, search and a Top Shelf extension.",
                "Seerr: browse, request and manage requests from inside the app.",
            ]
        ),
    ]

    static func version(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    static func build(from bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// The comparison takes plain strings so it can be exercised without
    /// standing up a bundle whose Info.plist says what a test needs.
    static func isRunning(_ entry: ChangelogEntry, version: String, build: String) -> Bool {
        entry.version == version && entry.build == build
    }

    static func isRunning(_ entry: ChangelogEntry, bundle: Bundle = .main) -> Bool {
        isRunning(entry, version: version(from: bundle), build: build(from: bundle))
    }

    /// TestFlight increments the build number at upload, so the running build
    /// routinely has no entry yet. Saying so is better than showing a list
    /// that quietly omits the build the viewer is actually on.
    static func isListed(version: String, build: String) -> Bool {
        entries.contains { isRunning($0, version: version, build: build) }
    }

    static func runningBuildIsListed(bundle: Bundle = .main) -> Bool {
        isListed(version: version(from: bundle), build: build(from: bundle))
    }
}
