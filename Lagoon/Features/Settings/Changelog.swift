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
            version: "0.1",
            build: "100",
            released: "September 2026",
            headline: "Downloads on iPhone and iPad, a new look for film and series pages, and interlaced TV recordings play directly.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Films and episodes can be downloaded to an iPhone or iPad and watched without the server. The download button on a title's page offers Original, High (1080p) and Standard (720p) with an estimated size, transfers continue while the app is in the background, and downloaded titles carry a mark on their posters. Your downloads are listed at the top of Library and keep working when the server cannot be reached, and where you stop watching reaches the server once it is back. Settings has a Downloads page for the default quality, Wi-Fi only, storage and a way to the list of what is on the device. The account needs the server's Allow media downloading permission.",
                    "1080i and 576i H.264 recordings, the kind a TV tuner produces, now play straight from your server and are deinterlaced on the device. They used to be re-encoded by the server, which on a busy server meant a stuttering start and occasional pauses.",
                    "A Baby Pink theme, for those who love pink: soft pink accents over a deep rose ground, with artwork glows blushed to match and, on iPhone, a rose tab bar, chosen under Settings › Appearance and remembered for that Jellyfin user, so a partner's pink stays with their profile. Picking a theme blooms it across the screen, with flowers drifting up for Baby Pink and swimming jellyfish for Lagoon. On iPhone, the Lagoon theme's selected tab and switches are a pale aqua instead of white.",
                    "On iPhone and iPad, playback keeps going when you lock the phone or leave the app: the sound carries on, intros are still skipped, the next episode still starts, and the picture is back when you return. The lock screen's play, pause and skip controls work throughout.",
                    "Watch Together: start or join a group from a film or episode's page and everyone in it watches in step, with play, pause and skipping reaching all of you and the group waiting for whoever is still loading. The player's Together tab shows who is in the room, Home keeps a way back in after you close the player, and on iPhone a locked screen stays in sync. Your Jellyfin server decides who may use it; a group's name is visible to everyone signed in to the server.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Film and series pages on iPhone and iPad are redesigned. The film's landscape artwork fills the top of the page in portrait and the whole screen in landscape, a large Play button sits under the title with the watched, favorite and From Beginning buttons beneath it as a row of circles, and the whole synopsis is shown instead of a Read Synopsis button. On an iPad in a full-width window the page keeps its landscape artwork and side-by-side layout, with more of the artwork showing. The tab bar steps out of the way while a film or series page is open.",
                    "A series page always has an episode ready to play: the one you are partway through, the next unwatched one, or the first of the season once you have seen the whole show. The page opens on that episode's season with the episode in view, and after watching it follows you to wherever you stopped, even seasons later. Watched episodes carry a check mark, and on Apple TV the synopsis keeps its height so the page no longer jumps as you browse episodes.",
                    "Discover's Movies, Shows and Requests buttons sit on one row on iPhone instead of stacking. A Seerr title's page now looks like a film or series page: the key art fills the top on iPhone and iPad, the Request, Open in Lagoon or status button is the page's one big button, the age rating, cast and crew are shown, and a More Like This row follows.",
                    "The changelog groups each build's notes into New features, Improvements and Bug fixes so changes are easier to find.",
                    "Home can now show Top 10 Movies and Top 10 Shows by matching Seerr's popular and trending lists to titles in your Jellyfin library, with each ranked title's number shown beside its artwork; existing Home Screen Sections Manager rows remain supported.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Quick season changes keep the newest episode list instead of letting an earlier selection replace it after loading.",
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
                    "The account picker and Settings now show your Jellyfin profile picture instead of only your initials. Accounts without a picture keep the initials, and a picture changed on the web is picked up the next time the account is opened.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "98",
            released: "September 2026",
            headline: "4K films buffer ahead properly, and image subtitles stop piling up over a long film.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "When marking something watched or adding a favorite fails, the button now says so briefly instead of silently flipping back. After the server accepts a change, the page re-reads it so a change made on another device shows up too.",
                    "On an iPad in a full-width window, a film or series page now keeps its title, details and buttons in a column beside the artwork, the way the TV lays it out, instead of spreading the synopsis across the whole screen.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "4K films played directly from your server now buffer ahead at your connection's pace like everything else. The previous build only did this for lower-bitrate titles and quietly kept the old trickle for 4K.",
                    "Image subtitles such as those on Blu-ray rips no longer keep every picture they have shown in memory until you seek. Over a long film that could add up to hundreds of megabytes and slow the player down.",
                    "Scrubbing backwards right after another jump no longer gets ignored. The player could restart its clock at the old position and race the picture forward to it instead of landing where you asked.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "97",
            released: "September 2026",
            headline: "The iPhone and iPad player no longer closes itself, and it gets swipe controls.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "The iPhone player no longer turns the screen to landscape by itself. A film opened in portrait plays in portrait until you turn the phone.",
                    "Swipe down on the video to shrink the player into Picture in Picture; it follows your finger on the way down. Swipe up to open the options panel with subtitles, audio and speed. The Close button now simply closes the player.",
                    "Library, search results, Discover and Requests show three posters per row on iPhone instead of two, more when the phone is on its side, and four or more on iPad.",
                    "Films played directly from your server buffer ahead as fast as your connection allows once playback is running, instead of at a fixed trickle, until about two minutes are cached. A momentary network failure no longer stops buffering for the rest of the film, and catching up with the buffer no longer downloads the same part twice.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Playing a title from its detail page, Library, Search or Discover on iPhone or iPad no longer closes the player a moment after it opens. Titles started from Home and Continue Watching were never affected, which made it look as if only some films were broken.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "96",
            released: "September 2026",
            headline: "Playback problems now reach the developer on their own.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "When playback fails unexpectedly, stalls badly, or a server request goes wrong, Lagoon sends a short technical report so the problem can be fixed without you having to describe it. Reports contain the app build, device model, codec and delivery details, error codes, and about a minute of playback measurements. They never include your account, server address, titles, subtitles, or screenshots.",
                    "Reporting can be turned off at any time under Settings, Advanced, Diagnostic Reports, which also discards anything not yet sent.",
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
                    "A film or show with a poster but no wide artwork now shows its poster on Home rows such as Recently Added and Favorites instead of an empty grey card. The rare title with no artwork at all shows its name.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "94",
            released: "September 2026",
            headline: "Touch controls for the iPhone and iPad player, Picture in Picture on the way out, and a tidier iPad Home.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Double-tap the left or right half of the video to skip back or forward ten seconds without bringing up the controls. Double-tap again within a moment to add another ten seconds.",
                    "Closing the player on iPhone or iPad continues the video in Picture in Picture when it is available, and returning from the picture brings you back to the full player where you left it.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "The iPhone and iPad player has a large centered play/pause button with ten-second back and forward beside it. Tap the video to show or hide the controls; while a film plays, they fade on their own after a few seconds.",
                    "On iPhone, the player stays in landscape while it is open and lets the screen rotate again when you close it. The volume keys control the film, and the Silent switch does not mute it.",
                    "The Home banner on iPhone and iPad has gently rounded corners instead of very round ones. On iPad it is taller, with a narrower text column that is easier to read.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Watching several episodes in a row no longer keeps each finished episode's player in memory until you close the player.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "93",
            released: "September 2026",
            headline: "A roomier subtitle search, a smoother player, and cleaner episode handoffs.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Searching for subtitles now opens a full list of results, five at a time, instead of two squeezed above your tracks. Done or the Back button returns you to the track list, changing the language searches again, and a downloaded subtitle takes you straight back to your tracks with it selected.",
                    "The player's control panel and remote response are smoother during playback: the player no longer redraws all of its controls ten times a second while a film plays.",
                    "Fewer dropped frames on HDR and Dolby Vision titles while subtitles are showing on Apple TV.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Choosing Play Next before an episode ends no longer drops you back to the browse screen, and the next episode starts sooner instead of waiting for its buffer to fill.",
                    "A subtitle you download during an episode now carries over to the next episode like any other track choice.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "92",
            released: "September 2026",
            headline: "Dolby Vision for disc remuxes, transcoding behind proxy paths, and a Home that always has featured titles.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Dolby Vision profile 7 titles, such as UHD Blu-ray remuxes, now play as Dolby Vision instead of HDR10 on Apple TV. If a title looks wrong, Settings → Advanced → Playback Diagnostics → Dolby Vision Compatibility Mode brings back the HDR10 behavior.",
                    "Settings → About now lists the open-source components Lagoon is built on, with their licences, and the same information is reachable from the sign-in screen before you connect to a server.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Home always opens on featured titles. When nothing has been added recently, it features what you are watching, your favourites, or a pick from your library instead of showing no banner at all.",
                    "Subtitle search now uses your Jellyfin server only. Settings → Subtitles shows whether your account is allowed to search for subtitles, and what to ask your server administrator for if it is not.",
                    "The OpenSubtitles account, API key and Search With settings have been removed, and any saved OpenSubtitles sign-in is cleared.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Jellyfin servers reached through a reverse-proxy path, such as example.com/jellyfin, can now transcode and load external subtitles. Previously those requests went to the wrong address and playback fell back or failed.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "91",
            released: "September 2026",
            headline: "Clearer subtitle recovery, safer account switching, and easier server setup.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Changing subtitle tracks keeps your current captions until the new track is ready. If it fails, playback continues and Subtitles offers an explanation and Retry.",
                    "Subtitle files over 8 MB now show a clear size-limit message. Oversized or incomplete artwork uses a placeholder instead of trying to display a broken image.",
                    "If your Jellyfin sign-in expires or is revoked, Lagoon takes you back to sign-in for that account while keeping your saved accounts and preferences.",
                    "Sign-in shows the full server address and warns when the connection uses unencrypted HTTP, before you enter your credentials.",
                    "If local-network access is blocked on iPhone or iPad, Jellyfin and Seerr setup explains how to enable it in Settings and offers Retry without re-entering the server address.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Search results, recent searches and Seerr sign-ins no longer carry over when you switch Jellyfin accounts.",
                    "Removing a remembered account also clears its recent searches, preferences and linked Seerr sign-ins, while keeping your other accounts intact.",
                    "On Apple TV, Home screen previews are tied to the active Jellyfin account. Links left over from a previous account no longer open titles.",
                    "Jellyfin and Seerr setup now handles server addresses with proxy paths, custom ports and IPv6 correctly, and explains invalid addresses before trying to connect.",
                    "HTTPS playback now checks the server's certificate and rejects invalid or untrusted connections. Servers using a private certificate authority need it to be trusted on your device.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "90",
            released: "September 2026",
            headline: "Featured titles you can swipe through, clearer Home rows, and easier browsing.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Browse featured titles on Home and Discover by swiping left or right on iPhone and iPad, or pressing Left and Right on your Apple TV remote. Tap or select the banner to open the title on screen.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Featured banners pause automatic rotation while you swipe or focus them on Apple TV, and keep your selected title when the library refreshes. VoiceOver announces the slide position and offers next and previous actions.",
                    "Next Up now only shows episodes you have not started. Partly watched episodes stay in Continue Watching, while playing from a show's details still resumes where you left off.",
                    "Recently Added show rows now display the show once when new episodes arrive, instead of listing individual episodes.",
                    "Posters on iPhone and iPad are larger across Library and recommendation rows, with layouts that adapt to the available space and text size.",
                    "Title details on iPhone and iPad use larger standard action buttons, with Resume and From Beginning kept together when space allows.",
                    "Long movie and show genre names on Apple TV are centered and can wrap onto two lines instead of being cut off.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "89",
            released: "September 2026",
            headline: "One Library, fuller search results, and a more comfortable iPhone experience.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Movies and shows now share one Library tab. Browse everything together, or choose Movies or Shows.",
                    "Sort your Library by title, recently added, release date or rating, and combine filters for genre, unwatched titles, favourites and 4K movies. Your choices are remembered separately for each account.",
                    "Filter by decade using the years actually represented in your library, with choices that update as your collection changes. A library selector appears when your server has multiple movie or show libraries to choose between.",
                    "Search now offers See All for both your Jellyfin library and Seerr, with more results loading as you scroll. Changing the search clears the previous matches instead of leaving unrelated titles on screen.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Rows on iPhone and iPad have more breathing room, with clearer space between headings, artwork and the next row.",
                    "The Home banner on iPhone and iPad is shorter and wider, with compact text and centered page indicators, so more of your library is visible underneath.",
                    "Grids, title details, request cards and action buttons on iPhone and iPad adapt to the space available and larger text sizes, instead of squeezing labels and controls together.",
                    "Posters, backdrops and episode artwork are sharper on high-resolution screens and update when their display size changes.",
                    "On iPhone and iPad, tapping an episode opens its details before playback. Seasons are chosen from a standard menu.",
                    "Seerr titles that are only partly available can now open in Lagoon when the title is already in Jellyfin, so you can reach the episodes you have without waiting for the rest.",
                    "The iPhone and iPad player uses standard toolbar controls and a resizable playback-options sheet, with clearer track choices and controls for speed and audio delay. VoiceOver keeps the playback controls available and can move the playhead in ten-second steps.",
                    "Settings on iPhone and iPad is organised into Account, Playback, Audio, Subtitles, Home Rows, Seerr, Advanced and About pages. Each opens separately instead of putting every setting in one long view.",
                    "Settings → Home Rows on iPhone and iPad uses standard switches to show or hide rows and Edit to reorder them.",
                    "Settings → Subtitles → Subtitle Appearance explains when captions follow the system's accessibility settings. Lagoon's custom appearance controls are shown only when system styling is turned off.",
                    "Add Account opens sign-in for your current Jellyfin server, with Use Another Server available when needed. Cancelling setup leaves your existing Jellyfin account and Seerr connection untouched.",
                    "Server entry and sign-in on iPhone and iPad have lighter native input fields without filled boxes. Username offers Next to move to Password, while password and server address offer Go.",
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
                    "While the playback controls are showing, another light tap on the Siri Remote touch surface swaps the time remaining for the time of day the film or episode will end. Tap again to swap back. Pause, and it keeps up: the finish time moves later for as long as you stay paused, and a faster playback speed brings it closer.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "On Apple TV, whatever you are pointed at in a row now casts a soft glow in the colours of its own artwork, underneath the usual lift. Posters are a little larger as well, with more room between rows.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "87",
            released: "September 2026",
            headline: "Pages keep themselves current, and the Siri Remote feels at home.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Home, Movies, Shows, and Discover stay current while you leave Lagoon open, refresh after you return, and can be updated whenever you choose: pull down on iPhone or iPad, or choose the refresh button beside Home on Apple TV.",
                    "A request you are watching in Discover updates itself. While it waits for approval, and while your server is downloading and importing it, the page keeps up on its own instead of needing you to leave and come back.",
                    "A light tap on the Siri Remote touch surface now reveals the playback controls without pausing, seeking, or moving focus.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "After you leave the player, Play changes to Resume and Home's progress bars and Continue Watching refresh after Jellyfin saves the new position, instead of showing the state from before you watched.",
                    "Servers running the Jellyfin 12 preview no longer turn Lagoon's links away. That release switches off an older way of carrying your credentials in a link, which Lagoon still used for video, external subtitles and scrubbing thumbnails; it now uses the current one everywhere.",
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
                    "If the sound ever drops out while the picture keeps playing, the playback details overlay counts it (aDry) and shows how far ahead the audio is fed (lead), so the problem can be reported with numbers rather than a description. The overlay is under Settings → Advanced → Show Playback Details.",
                    "The same overlay shows the video queue's peak against its limit, how much video is waiting behind it, and whether a buffering pause had to fall back to a seek to recover.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Titles the server has to remux or transcode, such as a disc image or a fallback after a playback error, played with the sound cutting out for a second or more, over and over, while the picture kept going. The player was reading those streams in an order that starved its own audio buffer; it now reads far enough ahead to keep the sound fed, on every kind of title.",
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
                    "Software-decoded HDR video is converted for the screen by the GPU instead of the CPU, in the background, so the decoder never waits for it.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "4K HDR AV1 episodes no longer start stuttering and dropping frames half a minute in. The Apple TV's decoder had been competing for the CPU with a part of the player that kept asking for video it did not have; that loop is gone, and the same scene that dropped a quarter of its frames now plays through it, dropping a handful rather than hundreds.",
                    "Every other kind of playback benefits from the first change too, since that loop ran on any title; hardware-decoded films simply had CPU to spare.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "84",
            released: "September 2026",
            headline: "More of the Apple TV can work on 4K AV1 at once.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Lagoon now lets its AV1 decoder work ahead across more video frames, instead of leaving part of its multicore throughput unused. This produced roughly 40 to 55 percent more frames per second in controlled tests, though the gain still needs confirmation on an Apple TV.",
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
                    "On an Apple TV, video that Lagoon decodes itself now reaches the screen the same way hardware-decoded video does, instead of being blended with the interface frame by frame, which is the most expensive way a television can show a film.",
                    "For HDR films that Lagoon decodes itself, that requires showing them in SDR on Apple TV: the Apple TV cannot truly show this kind of playback in HDR, and pretending otherwise cost performance without delivering HDR. The conversion is done properly by the hardware, not by relabeling. Infuse made the same choice for the same reason. iPhone and iPad keep HDR.",
                    "This build carries the plumbing; 4K AV1 is better but not yet where it should be, and the remaining gap is understood well enough to keep chasing.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "82",
            released: "September 2026",
            headline: "A little more of the work of showing 4K AV1 spread across the chip.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Preparing each decoded frame for display was being done on a single processor core. It is now split across a few, which is a small part of what 4K AV1 costs on an Apple TV but a real one.",
                    "Playback details now show what a whole frame costs rather than only the decoding part, which was reading comfortably under budget while the total was over it.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "81",
            released: "September 2026",
            headline: "AV1 falls back instead of failing, and the testing options are tidied away.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "One is left, Force SDR Output, and one is new: on an Apple TV, 4K AV1 cannot truly be shown in HDR, and Lagoon has been asking your TV for it anyway. This turns that off so the cost of it can be measured. It makes the picture look flat, so it is for testing rather than watching.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Most of the decoder testing options added over the last few builds are gone. They answered their questions, none of them made playback better, and a settings page full of switches that do nothing is worse than none.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "An AV1 file could fail to play outright if the system turned down a request to decode it. Lagoon now checks first and decodes the file itself when the answer is no, which is what it should have done all along.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "80",
            released: "September 2026",
            headline: "An option to let the system decode AV1 instead of Lagoon.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Lagoon decodes AV1 itself on devices whose chip has no AV1 support, which on an Apple TV is most of a 4K frame's worth of work. It turns out the system may be able to decode it anyway, and Lagoon was never asking. Settings then Advanced now has Decode AV1 with the System Decoder, to find out.",
                    "It is off, and it is a test rather than a setting: on a device where the system genuinely cannot decode AV1, an AV1 file will fail to play with it on. Turn it back off if that happens.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "79",
            released: "September 2026",
            headline: "A newer AV1 decoder, with better threading.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Lagoon's AV1 decoder moves up to dav1d 1.5.4, which schedules the work of decoding a frame across processor cores better than the version before it. That matters most on an Apple TV playing 4K, where there is the least room to spare.",
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
                    "Lagoon used to leave the number of cores used for software decoding up to the video library, which meant nobody could find out what it had chosen. It now decides explicitly, defaults to every core the device has, shows the number in playback details, and lets it be changed in Settings then Advanced for testing.",
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
                    "AV1 video can carry film grain that the encoder strips out and the decoder paints back on, frame by frame, and doing that is a real share of the work of playing a 4K file. Settings then Advanced now has Skip Film Grain, which measures how much.",
                    "It changes the picture, because the grain is part of how the film was finished. It is there to find out what the grain costs, not to be left on.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Playback details also say how many frames in what you are watching actually asked for grain, so it is possible to tell whether any of this applies to a given file.",
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
                    "4K AV1 on an Apple TV starts smoothly and slowly loses ground, which is the Apple TV warming up rather than anything about the file. Playback details, in Settings then Advanced, now report what one frame costs to decode against the time available for it, so that can be watched happening instead of guessed at.",
                    "Two new options sit beside it for testing how the decoder is scheduled. Both are off, both are for diagnosing the above, and neither is worth turning on during normal viewing.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "75",
            released: "September 2026",
            headline: "The AV1 decoder was not using the chip's video instructions. Now it is.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "4K AV1 played on an Apple TV with no AV1 chip of its own, but at under half the frame rate it needed. The cause turned out to be the decoder Lagoon ships rather than anything about how Lagoon used it: the prebuilt copy everyone in this corner of the world uses was compiled without the hand-written routines Apple chips provide for video decoding, so every frame took the slow, general path. Lagoon builds its own copy now, with those routines kept.",
                    "This makes AV1 several times cheaper to decode on every device, and it applies to an iPhone and iPad as much as to an Apple TV.",
                    "Nothing about picture quality changes. It is the same decoder and the same version, doing the same work by a faster route.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "73",
            released: "September 2026",
            headline: "Video Lagoon decodes itself is read and decoded at the same time, not in turns.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "4K AV1 played on an Apple TV with no AV1 chip of its own, but it did not hold a steady frame rate. Lagoon was reading the file and decoding it one after the other on the same thread, so it stopped reading for as long as each frame took to decode, and nothing was waiting for the picture when the time came to show it. Those two now happen at the same time.",
                    "This applies to everything Lagoon decodes itself: AV1 where the device has no hardware for it, VP9, VC-1, MPEG-2 and older MPEG-4. Formats your device decodes in hardware, which is most of them, take a different path and are unchanged.",
                    "Playback details, in Settings then Advanced, now separate decoding from converting from reading the file, so a stutter can be attributed rather than guessed at.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "A 4K film decoded this way could hold about a gigabyte of finished frames in memory at once, which is more than the system will let an app keep. It is now held to the same ceiling everything else uses.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "72",
            released: "September 2026",
            headline: "Video Lagoon decodes itself now uses the whole device, not one core.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "4K AV1 plays on the device now, on hardware with no AV1 chip of its own. Lagoon used to hand those files to your server to convert, which is slow to start and can time out before anything appears. It decodes them itself instead.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "That became possible because of the second half of this build: anything Lagoon decodes in software was running on a single processor core, because of a default nobody had noticed. Decoding a 4K AV1 episode measured eight times faster with the rest of the cores put to work. The same applies to VC-1, MPEG-2, VP9 and older MPEG-4 files.",
                    "Formats your device decodes in hardware, which is most of them, were never affected and are unchanged.",
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
                    "Playing a Blu-ray or DVD image opened as though an hour of it had already gone by, and the progress bar could not be dragged anywhere useful. A disc counts time from wherever its own clock happens to start, which for one disc here was 70 minutes in. Lagoon counts from the start of the film now, like it does for everything else.",
                    "The same applies to any recording whose timestamps do not start at zero, which is common for anything captured off the air.",
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
                    "DVD images play from the disc as well, instead of being rebuilt by your server. Lagoon picks the main title set and plays it.",
                    "Interlaced video no longer has to go to your server to be made watchable. Lagoon can now deinterlace MPEG-2 itself, which is what DVDs and most older recordings are. A still shot keeps its full detail, and movement is interpolated rather than left with the comb-toothed edges interlacing leaves behind.",
                    "This covers a disc stored as one image file. A disc kept as a folder of files still plays through your server, because Jellyfin gives an app no way to reach inside one, and interlaced video in other formats still goes to the server too.",
                    "A DVD that keeps several episodes in one title will play them one after another. Choosing a single episode off a disc like that is not there yet.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Blu-ray images did not actually play in the last build. Lagoon read the disc correctly and then stopped at the final step with a decoder error, because a Blu-ray describes its video in a way nothing else Lagoon plays uses. It plays now, with the soundtrack the disc was mastered with rather than a converted one.",
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
                    "A film your server stores as a Blu-ray disc image had to be rebuilt by the server before it could play, and that rebuild flattened a Dolby TrueHD or Atmos soundtrack down to Dolby Digital. Lagoon now reads the disc itself and plays the main feature as it was mastered, with the soundtrack it came with.",
                    "Choosing the feature off a disc is not as obvious as it sounds: a Blu-ray can carry sixty or more playlists, and the longest one is often a menu loop rather than the film. Lagoon picks using the running time your server already knows.",
                    "If a disc turns out to be one Lagoon cannot read, playback goes through your server exactly as it did before, so nothing that used to play stops playing.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "This covers Blu-ray images. A DVD image, or a disc kept as a folder of files rather than as one image, still plays through your server, and now goes there directly rather than trying and failing first, so it starts sooner.",
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
                    "If the connection is one you know is fast and unmetered, Settings has a new Full Quality on Cellular switch. Your device can tell Lagoon that a connection is metered but never that it is slow, so this one is your call rather than a guess.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "On a cellular connection or a personal hotspot, Lagoon used to ask your server for the original file. For a 4K film that can be tens of gigabytes, so it started slowly, looked no better for it, and spent a data allowance in minutes. It now asks for a smaller version instead.",
                    "Nothing changes on Apple TV, or on Wi-Fi anywhere. This applies only where the connection itself is metered.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "67",
            released: "August 2026",
            headline: "Undoes the constant buffering the last build introduced on anything with sound.",
            sections: [
                ChangelogSection(category: .bugFixes, changes: [
                    "Films with sound stopped and buffered every few seconds in 0.1 (66). That was a mistake in the last build and it is undone here. Lagoon had started watching how much sound was waiting in its own queue and treating a low reading as the sound having run out, when a low reading there is simply what a healthy film looks like: the sound has already been handed on to the part of the system that plays it, so very little is ever waiting.",
                    "Lagoon still notices and records when that queue empties, and Playback Details shows it, because the original problem it was meant to catch is real. It just no longer stops a film over it.",
                    "Everything else from the last build stands, including 4K films that previously refused to start.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "66",
            released: "August 2026",
            headline: "Some 4K films now start instead of being handed to your server, and a film that loses its sound says so.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "When the sound runs out because the film is not reaching your Apple TV fast enough, Lagoon now shows that it is buffering instead of carrying on with the picture and no sound. Nothing reported this before. The picture kept moving, every reading in Playback Details looked normal, and the only sign anything was wrong was the silence itself.",
                    "Lagoon also holds more sound in reserve now when your server is converting a film. Converted films had no reserve at all, so any stumble in delivery reached you immediately as silence, while the picture carried on from what it had already been given. There is more to come here, and the Buffer Transcoded Playback switch in Settings, Playback Diagnostics is still worth trying on a title that misbehaves.",
                    "That is honesty rather than a cure. A film whose sound keeps running out is still a film arriving too slowly, and there is more to do there, but it now tells you instead of hiding it.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "A film can now start even when its file does not describe its own video properly. Some 4K releases leave that description out of the file and repeat it inside the picture data instead, which is allowed, and Lagoon was reading only the first place. It could not set up a decoder, so it fell back on asking your server to convert the film, which is slow and looks worse than the file you already own. Lagoon now reads the second place too.",
                    "Nothing about this was visible while it happened. Every other tool reads that information from inside the picture data, so the file looked perfectly healthy on your server and in any other player, and the failure looked like your Apple TV refusing the film rather than the file being described oddly.",
                    "If a title has been converting for no obvious reason, it is worth another try.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "65",
            released: "August 2026",
            headline: "A film your server has to convert now keeps playing instead of stalling every few seconds.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "When Lagoon cannot play a file as it is and falls back on your server converting it, it now asks for that conversion at 1080p instead of at the film's full 4K. A server without dedicated video hardware manages roughly a third of the speed needed to keep up with 4K, which is why the fallback played for a second, stopped to buffer, played again and stuck. The same server produces 1080p comfortably faster than it needs to.",
                    "This only happens after Lagoon has already failed to play a file directly, which is rare. A title that plays normally is untouched, at 4K or otherwise, and nothing about direct playback changed.",
                    "Playback Details now names the delivery Lagoon settled on and what failed to make it settle there. Lagoon retries a broken film a different way and usually succeeds, which is the behaviour you want, but until now the reason it had to was thrown away the moment the retry worked. On an Apple TV there was then no way to find out what went wrong.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "64",
            released: "August 2026",
            headline: "Two new switches for chasing down a title that stutters or loses its sound.",
            sections: [
                ChangelogSection(category: .newFeatures, changes: [
                    "Settings, Playback Diagnostics has a new Buffer Transcoded Playback switch. When your server has to convert a film rather than send it as it is, Lagoon currently holds nothing back in reserve, so a slow moment on the network or the server reaches you as sound cutting out. Turning this on keeps a reserve. It is off by default and worth trying only on a title that misbehaves, because whether it helps is exactly what we are trying to find out.",
                    "Nothing here changes how a film plays unless you turn one of these on.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Playback Details now shows how many seconds of sound are waiting, not just how many pieces. A count near zero could mean either a starved film or a perfectly healthy one, which made the number useless for telling those apart.",
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
                    "Films with WMV3 video, or MP2 or Apple Lossless sound, now play as they are rather than being converted by your server first. Lagoon could always decode all three and simply never said so. MP2 is what DVD rips and recorded broadcasts usually carry, so those stop being converted for no reason.",
                    "Plain .wmv files are still converted. What changed is WMV3 video inside an mkv or an avi.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Opening Control Center in the middle of a film no longer blanks the television while it changes picture modes, once on the way in and again on the way out. Lagoon was handing the display back the moment anything appeared over playback, even though the film had not stopped. It now holds the mode until you actually leave.",
                    "Recent searches keep the title you looked for instead of every step on the way to it. Typing on a television happens one letter at a time and each letter ran a search of its own, so looking for Dune left d, du and dun in the row beside it. Searching for something again also clears up what earlier builds left behind.",
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
                    "Home has a Collections row, and a collection opens a page of everything in it, in the order the films came out.",
                    "Search finds collections as well as titles, so typing a franchise name reaches the franchise.",
                    "Collections holding nothing, or holding one title, are left out of both. A server invents a collection for a whole franchise the moment you own a single film from it, so most of what it lists is empty, and on the library this was built against that is 155 of 173.",
                    "The Collections row can be switched off in Settings, Home Rows, like every other row there.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Picking something out of one of the new Home rows opens it, rather than starting to play it there and then. The rows made of series behaved worse still: they answered a press with an error from your server, because a series is not a thing that can be played.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "61",
            released: "August 2026",
            headline: "Top Shelf artwork is kept where an Apple TV allows it.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Settings, Advanced puts the last result underneath the section instead of on one line, so a long reason is readable rather than cut off.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Lagoon was saving its Top Shelf pictures somewhere an Apple TV does not let apps keep things, so the last build drew all eight and then could not save any of them. They now go in the cache, which is where a television expects something it can rebuild.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "60",
            released: "August 2026",
            headline: "The Top Shelf artwork can be drawn on an HDR television.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "When something does go wrong, Settings, Advanced now names the step that failed rather than saying only that nothing could be built.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Lagoon was asking the television what kind of picture to draw, and on an HDR set the answer was one that cannot be saved as a JPEG. Every Top Shelf image failed at the last step, which is why the last build could fetch your titles and still show you nothing. Lagoon now picks the format itself.",
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
                    "Home has eight new rows. Because You Watched, named after the last thing you finished. Great Movies You Haven't Seen. Movies in 4K, which is the row for deciding what to put on the good television. A genre and a decade that change daily, drawn from what you actually watch. Series You Haven't Started, Ready to Binge for series that have finished airing, and Surprise Me at the bottom.",
                    "The new rows are all listed in Settings, Home Rows, and can be turned off individually like the existing ones.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "The rows are also in a different order. What you were watching comes first, then every movie row together, then every show row together, each run ending with its genre shelf. The genre shelves used to sit in the middle and interrupt, and movies and shows used to alternate.",
                    "Any row with too little behind it hides rather than showing you three posters and a lot of space, so a smaller library gets a shorter Home rather than a patchy one.",
                    "Settings, Advanced now also says when Lagoon last tried and how that attempt ended, so an empty shelf gives you a reason rather than four zeroes.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Lagoon was drawing all of its Top Shelf artwork on the same thread that runs the interface. On a Mac that finishes before you notice; on an Apple TV it is long enough to stall the app, which is why nothing ever reached the shelf. The drawing now happens out of the way.",
                    "If the Top Shelf has nothing on it, Lagoon now notices when you open the app and fills it in, instead of only ever doing so as a side effect of the Home screen loading.",
                ]),
            ]
        ),
        ChangelogEntry(
            version: "0.1",
            build: "58",
            released: "August 2026",
            headline: "Still chasing the Top Shelf.",
            sections: [
                ChangelogSection(category: .improvements, changes: [
                    "Settings, Advanced now reports what Lagoon has handed to the Home screen: how many titles, how much artwork, and when it last did it. If that says titles are published and the shelf still shows the Lagoon banner, the fault is not in the app.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "The Top Shelf did not appear in the last build, despite what its notes claimed. Lagoon now hands each title over as it is ready instead of all of them at once, so a slow or interrupted first run leaves you with the titles it managed rather than nothing at all.",
                    "Top Shelf artwork drawn by an older version of Lagoon is redrawn rather than kept, so upgrading no longer leaves you looking at the previous layout.",
                    "Continue Watching now updates when you come out of something you were watching. It used to wait until you left the Home screen and came back, so the row, and the Top Shelf with it, could still be offering you the episode you had just finished.",
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
                    "Put Lagoon in the top row of the Apple TV Home screen and what you were watching now fills the screen above it, up to eight titles you swipe through, each with its own artwork, a summary and how much is left.",
                    "Play picks up where you stopped. More Info opens the title in Lagoon instead, which is what the second button is for.",
                    "A part-watched episode says which episode it is, rather than only naming the series.",
                    "Titles carry their 4K, HDR, Dolby Vision and Atmos badges up there, the same ones the Apple TV app shows.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "The artwork is composed at the size a 4K television actually asks for, rather than a smaller image stretched to fit.",
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
                    "Search has a tab of its own. Discover used to open behind a full keyboard that took the top third of the screen, and now opens on artwork instead.",
                    "The Search screen remembers what you looked for, so searching for it again is one click rather than spelling it out on the keyboard a second time.",
                    "Discover opens on a hero banner and carries eight rows where it had four, including Upcoming Shows, your watchlist, and browsable movie and show genres. The rows follow the order your Seerr administrator arranged on their own Discover page, and each one opens a full list.",
                    "A request whose title has arrived opens straight into Lagoon to play it, instead of only offering to remove itself.",
                    "If you manage your Seerr blocklist, a blocked title can be unblocked from Lagoon rather than only from the web interface.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "A request that is downloading shows how far along it is and how long is left, and the icon animates while you are looking at it.",
                    "A request now shows the quality it will be fetched at, so approving one tells you what you are agreeing to.",
                    "Settings takes the app's own black background instead of the system's default grey.",
                    "This changelog is now a row per build that you open, rather than one long list to scroll.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Requests that are finished no longer claim to be pending. A request now says whether it is waiting for approval, downloading, importing, or ready to watch, and a title that was removed from your library says that rather than looking stuck.",
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
                    "Playback speed, from half to double, in the Video tab of the playback panel. Voices keep their pitch, and the speed you pick carries into the next episode.",
                    "Subtitles authored with a place on screen now appear where they were meant to, in their own colour, bold and italic, instead of being stacked at the bottom. That covers signs, captions over artwork, and two people talking at once.",
                    "10-bit AV1 and VP9 now play directly instead of being re-encoded by your server, up to 1080p on hardware with no AV1 decoder of its own.",
                    "MPEG-2 video, LPCM soundtracks and DVB subtitles play directly too, which covers most DVD rips and recorded television. Interlaced recordings still go through your server, because that is what deinterlaces them.",
                    "Stereo soundtracks now get Spatial Audio on AirPods, the way Apple's own player does.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Lagoon has a new look: a new app icon and Top Shelf artwork, and the mark now carries through the setup and sign-in screens instead of stopping at the home screen.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Starting another film after one failed no longer waits fifteen seconds to announce that the previous video could not release its player resources.",
                    "A film that fails also stops leaving your server working on a stream nobody is watching.",
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
                    "A film that won't play no longer ends at an error screen: Lagoon asks your server to send it another way and picks up where it stopped, without making the server re-encode unless nothing else works.",
                    "If the sound stops partway through a film, Lagoon rebuilds the audio and keeps playing rather than running on in silence.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "Pausing near the start of a film now buffers as far ahead as the cache allows, instead of stopping short of it.",
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
                    "When a subtitle download fails, Lagoon now shows the reason your server gave, such as an exhausted provider allowance, instead of guessing between causes.",
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
                    "If you administer your Jellyfin server, Lagoon no longer refuses to search for subtitles before it has even asked the server.",
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
                    "If your Seerr uses Jellyfin accounts, Discover now just works. There is no second login to type, since you are already signed in to Jellyfin.",
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
                    "Subtitles can be fetched straight from OpenSubtitles when your Jellyfin account isn't allowed to manage them. Add a key in Settings -> Subtitles.",
                    "This About screen, with a changelog.",
                ]),
                ChangelogSection(category: .improvements, changes: [
                    "Seerr requests are a poster grid, and opening one gives a proper page with the actions that apply to it.",
                    "Build numbers now come from the project rather than being assigned at upload, so builds between 1 and 50 predate this list and aren't itemised.",
                ]),
                ChangelogSection(category: .bugFixes, changes: [
                    "A long film no longer starts stuttering partway through: the disk buffer now travels with the playhead instead of filling up and giving out.",
                    "Subtitle failures say what actually went wrong, whether that is a missing server permission, an expired session or a timeout, rather than always blaming the provider.",
                    "Subtitles that aren't UTF-8 now decode by language instead of rendering as garbage.",
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
                    "A playback engine of Lagoon's own: libavformat demuxing straight into AVSampleBufferDisplayLayer, with no AVPlayer in the path.",
                    "Direct play for H.264, HEVC, VC-1, MPEG-4 Part 2 and anamorphic sources, so far fewer titles fall back to transcoding.",
                    "HDR10 and Dolby Vision with tvOS display-mode matching, plus Dolby Digital, Atmos and TrueHD passthrough.",
                    "Embedded PGS, VobSub and text subtitles, external sidecars, and provider search when a title has none.",
                    "Trickplay scrubbing, intro and recap skipping, and autoplay into the next episode without leaving the player.",
                    "Direct-play files buffer ahead of the playhead over HTTP range requests.",
                    "Home rails, genre discovery, library browsing, search and a Top Shelf extension.",
                    "Seerr: browse, request and manage requests from inside the app.",
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
