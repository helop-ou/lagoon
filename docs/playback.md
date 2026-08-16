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

## Debug playback HUD

DEBUG builds get Settings → Debug → Playback HUD: a top-left overlay in the
player showing the negotiated method/container/codecs/range/bitrate plus live
`AVPlayerItem` stats refreshed every 2 s. The "Playing:" fourCC tells remux
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
