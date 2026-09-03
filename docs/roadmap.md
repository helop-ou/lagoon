# Roadmap

What Lagoon does today and what comes next, at the level of a viewer or a
release note. Jira (Labs epic HEL-15 on helop-ou.atlassian.net) is
canonical for ticket status, `Lagoon/Models/Changelog.swift` for what
shipped in which build, and `docs/playback.md` for how the engine works.
Last brought up to date 2026-09-03, at 0.1 (86).

## Shipped

### MVP (August 2026)

- Connect to a Jellyfin server (schemeless input, https/http/:8096 probing)
- Sign in with password or Quick Connect; keychain-persisted session
- Home: hero carousel with ambient glow, Continue Watching, Next Up,
  Recently Added per library
- Dynamic library tabs (Movies / Shows), paged 6-column poster grids
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
(HEL-64); software-decoded HDR shown as SDR on tvOS, converted on the
GPU. Atmos/TrueHD/E-AC-3 passthrough, DTS/TrueHD/FLAC/Opus/PCM decoded
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
with provider search and OpenSubtitles direct fetch, non-UTF-8 decoding,
and on-screen positioning (M5).

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

## Next

In the order they are worth doing. Keys are Jira tickets.

1. **Server sync** (HEL-135): the app is sometimes visibly behind the
   server; decide between a refresh affordance on Home and refreshing on
   foreground and after playback. Re-check first: HEL-132 removed two
   general causes of "sometimes" — API responses served from the URL
   cache, and item equality by id, which let SwiftUI skip re-rendering
   rails whose ids had not changed.
2. **Jellyfin 10.12** (HEL-138): a scoping pass against a 10.12 server
   before fixture upgrades.
3. **Live Seerr status** (HEL-136): download status and time estimates
   that update while a detail page is open, without hurting performance.
4. **iOS polish pass** (HEL-41): compact-width detail composition, hero
   sizing, touch-first rails, keyboard behaviour on onboarding; iPad in
   between. Only the collection page has its own iOS layout so far.
5. **1080i H.264 without a transcode** (HEL-127, remainder): hardware
   decode has no deinterlacing stage; needs a CVPixelBuffer-side pass and
   its own frame-loss measurement.
6. **Buffer on audio starvation by default** (HEL-123): the mode is built
   and switched off; the `aDry` counter in Release decides whether real
   delivery still reaches the floor now that HEL-124 is in.
7. **Live TV**, if the server has it: guide and channels. A big lift with
   no ticket yet.

**Blocked upstream.** A server-wide Top 10 (HEL-121) needs a Streamystats
endpoint that does not exist; a personal one was rejected on value.

## In verification

Waiting on a TestFlight or hardware look rather than on code: 4K AV1
frame rate (HEL-137), the audio starvation signal and its fix (HEL-123,
HEL-124), the transcode cache switch (HEL-130), interlaced MPEG-2 on an
Apple TV (HEL-127), the recent-searches row (HEL-129), the iOS cellular
cap (HEL-108), the detail page turning Play into Resume after playback
(HEL-132), and a light Siri Remote touch-surface tap revealing the player
transport without changing playback (HEL-134).

## Deliberate non-goals for now

- Offline downloads. HEL-86's playback cache is transient, discardable on
  player exit, and deliberately cannot become saved media.
- A personal most-watched row (HEL-121): your own history read back to
  you.
- A second player path. AVPlayer and mpv were removed rather than kept in
  parallel (HEL-48), and MPVKit is only the source of the pinned FFmpeg
  artifacts.
