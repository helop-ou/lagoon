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
            build: "74",
            released: "September 2026",
            headline: "The AV1 decoder was not using the chip's video instructions. Now it is.",
            changes: [
                "4K AV1 played on an Apple TV with no AV1 chip of its own, but at under half the frame rate it needed. The cause turned out to be the decoder Lagoon ships rather than anything about how Lagoon used it: the prebuilt copy everyone in this corner of the world uses was compiled without the hand-written routines Apple chips provide for video decoding, so every frame took the slow, general path. Lagoon builds its own copy now, with those routines kept.",
                "This makes AV1 several times cheaper to decode on every device, and it applies to an iPhone and iPad as much as to an Apple TV.",
                "Nothing about picture quality changes. It is the same decoder and the same version, doing the same work by a faster route.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "73",
            released: "September 2026",
            headline: "Video Lagoon decodes itself is read and decoded at the same time, not in turns.",
            changes: [
                "4K AV1 played on an Apple TV with no AV1 chip of its own, but it did not hold a steady frame rate. Lagoon was reading the file and decoding it one after the other on the same thread, so it stopped reading for as long as each frame took to decode, and nothing was waiting for the picture when the time came to show it. Those two now happen at the same time.",
                "This applies to everything Lagoon decodes itself: AV1 where the device has no hardware for it, VP9, VC-1, MPEG-2 and older MPEG-4. Formats your device decodes in hardware, which is most of them, take a different path and are unchanged.",
                "A 4K film decoded this way could hold about a gigabyte of finished frames in memory at once, which is more than the system will let an app keep. It is now held to the same ceiling everything else uses.",
                "Playback details, in Settings then Advanced, now separate decoding from converting from reading the file, so a stutter can be attributed rather than guessed at.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "72",
            released: "September 2026",
            headline: "Video Lagoon decodes itself now uses the whole device, not one core.",
            changes: [
                "4K AV1 plays on the device now, on hardware with no AV1 chip of its own. Lagoon used to hand those files to your server to convert, which is slow to start and can time out before anything appears. It decodes them itself instead.",
                "That became possible because of the second half of this build: anything Lagoon decodes in software was running on a single processor core, because of a default nobody had noticed. Decoding a 4K AV1 episode measured eight times faster with the rest of the cores put to work. The same applies to VC-1, MPEG-2, VP9 and older MPEG-4 files.",
                "Formats your device decodes in hardware, which is most of them, were never affected and are unchanged.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "71",
            released: "September 2026",
            headline: "A film from a disc starts at the beginning, and the scrubber works.",
            changes: [
                "Playing a Blu-ray or DVD image opened as though an hour of it had already gone by, and the progress bar could not be dragged anywhere useful. A disc counts time from wherever its own clock happens to start, which for one disc here was 70 minutes in. Lagoon counts from the start of the film now, like it does for everything else.",
                "The same applies to any recording whose timestamps do not start at zero, which is common for anything captured off the air.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "70",
            released: "September 2026",
            headline: "Disc images play from the disc, Blu-ray and DVD alike.",
            changes: [
                "Blu-ray images did not actually play in the last build. Lagoon read the disc correctly and then stopped at the final step with a decoder error, because a Blu-ray describes its video in a way nothing else Lagoon plays uses. It plays now, with the soundtrack the disc was mastered with rather than a converted one.",
                "DVD images play from the disc as well, instead of being rebuilt by your server. Lagoon picks the main title set and plays it.",
                "Interlaced video no longer has to go to your server to be made watchable. Lagoon can now deinterlace MPEG-2 itself, which is what DVDs and most older recordings are. A still shot keeps its full detail, and movement is interpolated rather than left with the comb-toothed edges interlacing leaves behind.",
                "This covers a disc stored as one image file. A disc kept as a folder of files still plays through your server, because Jellyfin gives an app no way to reach inside one, and interlaced video in other formats still goes to the server too.",
                "A DVD that keeps several episodes in one title will play them one after another. Choosing a single episode off a disc like that is not there yet.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "69",
            released: "September 2026",
            headline: "A film kept as a Blu-ray disc image now plays straight from the disc.",
            changes: [
                "A film your server stores as a Blu-ray disc image had to be rebuilt by the server before it could play, and that rebuild flattened a Dolby TrueHD or Atmos soundtrack down to Dolby Digital. Lagoon now reads the disc itself and plays the main feature as it was mastered, with the soundtrack it came with.",
                "Choosing the feature off a disc is not as obvious as it sounds: a Blu-ray can carry sixty or more playlists, and the longest one is often a menu loop rather than the film. Lagoon picks using the running time your server already knows.",
                "If a disc turns out to be one Lagoon cannot read, playback goes through your server exactly as it did before, so nothing that used to play stops playing.",
                "This covers Blu-ray images. A DVD image, or a disc kept as a folder of files rather than as one image, still plays through your server, and now goes there directly rather than trying and failing first, so it starts sooner.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "68",
            released: "August 2026",
            headline: "On an iPhone or iPad, cellular no longer means downloading the whole film.",
            changes: [
                "On a cellular connection or a personal hotspot, Lagoon used to ask your server for the original file. For a 4K film that can be tens of gigabytes, so it started slowly, looked no better for it, and spent a data allowance in minutes. It now asks for a smaller version instead.",
                "If the connection is one you know is fast and unmetered, Settings has a new Full Quality on Cellular switch. Your device can tell Lagoon that a connection is metered but never that it is slow, so this one is your call rather than a guess.",
                "Nothing changes on Apple TV, or on Wi-Fi anywhere. This applies only where the connection itself is metered.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "67",
            released: "August 2026",
            headline: "Undoes the constant buffering the last build introduced on anything with sound.",
            changes: [
                "Films with sound stopped and buffered every few seconds in 0.1 (66). That was a mistake in the last build and it is undone here. Lagoon had started watching how much sound was waiting in its own queue and treating a low reading as the sound having run out, when a low reading there is simply what a healthy film looks like: the sound has already been handed on to the part of the system that plays it, so very little is ever waiting.",
                "Lagoon still notices and records when that queue empties, and Playback Details shows it, because the original problem it was meant to catch is real. It just no longer stops a film over it.",
                "Everything else from the last build stands, including 4K films that previously refused to start.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "66",
            released: "August 2026",
            headline: "Some 4K films now start instead of being handed to your server, and a film that loses its sound says so.",
            changes: [
                "A film can now start even when its file does not describe its own video properly. Some 4K releases leave that description out of the file and repeat it inside the picture data instead, which is allowed, and Lagoon was reading only the first place. It could not set up a decoder, so it fell back on asking your server to convert the film, which is slow and looks worse than the file you already own. Lagoon now reads the second place too.",
                "Nothing about this was visible while it happened. Every other tool reads that information from inside the picture data, so the file looked perfectly healthy on your server and in any other player, and the failure looked like your Apple TV refusing the film rather than the file being described oddly.",
                "If a title has been converting for no obvious reason, it is worth another try.",
                "When the sound runs out because the film is not reaching your Apple TV fast enough, Lagoon now shows that it is buffering instead of carrying on with the picture and no sound. Nothing reported this before. The picture kept moving, every reading in Playback Details looked normal, and the only sign anything was wrong was the silence itself.",
                "Lagoon also holds more sound in reserve now when your server is converting a film. Converted films had no reserve at all, so any stumble in delivery reached you immediately as silence, while the picture carried on from what it had already been given. There is more to come here, and the Buffer Transcoded Playback switch in Settings, Playback Diagnostics is still worth trying on a title that misbehaves.",
                "That is honesty rather than a cure. A film whose sound keeps running out is still a film arriving too slowly, and there is more to do there, but it now tells you instead of hiding it.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "65",
            released: "August 2026",
            headline: "A film your server has to convert now keeps playing instead of stalling every few seconds.",
            changes: [
                "When Lagoon cannot play a file as it is and falls back on your server converting it, it now asks for that conversion at 1080p instead of at the film's full 4K. A server without dedicated video hardware manages roughly a third of the speed needed to keep up with 4K, which is why the fallback played for a second, stopped to buffer, played again and stuck. The same server produces 1080p comfortably faster than it needs to.",
                "This only happens after Lagoon has already failed to play a file directly, which is rare. A title that plays normally is untouched, at 4K or otherwise, and nothing about direct playback changed.",
                "Playback Details now names the delivery Lagoon settled on and what failed to make it settle there. Lagoon retries a broken film a different way and usually succeeds, which is the behaviour you want, but until now the reason it had to was thrown away the moment the retry worked. On an Apple TV there was then no way to find out what went wrong.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "64",
            released: "August 2026",
            headline: "Two new switches for chasing down a title that stutters or loses its sound.",
            changes: [
                "Settings, Playback Diagnostics has a new Buffer Transcoded Playback switch. When your server has to convert a film rather than send it as it is, Lagoon currently holds nothing back in reserve, so a slow moment on the network or the server reaches you as sound cutting out. Turning this on keeps a reserve. It is off by default and worth trying only on a title that misbehaves, because whether it helps is exactly what we are trying to find out.",
                "Playback Details now shows how many seconds of sound are waiting, not just how many pieces. A count near zero could mean either a starved film or a perfectly healthy one, which made the number useless for telling those apart.",
                "Nothing here changes how a film plays unless you turn one of these on.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "63",
            released: "August 2026",
            headline: "Control Center stops blanking the picture, and more of your files play untouched.",
            changes: [
                "Opening Control Center in the middle of a film no longer blanks the television while it changes picture modes, once on the way in and again on the way out. Lagoon was handing the display back the moment anything appeared over playback, even though the film had not stopped. It now holds the mode until you actually leave.",
                "Recent searches keep the title you looked for instead of every step on the way to it. Typing on a television happens one letter at a time and each letter ran a search of its own, so looking for Dune left d, du and dun in the row beside it. Searching for something again also clears up what earlier builds left behind.",
                "Films with WMV3 video, or MP2 or Apple Lossless sound, now play as they are rather than being converted by your server first. Lagoon could always decode all three and simply never said so. MP2 is what DVD rips and recorded broadcasts usually carry, so those stop being converted for no reason.",
                "Plain .wmv files are still converted. What changed is WMV3 video inside an mkv or an avi.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "62",
            released: "August 2026",
            headline: "Collections, and the new Home rows open the title you picked.",
            changes: [
                "Picking something out of one of the new Home rows opens it, rather than starting to play it there and then. The rows made of series behaved worse still: they answered a press with an error from your server, because a series is not a thing that can be played.",
                "Home has a Collections row, and a collection opens a page of everything in it, in the order the films came out.",
                "Search finds collections as well as titles, so typing a franchise name reaches the franchise.",
                "Collections holding nothing, or holding one title, are left out of both. A server invents a collection for a whole franchise the moment you own a single film from it, so most of what it lists is empty, and on the library this was built against that is 155 of 173.",
                "The Collections row can be switched off in Settings, Home Rows, like every other row there.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "61",
            released: "August 2026",
            headline: "Top Shelf artwork is kept where an Apple TV allows it.",
            changes: [
                "Lagoon was saving its Top Shelf pictures somewhere an Apple TV does not let apps keep things, so the last build drew all eight and then could not save any of them. They now go in the cache, which is where a television expects something it can rebuild.",
                "Settings, Advanced puts the last result underneath the section instead of on one line, so a long reason is readable rather than cut off.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "60",
            released: "August 2026",
            headline: "The Top Shelf artwork can be drawn on an HDR television.",
            changes: [
                "Lagoon was asking the television what kind of picture to draw, and on an HDR set the answer was one that cannot be saved as a JPEG. Every Top Shelf image failed at the last step, which is why the last build could fetch your titles and still show you nothing. Lagoon now picks the format itself.",
                "When something does go wrong, Settings, Advanced now names the step that failed rather than saying only that nothing could be built.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "59",
            released: "August 2026",
            headline: "Eight new rows on Home, in an order that reads.",
            changes: [
                "Home has eight new rows. Because You Watched, named after the last thing you finished. Great Movies You Haven't Seen. Movies in 4K, which is the row for deciding what to put on the good television. A genre and a decade that change daily, drawn from what you actually watch. Series You Haven't Started, Ready to Binge for series that have finished airing, and Surprise Me at the bottom.",
                "The rows are also in a different order. What you were watching comes first, then every movie row together, then every show row together, each run ending with its genre shelf. The genre shelves used to sit in the middle and interrupt, and movies and shows used to alternate.",
                "Any row with too little behind it hides rather than showing you three posters and a lot of space, so a smaller library gets a shorter Home rather than a patchy one.",
                "The new rows are all listed in Settings, Home Rows, and can be turned off individually like the existing ones.",
                "Lagoon was drawing all of its Top Shelf artwork on the same thread that runs the interface. On a Mac that finishes before you notice; on an Apple TV it is long enough to stall the app, which is why nothing ever reached the shelf. The drawing now happens out of the way.",
                "If the Top Shelf has nothing on it, Lagoon now notices when you open the app and fills it in, instead of only ever doing so as a side effect of the Home screen loading.",
                "Settings, Advanced now also says when Lagoon last tried and how that attempt ended, so an empty shelf gives you a reason rather than four zeroes.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "58",
            released: "August 2026",
            headline: "Still chasing the Top Shelf.",
            changes: [
                "The Top Shelf did not appear in the last build, despite what its notes claimed. Lagoon now hands each title over as it is ready instead of all of them at once, so a slow or interrupted first run leaves you with the titles it managed rather than nothing at all.",
                "Settings, Advanced now reports what Lagoon has handed to the Home screen: how many titles, how much artwork, and when it last did it. If that says titles are published and the shelf still shows the Lagoon banner, the fault is not in the app.",
                "Top Shelf artwork drawn by an older version of Lagoon is redrawn rather than kept, so upgrading no longer leaves you looking at the previous layout.",
                "Continue Watching now updates when you come out of something you were watching. It used to wait until you left the Home screen and came back, so the row, and the Top Shelf with it, could still be offering you the episode you had just finished.",
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "57",
            released: "August 2026",
            headline: "The Top Shelf works.",
            changes: [
                "Put Lagoon in the top row of the Apple TV Home screen and what you were watching now fills the screen above it, up to eight titles you swipe through, each with its own artwork, a summary and how much is left.",
                "Play picks up where you stopped. More Info opens the title in Lagoon instead, which is what the second button is for.",
                "A part-watched episode says which episode it is, rather than only naming the series.",
                "Titles carry their 4K, HDR, Dolby Vision and Atmos badges up there, the same ones the Apple TV app shows.",
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
