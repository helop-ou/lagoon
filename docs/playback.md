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
   - else the server-provided `TranscodingUrl` (arrives server-relative with
     its own query string — resolve against the server URL, don't rebuild
     it), PlayMethod `Transcode`.
3. AVPlayer plays it; Jellyfin's HLS playlists cover the full duration, so
   **resume is a client-side seek** rather than a `StartTimeTicks` offset —
   this keeps position reporting absolute in both play methods.

## Device profile (HDR & audio policy)

All of this is encoded in `DeviceProfile.native`
(`Lagoon/Networking/DeviceProfile.swift`) and was verified against a real
library on 2026-08-15 by probing PlaybackInfo responses, HLS playlists, and
fMP4 init segments (full matrix in the HEL-32/HEL-33 comments):

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
