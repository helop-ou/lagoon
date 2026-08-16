# Playback

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.native` — a
   capability profile describing what AVPlayer handles natively: direct play
   for mp4/m4v/mov with HEVC/H.264 + AAC/AC3/EAC3/FLAC/ALAC audio, and an
   fMP4 HLS transcoding profile for everything else (MKV, unsupported
   codecs). The server does the deciding.
2. Pick the first `MediaSource` and resolve a URL via
   `JellyfinClient.streamURL`:
   - `SupportsDirectPlay` → `Videos/{id}/stream?static=true&mediaSourceId=…`
     (+ `api_key`, `deviceId`, `Tag`), PlayMethod `DirectPlay`.
   - else `SupportsDirectStream` → `Videos/{id}/stream.{container}` with the
     same static query, PlayMethod `DirectStream`. Same bytes, but the server
     must proxy them (remote/.strm sources, static-bitrate limits); local
     library files that pass the profile carry both flags and take the
     DirectPlay branch. The container can arrive as an ffprobe list
     ("mov,mp4,m4a") — take the first entry.
   - else the server-provided `TranscodingUrl` (arrives server-relative with
     its own query string — resolve against the server URL, don't rebuild
     it), PlayMethod `Transcode`.
3. AVPlayer plays it; Jellyfin's HLS playlists cover the full duration, so
   **resume is a client-side seek** rather than a `StartTimeTicks` offset —
   this keeps position reporting absolute in both play methods.

## Device profile (HDR & audio policy)

All of this is encoded in `DeviceProfile.native`
(`Lagoon/Networking/DeviceProfile.swift`) and was verified against a real
library on 2026-08-15/16 by probing PlaybackInfo responses, HLS playlists,
and fMP4 init segments (full matrix in the HEL-32/HEL-33/HEL-34 comments):

- **Direct play video is hevc, h264, mpeg4** — MPEG-4 Part 2 in mp4-family
  containers plays natively (AVI-era rips stay transcodes: with mpeg4
  advertised, `ContainerNotSupported` is the only reason the server cites,
  and mpeg4 is deliberately absent from the HLS list so those re-encode to
  hevc/h264 rather than risking mp4v in fMP4 segments). **AV1 is advertised
  per device** via `VTIsHardwareDecodeSupported` — AVPlayer only does AV1 in
  hardware (A17 Pro/M3 and later; no Apple TV as of tvOS 26). When present it
  is appended *last* to the direct-play and HLS codec lists, so hevc stays
  the transcode target and av1 merely enables stream copy, plus an av1
  CodecProfile (SDR/HDR10/HLG/HDR10Plus).
- **HLS segments are fMP4 (`Container: "mp4"`), never MPEG-TS.** Apple's HLS
  stack refuses HEVC (and all HDR/DoVi signalling) in TS — the old ts profile
  is why 4K HEVC MKVs came back as full H.264 SDR transcodes. With fMP4 the
  server *remuxes*: video stream-copies, so an MKV costs a container rewrap,
  not an encode.
- **HDR is advertised through `CodecProfiles` VideoRangeType conditions** on
  hevc: SDR, HDR10, HLG, HDR10Plus, DOVI (profile 5), and the profile-8
  DOVIWith{HDR10,HDR10Plus,HLG,SDR} fallbacks. h264 is SDR-only. Conditions
  carry `IsRequired: false` (the server-side default is *true*) so streams
  the server couldn't probe still direct play.
- **Dolby Vision profile 7 (DOVIWithEL) is deliberately absent** — Apple
  hardware can't render dual-layer DoVi, so the server re-encodes those to
  plain HDR10 (verified: hvc1 + smpte2084/bt2020 out, DoVi record stripped).
- DoVi survives remux correctly: init segments come back tagged `dvh1` with
  the DOVI configuration record intact (P5 verified byte-level), and masters
  signal `VIDEO-RANGE=PQ` plus `SUPPLEMENTAL-CODECS="dvh1.08.06/db1p"` (P8).
- **Transcode audio is `eac3,ac3,aac` with `MaxAudioChannels: "8"`** — the
  order is the server's preference, so TrueHD/DTS sources land on E-AC3 5.1
  instead of stereo AAC (stereo sources still get AAC; ffmpeg's eac3 encoder
  caps at 5.1). Compatible audio (aac/ac3/eac3) stream-copies, which carries
  **E-AC3 JOC (Atmos) through a remux intact**.
- Atmos reality on tvOS: E-AC3 JOC through AVPlayer is the *only* Atmos path.
  TrueHD Atmos can't be bitstreamed by any tvOS app, and engines that decode
  to LPCM lose the objects too (relevant to HEL-45's engine split).
- The simulator tone-maps everything to SDR — HDR presentation and the TV's
  HDR indicator can only be verified on real Apple TV 4K hardware, and
  spatial-audio engagement needs AirPods / an Atmos receiver (HEL-32/HEL-33
  remaining scope).

## mpv engine (HEL-45, experimental toggle)

`Lagoon/Views/Player/MPV/` holds a second playback engine built on libmpv
(MPVKit 1.0.0, mpv 0.41 — the project's only external dependency): true MKV
direct play where the server does zero work, DTS/TrueHD decoded to
multichannel LPCM, vc1/vp9/av1 in software where VideoToolbox can't.

**Split-engine design (deliberate):** AVPlayer keeps mp4/mov direct play and
all HLS — it has the best Dolby Vision pipeline and the *only* Atmos path on
tvOS (E-AC3 JOC). mpv gets what AVPlayer cannot open at all. Routing lives in
`PlaybackController.start` and is gated on the Settings → Debug →
"mpv engine for MKV" toggle (`debug.mpvForMKV`), which simultaneously widens
the device profile (`DeviceProfile.current` → `mpvExtended`, adding an
mkv/webm `DirectPlayProfile`) — the profile and the routing must ride the
same switch or the server grants direct play the client then can't do.

Mechanics (mirrors the MPVKit demo):

- `MPVPlayerEngine` owns the mpv handle. `wid` = CAMetalLayer address, set
  **before** `mpv_initialize` — hence `prepare(url:)` + `attachAndPlay(layer:)`
  split, with the layer coming from `MPVVideoSurface`'s view controller.
- Options: `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`,
  `hwdec=videotoolbox`, `target-colorspace-hint=yes` (HDR → EDR; cannot be
  toggled at runtime), `keep-open=no` so EOF fires `MPV_EVENT_END_FILE`.
  Initial `aid`/`sid` come from the MediaSource's
  `DefaultAudioStreamIndex`/`DefaultSubtitleStreamIndex` — the server has
  already applied the user's language preferences, so no mpv language
  heuristics (`subs-match-os-language` is deliberately not set). The
  Jellyfin stream index maps to mpv's per-type 1-based id by ordinal among
  embedded streams of that type; a nil default subtitle means `sid=no`.
- Threading: commands on the main actor (libmpv is thread-safe); the wakeup
  callback drains events on a private serial queue and hops state back via
  `Task { @MainActor }`. `MetalVideoLayer` swallows MoltenVK's 1×1
  drawableSize writes (mpv#13651).
- Resume is the `start` option (set pre-init), not a seek. Progress
  reporting is engine-agnostic in `PlaybackController` (`PlayMethod:
  DirectPlay`); positions come from the throttled `time-pos` observer.
- The UI is `CustomPlayerView`, which talks **only to the `PlayerEngine`
  protocol** (HEL-48: the sample-buffer engine must slot in without touching
  the UI; the video surface is injected). Focus invariants hold: the surface
  is focusable while the track panel is closed, play/pause toggles,
  left/right seek ±10 s, **down opens the track panel**, Menu exits — or
  closes the panel when it's open (focus lives in the panel's buttons then).
- **Track selection (HEL-35)** is instant and client-side on this path:
  `track-list` read as JSON, switched via `aid`/`sid`. External SRT streams
  are side-loaded on `FILE_LOADED` with `sub-add` (DeliveryUrl resolved +
  `api_key` appended); if the server's default subtitle is external it gets
  the `select` flag. Names are built from mpv's lang/title/codec facts.

Known-unknowns for the hardware pass: EDR/HDR10 output quality, DoVi P5
rendering via libplacebo (P7 MKVs still take the HDR10 remux — the hevc
CodecProfile conditions deliberately still apply), 4K AV1 software-decode
performance on A15. TrueHD Atmos objects are lost by design (no tvOS app can
bitstream them).

## Lagoon sample-buffer engine (HEL-48 M1, experimental toggle)

`Lagoon/Views/Player/SampleBuffer/` is the long-term engine: libavformat
demux (FFmpeg modules imported straight from MPVKit's artifacts — no new
dependency) into **compressed** CMSampleBuffers that
`AVSampleBufferDisplayLayer` / `AVSampleBufferAudioRenderer` decode and
render under an `AVSampleBufferRenderSynchronizer`. The system does decode,
color management, and audio output — that's the whole architecture bet.

- The key mechanic: Matroska stores h264/hevc mp4-style (avcC/hvcC
  extradata + length-prefixed NALs), so demuxed packets wrap directly as
  compressed sample buffers — no VTDecompressionSession, no shaders.
  Audio likewise: CoreAudio decodes aac/ac3/eac3 packets handed to the
  renderer (ac3/eac3 self-describing, aac needs its ASC as magic cookie).
- **M1 envelope**: h264/hevc + aac/ac3/eac3, no subtitles. Settings →
  Debug → "Lagoon engine A/B" routes eligible files here
  (`SampleBufferPlayerEngine.canPlay`); everything else stays on mpv, so
  the A/B toggle can never make a file unplayable.
- Threading: demux loop on a serial queue feeding two locked sample-buffer
  queues; renderer pumps drain them via `requestMediaDataWhenReady`; state
  and transport live on the main actor. Seeks stop the clock, flush
  renderers and queues, `av_seek_frame`, re-prime, then restart the
  synchronizer at the target. Audio track switching = re-demux from the
  current position with the new stream selected (others discarded inside
  libavformat).
- Roadmap: M2 Atmos (E-AC3 JOC survives because packets are never
  decoded), M3 HDR/DoVi format descriptions, M4 DTS/TrueHD via libavcodec,
  M5 subtitles, M6 parity hardening — then mpv gets deleted (HEL-48).

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player showing
the negotiated method/container/codecs/range/bitrate plus live
`AVPlayerItem` stats refreshed every 2 s. The Debug section (HUD + mpv
toggle) deliberately ships in **all** builds, TestFlight included — real
Apple TV hardware only ever runs Release, and that's exactly where these
switches are needed; both default off. The "Playing:" fourCC tells remux
truth from re-encode — `dvh1` means Dolby Vision actually reached AVPlayer,
`hvc1` plain HEVC. The overlay is hit-test-disabled and never focusable, so
tvOS focus behavior is untouched. Backed by `UserDefaults` key
`debug.playbackHUD`, checked once at playback start.

## Progress reporting

Positions are ticks (see jellyfin-api.md). Three report points, all fire-and-
forget (`try?` — reporting must never interrupt playback):

- `Sessions/Playing` once playback starts.
- `Sessions/Playing/Progress` every 10 s from a detached loop, including
  `IsPaused` derived from `timeControlStatus`.
- `Sessions/Playing/Stopped` exactly once from `stop()` (guarded by
  `didReportStop`), called on dismiss. This is what moves the server-side
  resume point and reorders Continue Watching.

Detail screens re-fetch the item in `fullScreenCover`'s `onDismiss`, and
HomeView re-fetches its Resume/Next Up rails in `onAppear`, so the UI reflects
the new position immediately.

## Player view gotchas (all learned the hard way on tvOS)

- `externalMetadata` (title, subtitle, description, artwork) must be **fully
  built before playback starts** — mutating it while the player is active
  corrupts the info panel layout. Artwork is fetched through `ImageCache`
  and attached as JPEG data with `extendedLanguageTag = "und"`.
- On failure the player is set to **nil** and replaced with a custom error
  overlay carrying a Back button and `.onExitCommand` — a dead player
  swallows the Menu press and traps the user.
- `AVPlayerItem.didPlayToEndTimeNotification` dismisses the cover so a
  finished movie doesn't strand the viewer on a black screen.
- The loading state is `LoadingView` (focusable) for the same Menu-button
  reason as everywhere else.
