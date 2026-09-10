# Roadmap

What Lagoon does today and what comes next, at the level of a viewer or a
release note. Jira (Labs epic HEL-15 on helop-ou.atlassian.net) is
canonical for ticket status, `Lagoon/Models/Changelog.swift` for what
shipped in which build, and `docs/playback.md` for how the engine works.
Last brought up to date 2026-09-07, at repository version 0.1 (90).
Builds 89 and 90 have release notes and verified simulator builds; this does
not confirm a TestFlight upload or physical-device acceptance.

## Implemented

### MVP (August 2026)

- Connect to a Jellyfin server (schemeless input, https/http/:8096 probing)
- Sign in with password or Quick Connect; keychain-persisted session
- Home: hero carousel with ambient glow, Continue Watching, Next Up,
  Recently Added per library
- Movie/show libraries with paged poster grids, initially in separate tabs
- Movie/episode and series detail pages (seasons, episode rail)
- Playback with resume and progress reporting
- Debounced search, settings (sign out / change server)
- iOS builds from the same target with scaled-down metrics

### Since the MVP

**Player.** One engine for everything (HEL-48): libavformat demux, codec
stages, the AVSampleBuffer presentation APIs; the AVPlayer and mpv paths
are gone. Hardware HEVC/H.264 and, where the silicon has it, AV1; software
AV1 through a dav1d built by this repo (HEL-137), plus VP9, VC-1, MPEG-4
Part 2 and MPEG-2 in software with local deinterlacing for MPEG-2
(HEL-127, half). HDR10, HDR10+ and Dolby Vision with display-mode matching
(HEL-64); profile 7 remuxes are converted to profile 8.1 live rather than
falling back to HDR10 (HEL-145); software-decoded HDR shown as SDR on
tvOS, converted on the GPU. Atmos/TrueHD/E-AC-3 passthrough,
DTS/TrueHD/FLAC/Opus/PCM decoded
locally, Spatial Audio for stereo. Blu-ray and DVD images play natively
with their original audio (HEL-133). A delivery ladder that falls from
direct play to remux to transcode on failure, by cause (HEL-100), with a
1080p ceiling on the re-encode rung. A bounded playback cache behind
direct play (HEL-86, HEL-130). Compressed video read-ahead so remuxed and
transcoded titles keep their sound (HEL-124), and a renderer-side audio
starvation signal in the overlay (HEL-123). Trickplay scrubbing, chapter
markers, intro/recap skip, autoplay next episode, playback speed, picture
in picture, Now Playing and remote integration (HEL-80). A metered-path
bitrate cap on iOS (HEL-108).

**Subtitles and audio.** Audio and subtitle track pickers over the
server's streams; embedded text, PGS, VobSub and DVB; external subtitles
with provider search, non-UTF-8 decoding, and on-screen positioning (M5).

**Home and browsing.** Top Shelf with Continue Watching, published
incrementally (HEL-31, builds 57–61). Curated Home rows: Because You
Watched, 4K, genres and decades. Collections as a row and a page
(HEL-122). Search on its own tab with recent searches (HEL-129). Favorites
and played/unplayed from context menus and the detail action row.

**Accounts.** User switching and multiple servers through an account
picker (HEL-38), with per-account keychain sessions.

**Seerr.** Discovery with a hero rail, title and season requests, request
history and progress, permission-gated moderation, Jellyfin SSO and
per-user Quick Connect.

**Settings.** About with the changelog and the installed build badged
(HEL-94). Playback Diagnostics: the details overlay, the frame-loss bench,
and the decoder switches that hardware questions get answered with.

### September 7 browsing and iOS pass (builds 89–90)

**Unified Library (HEL-140).** Home, Discover, Library, Search, and Settings
are five stable tabs. Library combines movies and shows with server-side
sorting and library, genre, decade, unwatched, favorites, and 4K movie filters.
Decades follow the library's year catalogue rather than a hardcoded list;
redundant source selectors stay hidden. Choices are remembered per account.
tvOS uses five poster columns; iOS adapts its grid to width and text size.

**Home and Discover.** Featured banners support native swipe paging on iOS
and Left/Right navigation on tvOS, keeping tap/select for details. Rotation
pauses during interaction and selection survives refreshes. Next Up excludes
started episodes; Recently Added shows resolves new episodes to their parent
series. Long tvOS genre names are centered and wrap onto two lines.

**Search and Seerr.** Both library and Seerr search offer See All and paginated
full results. Changing the query clears stale matches. Partially available
Seerr titles can open their matching item in Lagoon.

**iOS layout and controls (HEL-41).** Shorter landscape hero banners, roomier
rows, larger posters, adaptive grids and detail actions, and display-scale
artwork. Episode taps open details; seasons use a native picker. The player
uses native toolbar actions and a resizable options sheet, with adjustable
VoiceOver seeking. Home Rows uses native toggles and Edit/reorder.

**Settings and accounts.** iOS settings now opens separate category pages,
matching the organisation on tvOS. Native onboarding fields use lighter
styling and keyboard submit actions. Add Account starts on the current
server, offers Use Another Server, and leaves the active Jellyfin and Seerr
sessions intact until a new account is verified. System-managed subtitle
appearance hides Lagoon controls that would have no effect.

## Toward 1.0

What 1.0 still owes, functionally and as release gates, in the order they
are worth doing (decided 2026-09-10). Keys are Jira tickets; the two audit
tickets hold the detailed acceptance lists so they are not repeated here.

1. **Touch player controls on iPhone and iPad** (HEL-153). The iOS player
   has a top bar with Close, Info and Play/Pause, a tap to show the
   controls, a drag scrubber and Picture in Picture inside the panel, and
   nothing else by gesture. 1.0 needs the grammar every phone player has:
   a large centred play/pause with 10 s back and forward beside it,
   double-tap on either half of the picture to seek, landscape lock while
   playing, the mute switch and volume keys respected, trickplay thumbnails
   while scrubbing by touch, Skip Intro and Up Next tappable, and Picture
   in Picture when leaving the player as the phone's popup behaviour. An
   in-app mini player is a 1.1 idea.
2. **Physical-device acceptance** (HEL-144, with HEL-41 for iPhone/iPad):
   the audit's matrix on real hardware — iPhone and iPad touch, rotation,
   keyboards, VoiceOver, large text, interruptions and the lock screen,
   AirPlay to a receiver, Picture in Picture captions, and a full film with
   captions on watched on the Apple TV from a TestFlight build, which is
   what retires HEL-148 for good. The iPad layout has never been looked at
   on a device.
3. **App Store preparation** (HEL-143): privacy nutrition labels, the
   privacy policy and support URLs, review notes with a demo server and
   account, the export-compliance answer for the FFmpeg build (HTTPS only,
   through URLSession), the age rating, and a signed archive checked before
   upload.
4. **Known defects to close first**: the outgoing engine retained across an
   episode handoff (HEL-152), a slow creep over a binge rather than a crash.
   The subtitle-over-HDR frame drops (HEL-148) are better but not zero and
   can ship as they are, with the ticket open.
5. **The website** (`../lagoon-website`, HEL-143): screenshots of both
   platforms in the current design, the privacy policy page App Store
   Connect links to, a support/contact page, the App Store or TestFlight
   link, and a short setup page covering the three questions the app already
   answers in-line — server address and proxy paths, the subtitle-search
   permission, and captions appearance following system settings. The
   non-goals below make a good "what Lagoon is not" paragraph.

## Next

After 1.0, in the order they are worth doing. Keys are Jira tickets.

1. **1080i H.264 without a transcode** (HEL-127, remainder): hardware
   decode has no deinterlacing stage; needs a CVPixelBuffer-side pass and
   its own frame-loss measurement.
2. **Live TV**, if the server has it: guide and channels. A big lift with
   no ticket yet.
3. **A route-loss main-thread block** (follow-up to HEL-149): removing
   AirPods while paused blocked the main actor for 862 ms in the trace;
   the AirPods gap itself measured as a two-second re-prime on connect while
   playing and nothing while paused, so no new route path is planned.
4. **An in-app mini player on iPhone** once HEL-153's Picture in Picture on
   exit has been lived with.

A post-1.0 idea worth tracking: a Lagoon server plugin exposing fetch-only
subtitle search to accounts without `EnableSubtitleManagement`, so an
administrator would not need to grant those accounts library writes just to
let them search for subtitles. No ticket yet.

**Blocked upstream.** A server-wide Top 10 (HEL-121) needs a Streamystats
endpoint that does not exist; a personal one was rejected on value.

## In verification

The Library and iOS work above was checked in simulators on 2026-09-07,
including portrait/landscape layouts, large text on iPhone, and Home/Discover
hero paging, details, and back navigation on iOS and tvOS. Unit tests and
both platform builds pass. These checks do not replace iPad and physical-device
validation or change Jira status automatically.

HEL-137 (4K AV1 frame rate) and HEL-123 (audio starvation) were accepted by
Jaagop and moved to Done on 2026-09-07.

Waiting on a TestFlight or hardware look rather than on code: the audio
refill fix (HEL-124), the transcode cache switch (HEL-130), interlaced MPEG-2 on an
Apple TV (HEL-127), the recent-searches row (HEL-129), the iOS cellular
cap (HEL-108), the detail page turning Play into Resume after playback
(HEL-132), the Dolby Vision profile 7 → 8.1 conversion (HEL-145, waiting on
an Apple TV reporting Dolby Vision and a rerun of the frame-loss bench
against the converted path), and both halves of HEL-134: the light Siri
Remote touch-surface tap
that reveals the player transport, shipped in 0.1 (87), and the further tap
that swaps remaining time for the clock time playback will finish, in 0.1 (88).
Seerr media and request details refresh pending approval every 30 seconds and
active download/import progress every 10 seconds while visible and foregrounded
(HEL-136); that one was verified against a live Jellyseerr on 2026-09-04 and is
closed.

The browse-refresh work (HEL-135) shipped in 0.1 (87) and is here rather than
under *Next*: a code review on 2026-09-04 found three defects, all now fixed
and covered by tests, so what it owes is a look on a device rather than more
code. Jellyfin 12 compatibility (HEL-138) also shipped in 0.1 (87), and its
app-level regression against the 12.0.0 preview was run on 2026-09-04: direct
play authenticates, negotiates and sustains, and the transcode credential
chain was verified hop by hop at the protocol level. What it still owes is the
deployment check on fixture once that server upgrades, so it waits here.

## Deliberate non-goals for now

- Offline downloads. HEL-86's playback cache is transient, discardable on
  player exit, and deliberately cannot become saved media.
- A personal most-watched row (HEL-121): your own history read back to
  you.
- A second player path. AVPlayer and mpv were removed rather than kept in
  parallel (HEL-48), and MPVKit is only the source of the pinned FFmpeg
  artifacts.
- A direct subtitle provider inside the app, removed in HEL-146: OpenSubtitles'
  REST terms require one API key per application and ban apps that ask users
  to supply their own, which is what the shipped per-device-key design did.
