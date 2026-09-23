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
    /// Newest first. Add an entry at the top when a build goes out; the About
    /// screen highlights whichever one matches the running bundle.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "0.2.1",
            build: "108",
            released: "September 2026",
            headline: "Smoother playback for some films and episodes on Apple TV.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Lagoon now says when a Seerr server sits behind a sign in proxy such as Cloudflare Access, instead of reporting an unreadable response. Connecting through one is not supported yet.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Some 23.976 fps films and episodes no longer judder on Apple TV: the TV now switches to the right frame rate for them.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.2.0",
            build: "107",
            released: "September 2026",
            headline: "Privacy policy and support pages in Settings.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Settings, About and the sign in screens link Lagoon's privacy policy and support page. On Apple TV, scan the code to open them on your phone.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "106",
            released: "September 2026",
            headline: "Home is yours to arrange.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Reorder and hide every Home row, including Home Screen Sections plugin rows, in Settings, Home Rows.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Home opens with Continue Watching, Next Up and what is new in each library.",
                    "Recently Added is split into separate Movies and Shows rows.",
                    "Lagoon remembers your subtitle choice for a series, including none.",
                    "Skip Intro waits for the picture to move again, so a slow connection no longer rebuffers.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "A struggling episode no longer switches to a server transcode partway through.",
                    "Sign Out on Apple TV works, after asking you to confirm.",
                    "Signing out of your last account returns you to the server screen.",
                    "Change Server on the sign in again screen now removes that account.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "105",
            released: "September 2026",
            headline: "The audio track you pick is the one that keeps playing.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Audio tracks with identical names show their position so they can be told apart.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Lagoon remembers the audio track you pick for a series, so poorly labelled releases stop starting in the wrong language.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "104",
            released: "September 2026",
            headline: "Search stops leading to a dead end.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "A search with no matches no longer offers an empty Show All page.",
                    "Watch Together on Apple TV opens as a proper panel with a clear name field.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "103",
            released: "September 2026",
            headline: "Jellyseerr search stops coming up empty.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Seerr search no longer comes up empty when a result is a film collection.",
                    "A film no longer drops to a lower quality stream after the app has been in the background.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "102",
            released: "September 2026",
            headline: "Skip Intro and Next Episode show how long is left.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "The Skip Intro and Next Episode buttons fill up as their countdown runs.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "101",
            released: "September 2026",
            headline: "Readable focused buttons on Apple TV.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Focused buttons and settings on Apple TV keep their text readable.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "100",
            released: "September 2026",
            headline: "Downloads, Watch Together, themes and a new look for film pages.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Download films and episodes to iPhone or iPad and watch them offline. Needs the server's Allow media downloading permission.",
                    "Watch Together: start or join a group from a title's page and watch in sync with others on your server.",
                    "A Baby Pink theme, chosen per profile in Settings, Appearance.",
                    "On iPhone and iPad, playback continues when you lock the screen or leave the app.",
                    "1080i and 576i TV recordings play directly and are deinterlaced on the device.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Redesigned film and series pages on iPhone and iPad, with full width artwork and a large Play button.",
                    "Series pages open on the episode to watch next.",
                    "Seerr title pages match Lagoon's film and series pages.",
                    "Home can show Top 10 Movies and Top 10 Shows from Seerr's trending lists.",
                    "Changelog notes are grouped into New features, Improvements and Bug fixes.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Switching seasons quickly no longer shows the wrong episode list.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "99",
            released: "September 2026",
            headline: "Your Jellyfin profile picture shows up in Lagoon.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "The account picker and Settings show your Jellyfin profile picture.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "98",
            released: "September 2026",
            headline: "4K buffers ahead properly, and image subtitles stop piling up.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "A failed watched or favorite change now says so instead of silently reverting.",
                    "On a full width iPad, film and series pages keep their details in a column beside the artwork.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "4K films played directly buffer ahead at your connection's full speed.",
                    "Image subtitles no longer pile up in memory over a long film.",
                    "Scrubbing backwards right after another jump lands where you asked.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "97",
            released: "September 2026",
            headline: "The iPhone and iPad player stays open, and gets swipe controls.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "The iPhone player no longer forces landscape.",
                    "Swipe down for Picture in Picture, or up for subtitles, audio and speed.",
                    "Three posters per row on iPhone, more in landscape and on iPad.",
                    "Films played directly buffer ahead at full speed and survive brief network drops.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "The player no longer closes itself when started from a title page, Library, Search or Discover on iPhone or iPad.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "96",
            released: "September 2026",
            headline: "Playback problems report themselves.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "When playback fails or stalls, Lagoon sends a short technical report with no account, server or title details. Turn it off in Settings, Advanced, Diagnostic Reports.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "95",
            released: "September 2026",
            headline: "No more blank cards for titles that only have a poster.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Titles with only a poster show it on Home rows instead of a blank card.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "94",
            released: "September 2026",
            headline: "Touch controls for the iPhone and iPad player.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Double tap either side of the video to skip ten seconds.",
                    "Closing the player continues in Picture in Picture.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "A large centered play button with ten second skips, and controls that fade while playing.",
                    "The volume keys control the film, and the Silent switch no longer mutes it.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Watching episodes back to back no longer builds up memory.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "93",
            released: "September 2026",
            headline: "A roomier subtitle search and smoother episode handoffs.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Subtitle search opens a full list of results.",
                    "Smoother player controls during playback.",
                    "Fewer dropped frames on HDR and Dolby Vision with subtitles on Apple TV.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Play Next no longer drops you back to browsing, and starts the next episode sooner.",
                    "A downloaded subtitle carries over to the next episode.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "92",
            released: "September 2026",
            headline: "Dolby Vision for disc remuxes, and transcoding behind proxy paths.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Dolby Vision profile 7 titles, such as UHD Blu-ray remuxes, play as Dolby Vision on Apple TV.",
                    "Settings, About lists the open source components Lagoon uses.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Home always has featured titles.",
                    "Subtitle search goes through your Jellyfin server only, and the OpenSubtitles settings are gone.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Servers behind a proxy path such as example.com/jellyfin can transcode and load external subtitles.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "91",
            released: "September 2026",
            headline: "Safer account switching and easier server setup.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Changing subtitle tracks keeps the current one until the new one is ready, with Retry if it fails.",
                    "An expired sign in takes you back to sign in, keeping your accounts and settings.",
                    "Sign in warns when a server uses unencrypted HTTP.",
                    "iPhone and iPad explain how to allow local network access when it is blocked.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Switching accounts no longer carries over searches, Seerr sign ins or Top Shelf links.",
                    "Removing an account also clears its searches, preferences and Seerr sign in.",
                    "Server addresses with proxy paths, custom ports and IPv6 work.",
                    "HTTPS playback checks the server's certificate.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "90",
            released: "September 2026",
            headline: "Swipeable featured titles and cleaner Home rows.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Swipe through featured titles on Home and Discover, or press Left and Right on Apple TV.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Next Up only shows episodes you have not started.",
                    "Recently Added shows a series once, not every new episode.",
                    "Larger posters and buttons on iPhone and iPad.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "89",
            released: "September 2026",
            headline: "One Library, fuller search, and a more comfortable iPhone.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Movies and shows share one Library tab.",
                    "Sort and filter the Library by genre, decade, unwatched, favourites and 4K.",
                    "See All for Jellyfin and Seerr search results.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "iPhone and iPad layouts adapt to the screen and to larger text.",
                    "Sharper artwork on high resolution screens.",
                    "Settings on iPhone and iPad is split into separate pages.",
                    "The iPhone and iPad player uses standard controls, with speed and audio delay options.",
                    "Partly available Seerr titles open in Lagoon.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "88",
            released: "September 2026",
            headline: "Rows pick up the colour of what you are looking at.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "With the controls showing, tap the Siri Remote touch surface to see when the film will end.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Focused artwork on Apple TV casts a glow in its own colours.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "87",
            released: "September 2026",
            headline: "Pages stay current, and the Siri Remote feels at home.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Home, Movies, Shows and Discover stay current, with pull to refresh on iPhone and iPad and a refresh button on Apple TV.",
                    "Pending Seerr requests update on their own.",
                    "A light tap on the Siri Remote shows the controls without pausing.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Resume and Continue Watching update as soon as you stop watching.",
                    "Jellyfin 12 preview servers no longer reject Lagoon's video and subtitle links.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "86",
            released: "September 2026",
            headline: "Remuxed and transcoded titles no longer lose their sound every few seconds.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Playback Details shows audio and video buffer health.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Remuxed and transcoded titles no longer drop their sound every few seconds.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "85",
            released: "September 2026",
            headline: "4K AV1 plays smoothly on Apple TV.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Software decoded HDR is converted on the GPU.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "4K HDR AV1 no longer starts dropping frames half a minute in.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "84",
            released: "September 2026",
            headline: "More of the Apple TV works on 4K AV1 at once.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "The AV1 decoder works on more frames at once, for a faster decode.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "83",
            released: "September 2026",
            headline: "4K AV1 shows in SDR on Apple TV, the way it has to be.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Software decoded HDR shows in SDR on Apple TV, which cannot present it as HDR. iPhone and iPad keep HDR.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "82",
            released: "September 2026",
            headline: "4K AV1 frame preparation spreads across more cores.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Preparing decoded frames for display uses several cores instead of one.",
                    "Playback Details shows the full cost of each frame.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "81",
            released: "September 2026",
            headline: "AV1 falls back instead of failing.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Most decoder test switches are removed.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "AV1 files the system refuses to decode play with Lagoon's own decoder.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "80",
            released: "September 2026",
            headline: "A test switch for decoding AV1 with the system.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Decode AV1 with the System Decoder, in Settings, Advanced, for testing. Turn it off if AV1 files stop playing.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "79",
            released: "September 2026",
            headline: "A newer AV1 decoder.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "AV1 decoding moves to dav1d 1.5.4, which spreads work across cores better.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "78",
            released: "September 2026",
            headline: "Playback details say how many processor cores are decoding.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Playback Details shows how many cores are decoding, and Settings, Advanced can change it.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "77",
            released: "September 2026",
            headline: "A way to measure what film grain costs the decoder.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Skip Film Grain, in Settings, Advanced, measures what AV1 film grain costs. It changes the picture, so it is for testing.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "76",
            released: "September 2026",
            headline: "Playback details say what decoding a frame actually costs.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Playback Details shows each frame's decode cost against its time budget.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "75",
            released: "September 2026",
            headline: "AV1 decodes several times faster.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "AV1 decodes several times faster on every device, with no change to the picture.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "73",
            released: "September 2026",
            headline: "Software decoded video reads and decodes at the same time.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Software decoded video, such as AV1, VP9 and MPEG-2, reads and decodes in parallel for a steadier frame rate.",
                    "Playback Details separates decoding, converting and reading time.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "4K software decoded films no longer hold a gigabyte of frames in memory.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "72",
            released: "September 2026",
            headline: "4K AV1 plays on the device.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "4K AV1 plays on the device instead of being converted by your server.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Software decoding uses every core, about eight times faster for 4K AV1.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "71",
            released: "September 2026",
            headline: "A film from a disc starts at the beginning, and the scrubber works.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Disc images and TV recordings start at the beginning, and the scrubber works.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "70",
            released: "September 2026",
            headline: "Disc images play from the disc, Blu-ray and DVD alike.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "DVD images play directly from the disc.",
                    "Lagoon deinterlaces MPEG-2 itself, so DVDs and older recordings no longer need the server.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Blu-ray images play, with their original soundtrack.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "69",
            released: "September 2026",
            headline: "A film kept as a Blu-ray disc image now plays straight from the disc.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Blu-ray images play the main feature directly, keeping a TrueHD or Atmos soundtrack.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "DVD images and disc folders go straight to the server, so they start sooner.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "68",
            released: "August 2026",
            headline: "On an iPhone or iPad, cellular no longer means downloading the whole film.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "A Full Quality on Cellular switch in Settings, for fast unmetered connections.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "On cellular or a hotspot, Lagoon asks the server for a smaller version instead of the original file.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "67",
            released: "August 2026",
            headline: "Fixes the constant buffering from the last build.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Films no longer stop to buffer every few seconds, a regression in 0.1 (66).",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "66",
            released: "August 2026",
            headline: "More 4K films play directly, and lost sound shows as buffering.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "When the sound runs out because a film arrives too slowly, Lagoon shows buffering instead of playing on in silence.",
                    "Films your server converts keep more sound in reserve.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Some 4K releases that fell back to a server transcode now play directly. Worth retrying any that did.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "65",
            released: "August 2026",
            headline: "A film your server has to convert keeps playing instead of stalling.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Fallback transcodes are requested at 1080p instead of 4K, so most servers keep up.",
                    "Playback Details shows which delivery was used and why.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "64",
            released: "August 2026",
            headline: "A switch for chasing sound that cuts out.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Buffer Transcoded Playback, in Settings, Playback Diagnostics, for converted titles whose sound cuts out.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Playback Details shows buffered sound in seconds.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "63",
            released: "August 2026",
            headline: "Control Center stops blanking the picture, and more of your files play untouched.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "WMV3 video in MKV or AVI, MP2 and Apple Lossless play directly.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Opening Control Center during a film no longer blanks the TV.",
                    "Recent searches keep what you searched for, not every letter typed.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "62",
            released: "August 2026",
            headline: "Collections, and the new Home rows open the title you picked.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "A Collections row on Home, and collections in Search.",
                    "Empty and single title collections are hidden.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Picking from the new Home rows opens the title instead of playing it.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "61",
            released: "August 2026",
            headline: "Top Shelf artwork is kept where an Apple TV allows it.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Top Shelf artwork is saved where Apple TV allows it.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "60",
            released: "August 2026",
            headline: "The Top Shelf artwork can be drawn on an HDR television.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Top Shelf artwork works on HDR televisions.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "59",
            released: "August 2026",
            headline: "Eight new rows on Home, in an order that reads.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Eight new Home rows, including Because You Watched, Movies in 4K, Ready to Binge and Surprise Me.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Home groups what you are watching, then movies, then shows.",
                    "Rows with too little in them hide.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Drawing Top Shelf artwork no longer stalls the app.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "58",
            released: "August 2026",
            headline: "Still chasing the Top Shelf.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "The Top Shelf fills in with whatever titles are ready, instead of nothing.",
                    "Continue Watching updates as soon as you stop watching.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "57",
            released: "August 2026",
            headline: "The Top Shelf works.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "The Top Shelf shows up to eight titles you were watching, with artwork, a summary, time left and quality badges.",
                    "Play resumes where you stopped, and More Info opens the title in Lagoon.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "56",
            released: "August 2026",
            headline: "Search moves out, and Discover fills the screen.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Search has its own tab and remembers recent searches.",
                    "Discover has a hero banner and eight rows, in your Seerr administrator's order.",
                    "A request that has arrived opens straight into Lagoon.",
                    "Unblock titles on your Seerr blocklist from Lagoon.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Requests show download progress and the quality they will be fetched at.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Requests show their real status instead of always pending.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "55",
            released: "August 2026",
            headline: "Play at your own speed.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Playback speed from half to double, keeping voices at their pitch.",
                    "Positioned and styled subtitles appear where and how they were authored.",
                    "10-bit AV1 and VP9 play directly.",
                    "MPEG-2, LPCM and DVB subtitles play directly, covering most DVD rips and recordings.",
                    "Spatial Audio for stereo soundtracks on AirPods.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "A new app icon and look.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Starting a film after a failed one no longer waits fifteen seconds.",
                    "A failed film no longer leaves your server converting it.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "54",
            released: "August 2026",
            headline: "Playback recovers instead of giving up.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "A film that will not play retries another way instead of showing an error.",
                    "Lost sound is rebuilt instead of playing on in silence.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Pausing near the start buffers as far ahead as it should.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "53",
            released: "August 2026",
            headline: "Subtitle errors say what the server said.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "A failed subtitle download shows your server's reason.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "52",
            released: "August 2026",
            headline: "Subtitle search works for server administrators again.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Subtitle search works again for Jellyfin administrators.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "51",
            released: "August 2026",
            headline: "Seerr signs itself in.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Discover signs in to Seerr with your Jellyfin account.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "50",
            released: "August 2026",
            headline: "Playback, subtitles and requests.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Fetch subtitles from OpenSubtitles when your Jellyfin account cannot. Add a key in Settings, Subtitles.",
                    "An About screen with this changelog.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Seerr requests are a poster grid, each with its own page.",
                    "Builds before 50 are not listed.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Long films no longer start stuttering partway through.",
                    "Subtitle errors name the real cause.",
                    "Subtitles that are not UTF-8 display correctly.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "1",
            released: "August 2026",
            headline: "First TestFlight build.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Lagoon's own playback engine, with no AVPlayer.",
                    "Direct play for H.264, HEVC, VC-1 and MPEG-4, so fewer titles transcode.",
                    "HDR10 and Dolby Vision with display matching, and Dolby Digital, Atmos and TrueHD passthrough.",
                    "Embedded, external and searchable subtitles.",
                    "Trickplay scrubbing, intro skipping and autoplay into the next episode.",
                    "Home, library browsing, search and a Top Shelf extension.",
                    "Browse and request titles from Seerr.",
                ]),
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

    /// A development build can lack notes until its release is prepared.
    /// Saying so is better than quietly omitting the installed build.
    static func isListed(version: String, build: String) -> Bool {
        entries.contains { isRunning($0, version: version, build: build) }
    }

    static func runningBuildIsListed(bundle: Bundle = .main) -> Bool {
        isListed(version: version(from: bundle), build: build(from: bundle))
    }
}
