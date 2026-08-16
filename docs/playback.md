# Playback

**One engine for everything** (Jaagop's call, 2026-08-16, HEL-48): all
playback runs through the Lagoon sample-buffer engine. The AVPlayer and mpv
players were removed the same day the decision was made — no split paths,
no per-container routing. The MPVKit package stays **only** as the source
of the FFmpeg xcframeworks the engine links (`import Libavformat` works
straight from its artifacts); libmpv itself is unused dead weight in the
bundle until the dependency is slimmed.

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.lagoon` — a
   capability profile mirroring exactly what the engine can wrap: h264/hevc
   video with aac/mp3/ac3/eac3 audio in mkv/webm/mp4/m4v/mov, plus an fMP4
   HLS transcoding profile whose output (hevc/h264 + eac3,ac3,aac) lands
   back inside the same envelope. The server does the deciding.
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
- **Threading**: the demux loop runs on a serial queue feeding two locked
  sample-buffer queues; renderer pumps drain them via
  `requestMediaDataWhenReady`; state and transport live on the main actor.
- **Seeks** stop the clock, flush renderers and queues, `av_seek_frame`,
  re-prime (~12 video buffers), then restart the synchronizer at the
  target. Resume is the same path with the start position.
- **Audio tracks**: listed from the demuxer (per-type 1-based ordinals —
  the same convention the server's `DefaultAudioStreamIndex` maps to);
  switching re-demuxes from the current position with the new stream
  selected and the rest discarded inside libavformat.
- **Milestones outstanding** (HEL-48): M2 Atmos verification (E-AC3 JOC
  passes through compressed, so it may already survive — needs hardware),
  M3 HDR/DoVi color tagging on the format descriptions (until then HDR
  sources render without HDR signalling), M4 DTS/TrueHD decode via
  libavcodec (until then the server transcodes their audio to E-AC3), M5
  subtitles (none render today — the `SubtitleProfiles` vtt request and
  `externalSubtitleURL` helper are ready for it), M6 stall/underrun
  hardening and the master-variant pick.

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player showing
the negotiated method/container/codecs/range/bitrate plus live engine state
refreshed every 2 s. Ships in **all** builds, TestFlight included — real
Apple TV hardware only ever runs Release; defaults off
(`debug.playbackHUD`, read once at playback start).

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
- Focus invariants: the video surface is focusable whenever the panel is
  closed (Menu would quit the app from an unfocusable screen); Menu is
  decided once — panel open closes the panel, otherwise the player exits,
  with a handler on the panel itself as the nearest catch.
- `defaultFocus` is only honored when a fresh scene appears — any
  mid-screen reveal must assign its `@FocusState` programmatically
  (immediately, plus a settled retry) or focus strands and Menu falls
  through to the fullScreenCover's default dismissal.
- Native buttons only; never draw custom chrome tied to focus — the system
  lozenge is the design (see the Infuse reference on HEL-35).
- On failure the engine is set to **nil** and replaced with an error
  overlay carrying a Back button and `.onExitCommand` — a dead surface
  would swallow the Menu press and trap the user.
- The loading state is `LoadingView` (focusable) for the same Menu-button
  reason as everywhere else.
