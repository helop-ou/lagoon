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
            build: "57",
            released: "August 2026",
            headline: "The Top Shelf works.",
            changes: [
                "Put Lagoon in the top row of the Apple TV Home screen and what you were watching now fills the screen above it, one title at a time, with its own artwork, a summary and how long is left.",
                "Play picks up where you stopped. More Info opens the title in Lagoon instead, which is what the second button is for.",
                "The artwork is composed at the size a 4K television actually asks for, rather than a smaller image stretched to fit.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "56",
            released: "August 2026",
            headline: "Search moves out, and Discover fills the screen.",
            changes: [
                "Search has a tab of its own. Discover used to open behind a full keyboard that took the top third of the screen, and now opens on artwork instead.",
                "The Search screen remembers what you looked for, so searching for it again is one click rather than spelling it out on the keyboard a second time.",
                "Discover opens on a hero banner and carries eight rows where it had four, including Upcoming Shows, your watchlist, and browsable movie and show genres. The rows follow the order your Seerr administrator arranged on their own Discover page, and each one opens a full list.",
                "Requests that are finished no longer claim to be pending. A request now says whether it is waiting for approval, downloading, importing, or ready to watch, and a title that was removed from your library says that rather than looking stuck.",
                "A request that is downloading shows how far along it is and how long is left, and the icon animates while you are looking at it.",
                "A request whose title has arrived opens straight into Lagoon to play it, instead of only offering to remove itself.",
                "A request now shows the quality it will be fetched at, so approving one tells you what you are agreeing to.",
                "If you manage your Seerr blocklist, a blocked title can be unblocked from Lagoon rather than only from the web interface.",
                "Settings takes the app's own black background instead of the system's default grey.",
                "This changelog is now a row per build that you open, rather than one long list to scroll.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "55",
            released: "August 2026",
            headline: "Play at your own speed.",
            changes: [
                "Playback speed, from half to double, in the Video tab of the playback panel. Voices keep their pitch, and the speed you pick carries into the next episode.",
                "Lagoon has a new look: a new app icon and Top Shelf artwork, and the mark now carries through the setup and sign-in screens instead of stopping at the home screen.",
                "Subtitles authored with a place on screen now appear where they were meant to, in their own colour, bold and italic, instead of being stacked at the bottom. That covers signs, captions over artwork, and two people talking at once.",
                "10-bit AV1 and VP9 now play directly instead of being re-encoded by your server, up to 1080p on hardware with no AV1 decoder of its own.",
                "MPEG-2 video, LPCM soundtracks and DVB subtitles play directly too, which covers most DVD rips and recorded television. Interlaced recordings still go through your server, because that is what deinterlaces them.",
                "Stereo soundtracks now get Spatial Audio on AirPods, the way Apple's own player does.",
                "Starting another film after one failed no longer waits fifteen seconds to announce that the previous video could not release its player resources.",
                "A film that fails also stops leaving your server working on a stream nobody is watching.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "54",
            released: "August 2026",
            headline: "Playback recovers instead of giving up.",
            changes: [
                "A film that won't play no longer ends at an error screen: Lagoon asks your server to send it another way and picks up where it stopped, without making the server re-encode unless nothing else works.",
                "If the sound stops partway through a film, Lagoon rebuilds the audio and keeps playing rather than running on in silence.",
                "Pausing near the start of a film now buffers as far ahead as the cache allows, instead of stopping short of it.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "53",
            released: "August 2026",
            headline: "Subtitle errors say what the server said.",
            changes: [
                "When a subtitle download fails, Lagoon now shows the reason your server gave, such as an exhausted provider allowance, instead of guessing between causes.",
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
                "If your Seerr uses Jellyfin accounts, Discover now just works. There is no second login to type, since you are already signed in to Jellyfin.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "50",
            released: "August 2026",
            headline: "Playback, subtitles and requests.",
            changes: [
                "A long film no longer starts stuttering partway through: the disk buffer now travels with the playhead instead of filling up and giving out.",
                "Subtitle failures say what actually went wrong, whether that is a missing server permission, an expired session or a timeout, rather than always blaming the provider.",
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
                "A playback engine of Lagoon's own: libavformat demuxing straight into AVSampleBufferDisplayLayer, with no AVPlayer in the path.",
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
