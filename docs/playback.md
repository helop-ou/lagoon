# Playback

**One engine for everything** (Jaagop's call, 2026-08-16, HEL-48): all
playback runs through the Lagoon sample-buffer engine. The AVPlayer and mpv
players were removed the same day the decision was made — no split paths,
no per-container routing. Since 2026-08-17 (M6) the FFmpeg libraries come
from the local `Packages/LagoonFFmpeg` package, which pins the four
Libav* static xcframeworks from MPVKit's 1.0.0 release (FFmpeg 8.1.2)
plus the static libs FFmpeg's build references (gnutls/nettle/hogweed/gmp
for TLS, dav1d, uavs3d, lcms2) — MPVKit itself, libmpv, MoltenVK, and
libplacebo are no longer in the project. The archives are static: the app
binary links only referenced objects, and the bundle embeds 11 framework
shells instead of 27.

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.lagoon` — a
   capability profile mirroring exactly what the engine can play: h264/hevc
   video with aac/mp3/ac3/eac3 (passthrough) plus dts/truehd/flac/opus/
   vorbis (libavcodec-decoded, M4) audio in mkv/webm/mp4/m4v/mov, embedded
   text/PGS subtitles and external vtt (M5), plus an fMP4 HLS transcoding
   profile whose output (hevc/h264 + eac3,ac3,aac) lands back inside the
   same envelope. The server does the deciding.
2. Pick the first `MediaSource` and resolve a URL via
   `JellyfinClient.streamURL`:
   - `SupportsDirectPlay` → `Videos/{id}/stream?static=true&mediaSourceId=…`
     (+ `api_key`, `deviceId`, `Tag`), PlayMethod `DirectPlay`.
   - else `SupportsDirectStream` → `Videos/{id}/stream.{container}` with the
     same static query, PlayMethod `DirectStream` (server-must-proxy case;
     container can arrive as an ffprobe list — take the first entry).
   - else the server-provided `TranscodingUrl` (server-relative with its own
     query string — resolve against the server URL, don't rebuild it),
     PlayMethod `Transcode`. libavformat's HLS demuxer reads the fMP4
     playlist; the video-copy variant is listed first in the master.
3. The engine plays it. Jellyfin's HLS playlists cover the full duration,
   so resume is handled the same way as direct play: an initial demuxer
   seek, keeping position reporting absolute in every play method.

## The engine (`Lagoon/Views/Player/SampleBuffer/`)

libavformat demux → **compressed** `CMSampleBuffer`s →
`AVSampleBufferDisplayLayer` + `AVSampleBufferAudioRenderer` under an
`AVSampleBufferRenderSynchronizer`. The system does decode, color
management, and audio output — the Infuse architecture (HEL-48), which is
why nothing here touches VideoToolbox sessions or shaders directly.

- **Why packets pass through untouched**: Matroska stores h264/hevc
  mp4-style (avcC/hvcC extradata + length-prefixed NALs), so demuxed
  packets wrap directly as compressed sample buffers and the display layer
  decodes them. CoreAudio likewise decodes compressed aac/mp3/ac3/eac3
  handed to the audio renderer (ac3/eac3 self-describing; aac needs its
  AudioSpecificConfig as the magic cookie; mp3 is 1152 frames/packet).
  The CoreMedia block retains the packet's underlying `AVBufferRef` with
  `av_buffer_ref` and releases that reference after decode, avoiding both a
  packet-structure clone and a second allocation/full payload copy for every
  compressed packet. Packet pts/dts/duration are converted to `CMTime` in the
  stream's exact rational time base rather than round-tripping through
  floating point and a fixed 90 kHz scale.
- **Audio decode** (M4): codecs CoreAudio won't take compressed
  (DTS, TrueHD, FLAC, Opus, Vorbis — anything with an FFmpeg decoder)
  go through `AudioDecoder`: libavcodec → swresample → interleaved
  Float32 LPCM sample buffers, coalesced to ~2048-sample chunks because
  TrueHD frames are 40 samples each. swresample writes directly into the
  growable coalescing allocation, which is reused across chunks, so the
  per-decoded-frame temporary allocation and append copy are both gone; the
  chunk itself is then copied into a CoreMedia-owned block at emit (see
  "Do not make the LPCM emit zero-copy" below — the handoff that avoided
  this copy leaked the decoded stream).
  FFmpeg's native channel-bit order
  matches CoreAudio's channel bitmap bit-for-bit on the first 18
  positions, so a native layout mask maps straight across into the
  `AudioChannelLayout`. The E-AC3 (JOC/Atmos) path deliberately stays
  compressed passthrough. Platform limit stands: TrueHD Atmos objects
  are unpreservable — TrueHD plays as lossless multichannel LPCM.
- **Atmos from E-AC3 JOC — the recipe** (M2, settled on real hardware
  2026-08-17 after three failed attempts): when FFmpeg reports
  `AV_PROFILE_EAC3_DDP_ATMOS`, the format description must use the
  **`'ec+3'` media subtype** (Apple's "Enhanced AC-3 with JOC"; no
  public constant) with **`mChannelsPerFrame = 16`** (the HLS
  `CHANNELS="16/JOC"` presentation), plus the synthesized `dec3` box
  (ETSI TS 102 366 Annex F) as magic cookie + extension atom. Things
  that do NOT work: plain `ec-3` passthrough, an
  `kAudioChannelLayoutTag_Atmos_9_1_6` channel layout (alone or
  combined with `ec-3` + dec3) — those decode only the DD+ core and
  report "Multichannel". Verified: Samsung soundbar Atmos handshake +
  "Dolby Atmos" in the AirPods submenu.
  **Timing gotcha**: successive LPCM buffers anchor to the sample-exact
  end of the previous one (stamped at the stream's own sample rate) and
  re-anchor to container pts only on >50 ms jumps — Matroska stamps at
  1 ms precision (TrueHD frames are 0.83 ms) and 90 kHz can't represent
  48 kHz boundaries, and either mismatch renders as steady clicking.
- **Subtitles** (M5): rendered as a SwiftUI overlay, never through the
  renderers. Embedded streams decode via `avcodec_decode_subtitle2`
  (normalizes srt/ass/ssa/mov_text to ASS event payloads — text is
  everything past the 8th comma, `{\…}` override tags stripped — and
  PGS/VobSub to paletted rects converted to CGImages, positioned on the
  codec's graphics plane). External Jellyfin streams (vtt delivery)
  download and parse into the same cue store. Every subtitle stream is
  listed even if undecodable so per-type ordinals stay aligned with the
  server's stream list; external tracks append after embedded ones and
  the controller maps `DefaultSubtitleStreamIndex` into that combined
  space. Selecting an embedded track re-demuxes from the current
  position (same trick as audio switching) so the active line appears
  immediately; PGS cues are open-ended and close on the next
  composition event. Not covered: subtitles during HLS transcode (the
  vtt-over-HLS playlist is not read).
- **Threading**: the demux loop runs on a serial queue feeding two
  condition-protected sample-buffer queues; renderer pumps drain them via
  `requestMediaDataWhenReady`; state and transport live on the main actor.
  Independent video/audio high-water marks apply hysteretic backpressure and
  wake the producer when consumers cross their low-water marks, so a full
  queue blocks without polling or arbitrary sleeps.
- **Seeks** stop the clock, flush renderers and queues, `av_seek_frame`,
  re-prime (~12 video buffers), then restart the synchronizer at the
  target. Resume is the same path with the start position.
- **Audio tracks**: listed from the demuxer (per-type 1-based ordinals —
  the same convention the server's `DefaultAudioStreamIndex` maps to);
  switching re-demuxes from the current position with the new stream
  selected and the rest discarded inside libavformat.
- **HDR/DoVi tagging** (M3): the video format description carries
  colorimetry extensions (primaries/transfer/matrix/range/chroma siting
  from codecpar) plus HDR10 static metadata (mdcv/clli payloads rebuilt
  big-endian from FFmpeg side data) — that's what makes the display
  pipeline engage HDR/EDR instead of rendering BT.2020+PQ as washed-out
  SDR. Dolby Vision: profile 5 becomes a `dvh1` sample entry with a
  `dvcC` atom (IPTPQc2 is unwatchable without the DoVi path), profile 8
  stays `hvc1` plus supplementary `dvvC` (non-DoVi displays fall back to
  the base layer's HDR10/HLG tags), dual-layer profiles 4/7 get no atom
  and play as HDR10 from the base layer. Profile 7
  (`DOVIWithEL`/`DOVIWithELHDR10Plus`) **direct-plays** on that basis:
  the BL is plain Main 10 HDR10(+), the EL NALs are unspecified types
  the decoder ignores, and tvOS can't reconstruct dual-layer DoVi anyway
  — same presentation as the server's strip-to-HDR10 transcode without
  the lossy re-encode. Hardware verification pending (the simulator has
  no HDR output; DoVi P5 may not decode in the sim at all).
- **Stall recovery** (M6): when the clock catches up to the last
  delivered video pts with a dry queue and the file isn't over, the
  engine holds the synchronizer (buffering spinner) and auto-resumes
  once ~12 buffers rebuild. `av_read_frame` distinguishes `AVERROR_EOF`
  from read failures — transient errors retry briefly, persistent ones
  surface as the error overlay instead of fake-finishing the file (which
  would have moved the server resume point). At real EOF the audio
  decoder drains its coalescing tail. In HLS masters the working set is
  restricted to the chosen video's program, so other variants never
  download segments or duplicate the track list.
- **Audio delay** (M6): mpv convention, positive delays audio; applied
  by re-stamping buffers at enqueue (`CMSampleBufferCreateCopyWithNewTiming`)
  and re-demuxing from the current position on change. Lives in the
  Audio tab's OPTIONS column.
- **HEL-48 closed 2026-08-17**: all engine milestones (M1–M6)
  hardware-verified end-to-end — direct play, Atmos (recipe above),
  HDR/DoVi presentation, DTS/TrueHD multichannel, subtitles, Menu/panel
  policy. Accepted platform limits: TrueHD Atmos objects unpreservable
  on tvOS; no subtitles during HLS transcode. Transport UX work
  (scrubbing/trickplay/motion) continues on HEL-39.

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player showing
the negotiated method/container/codecs/range/bitrate plus live engine state
refreshed every 2 s. Ships in **all** builds, TestFlight included — real
Apple TV hardware only ever runs Release; defaults off
(`debug.playbackHUD`, read once at playback start).

HEL-56 adds two live diagnostic lines to that HUD: renderer queue depths +
stall count, and AVFoundation's total/dropped/corrupted frame counters. The
same build emits `PlaybackPerformance` signposts for controller startup,
playback cushion readiness, stalls, dismissal-critical main-actor work, renderer
teardown, demux close, the stopped-report request, and every increase in the
dropped/corrupted-frame counters. Frame-loss events include the delta, playback
position, queue depths, and stall count so a hardware trace can distinguish
decoder pressure from starvation without a screen recording. Capture those
with the Instruments **Points of Interest** template on real Apple TV hardware;
the signposts intentionally ship in Release/TestFlight.

Memory is sampled alongside them: the HUD carries a `Memory:` line (footprint
plus remaining headroom from `os_proc_available_memory()`, which reads 0 in the
simulator and reports real headroom on device), and the progress loop emits a
`Playback Memory` signpost every 10 s with both figures and the playback
position. Watch the footprint's *slope*, not its absolute value — a leak is a
straight line that never plateaus, and it is the one playback failure that
leaves no crash trace, because jetsam writes a `JetsamEvent` report instead.
Anything above roughly 0.2 MB/s sustained over a few minutes needs explaining;
see the note under the renderer feed below for the one that shipped.

The renderer feed is kept cheap under high-bitrate load: packet wakeups are
coalesced onto a user-interactive serial pump, and the app-side sample FIFO is
head-indexed/amortized O(1) rather than shifting its whole Swift array for every
frame. The demuxer blocks on condition-driven video/audio high-water marks and
resumes at lower thresholds instead of polling queue counts, and compressed
payloads retain FFmpeg's existing backing buffer (`av_buffer_ref` behind a
`CMBlockBufferCustomBlockSource`) instead of being copied per packet. Decoded
LPCM coalesces into a reused `NSMutableData` that swresample fills in place,
then **is copied** into a CoreMedia-owned block at emit. These optimizations
reduce Lagoon's packet-copying, allocation, scheduling, and ARC overhead;
AVFoundation's hardware decoder remains responsible for codec decode.

**Do not make the LPCM emit zero-copy.** HEL-58 originally handed that
`NSMutableData` to CoreMedia behind a custom block source, and the free
callback never ran: the app leaked the entire decoded audio stream —
~2.2 MB/s on TrueHD 7.1 — and jetsam killed it for `per-process-limit` at
2100 MB partway through a movie, with a `JetsamEvent` report rather than a
crash trace. The copy that bought back is 1.5 MB/s on the demux queue,
roughly 0.03% of a core, and cannot reach the render path: a matched pair of
6.5-minute 4K/TrueHD runs measured 2 dropped frames out of ~9300 either way,
0 stalls, with footprint going 131 → 113 MB fixed versus 225 → 1003 MB
leaking. The compressed video handoff uses the same block-source pattern and
is measured leak-free, so the pattern itself is fine — only the LPCM use of
it regressed. It was isolated by playing one file twice and switching only
the audio track (TrueHD vs AC-3), which holds the video path constant; that
is the fastest way to attribute a playback leak to audio or video.

Player exit is deliberately two-phase (HEL-57). The main actor cancels the
clock/observer and interrupts FFmpeg, then renderer stop/flush, queued sample
release, and renderer removal are serialized on the existing pump queue.
FFmpeg codec/decoder wrappers are released by `FFmpegDemuxer.close()` on the
demux queue. This prevents dismissal from paying for hundreds of queued
media-buffer releases or C decoder destruction. `Sessions/Playing/Stopped`
still reports exactly once from the controller after the engine position is
captured; network reporting never gates UI dismissal.

## Progress reporting

Positions are ticks (see jellyfin-api.md). Three report points, all fire-
and-forget (`try?` — reporting must never interrupt playback):

- `Sessions/Playing` once playback starts.
- `Sessions/Playing/Progress` every 10 s from a detached loop, including
  `IsPaused` from the engine.
- `Sessions/Playing/Stopped` exactly once from `stop()` (guarded by
  `didReportStop`), called on dismiss. This is what moves the server-side
  resume point and reorders Continue Watching.

Detail screens re-fetch the item in `fullScreenCover`'s `onDismiss`, and
HomeView re-fetches its Resume/Next Up rails in `onAppear`, so the UI
reflects the new position immediately.

## Player view gotchas (learned the hard way on tvOS)

- The custom player UI (`CustomPlayerView`) talks **only to the
  `PlayerEngine` protocol** — engine internals must never leak into it.
- Focus invariants: the video surface is focusable at **all** times (Menu
  would quit the app from an unfocusable screen).
- **Scrub grammar** (HEL-39 slice 2): while *playing*, tvOS arrows are
  ±10 s seeks; while *paused* they walk a virtual playhead (`scrubTarget`)
  that only lands when Select or Play/Pause commits it — and committing
  resumes playback, the native tvOS grammar. Menu cancels back to the live
  position, so it now outranks close-the-panel in `MenuPressGate`'s policy.
  Sustained walking accelerates 10 → 30 → 60 s, and the run resets after
  600 ms of quiet. Mid-scrub, up/down hop chapters (slice 3) — everywhere
  else down still opens the panel, which is why the hop is scoped to scrub
  mode: opening the panel mid-scrub would strand the virtual playhead
  behind it. Backwards hops land on the current chapter's start first, the
  way track skip-back does. iOS instead drags the bar directly and seeks on
  release only — seeking per drag update would flush the renderers and
  re-demux on every frame of the gesture.
- **Trickplay** (slice 3, Jellyfin 10.9+): `BaseItemDto.Trickplay` is
  `[mediaSourceId: [width: TrickplayInfo]]`, and its `Interval` is
  **milliseconds**. Sheets come from `Videos/{id}/Trickplay/{width}/{n}.jpg`
  — one sprite sheet per `TileWidth × TileHeight` grid of thumbnails, so
  the default 10×10 at 10 s covers ~16 minutes each. Two gotchas: unlike
  `Items/…/Images/…` this route **401s without credentials**, so the URL
  carries `api_key` the way stream URLs do; and a sheet is ~23 MB decoded,
  which is why `TrickplayLoader` holds its own two rather than going
  through `ImageCache` (one scrub would evict every poster). Tile crops are
  derived from the *decoded* sheet's size, never the declared numbers — the
  decode caps sheets at 3200 px, and the last sheet of a film is only
  partially filled, so its height isn't `rows` tiles.
- Chapters and trickplay are fetched by the player itself
  (`playbackExtras`, concurrent with the PlaybackInfo negotiation), not
  taken from the `MediaItem` it was handed: playback starts from rails too,
  and their list requests don't carry those fields. Both degrade to
  nothing — no ticks, no preview — on servers that never generated them.
- A faded-out overlay **still hit-tests**: the transport gates
  `allowsHitTesting` on its own visibility, or the invisible iOS scrubber
  swallows drags meant for the video. tvOS keeps the whole transport
  non-hit-testable — Select goes to the focused surface, and anything else
  down there steals it.
- **SwiftUI's `onExitCommand` never fires inside a fullScreenCover on
  tvOS 26** — arrows and play/pause reach SwiftUI, but UIKit's
  presentation controller consumes Menu and dismisses the cover directly,
  and `interactiveDismissDisabled` doesn't gate it (verified with
  instrumented handlers). `MenuPressGate` owns the policy: panel open →
  close panel, else → explicit dismiss. **It needs BOTH interception
  layers**: a real Siri Remote `.menu` press is eaten by UIKit's
  dismissal *gesture recognizer* before press delivery reaches any
  responder — only our own `UITapGestureRecognizer` with
  `allowedPressTypes = [.menu]` inside the hierarchy preempts it (found
  on hardware: responder-chain overrides alone let Menu kill the whole
  player) — while the simulator's keyboard Escape arrives as a keyboard
  press (type = 2000 + HID usage, never `.menu`) that no recognizer
  matches, so the `pressesEnded` override must catch
  `key?.keyCode == .keyboardEscape`. Sim-only testing exercises only the
  second path; hardware exercises only the first.
- `defaultFocus` is only honored when a fresh scene appears — any
  mid-screen reveal must assign its `@FocusState` programmatically
  (immediately, plus a settled retry) or focus strands.
- **Nothing that *appears* inside the player can animate — animate values
  instead.** The animation transaction doesn't survive the `MenuPressGate`
  hosting boundary (state lives outside the `UIHostingController`, updates
  cross via `rootView` reassignment), so `withAnimation` lands instantly.
  Value-driven `.animation(_, value:)` in the hosted tree *does* work, which
  covers opacity, offset, and asymmetric timing via a target-state-conditional
  animation argument.
  **Transitions are the trap**: `.transition()` on a conditionally-inserted
  view has no value to hang an animation on at the moment of insertion, so it
  never runs no matter how it's wrapped. Two fixes were tried and *both
  failed* — `.animation(_, value:)` on a `Group` around the `if` (2026-08-17,
  believed fixed but wasn't), and forwarding `context.transaction` around the
  `rootView` assignment. Frame-by-frame capture settled it: the panel still
  appeared whole between two frames 0.04 s apart. The panel now stays mounted
  permanently and slides via `.offset` + `.opacity`, `.disabled(!panelOpen)`
  keeping its buttons out of the focus engine while closed.
  **Verify animations by recording, not screenshots**: `simctl io recordVideo`
  then step frames out with `AVAssetImageGenerator` — a screenshot lands after
  a 0.4 s animation has finished and tells you nothing.
- Never nest `SharedState.withLock` (non-recursive lock — nesting was the
  engine's first real deadlock). `sample <pid>` on the host names the
  exact stuck line when a queue wedges.
- Native buttons only; never draw custom chrome tied to focus — the system
  lozenge is the design (see the Infuse reference on HEL-35).
- On failure the engine is set to **nil** and replaced with an error
  overlay carrying a Back button and `.onExitCommand` — a dead surface
  would swallow the Menu press and trap the user.
- The loading state is `LoadingView` (focusable) for the same Menu-button
  reason as everywhere else.
- tvOS does not restore focus to the presenting screen after the player
  cover dismisses (custom focusable content inside) — every screen that
  presents the player wraps in `.restoresFocusAfterPlayer(isPresented:)`
  (`FocusRestoration.swift`: focus scope + `resetFocus` timed past the
  dismissal transition).
