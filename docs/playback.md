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
- **Audio decode** (M4): codecs CoreAudio won't take compressed
  (DTS, TrueHD, FLAC, Opus, Vorbis — anything with an FFmpeg decoder)
  go through `AudioDecoder`: libavcodec → swresample → interleaved
  Float32 LPCM sample buffers, coalesced to ~2048-sample chunks because
  TrueHD frames are 40 samples each. FFmpeg's native channel-bit order
  matches CoreAudio's channel bitmap bit-for-bit on the first 18
  positions, so a native layout mask maps straight across into the
  `AudioChannelLayout`. The E-AC3 (JOC/Atmos) path deliberately stays
  compressed passthrough. Platform limit stands: TrueHD Atmos objects
  are unpreservable — TrueHD plays as lossless multichannel LPCM.
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
- **HDR/DoVi tagging** (M3): the video format description carries
  colorimetry extensions (primaries/transfer/matrix/range/chroma siting
  from codecpar) plus HDR10 static metadata (mdcv/clli payloads rebuilt
  big-endian from FFmpeg side data) — that's what makes the display
  pipeline engage HDR/EDR instead of rendering BT.2020+PQ as washed-out
  SDR. Dolby Vision: profile 5 becomes a `dvh1` sample entry with a
  `dvcC` atom (IPTPQc2 is unwatchable without the DoVi path), profile 8
  stays `hvc1` plus supplementary `dvvC` (non-DoVi displays fall back to
  the base layer's HDR10/HLG tags), dual-layer profiles 4/7 get no atom
  and play as HDR10 from the base layer. Hardware verification pending
  (the simulator has no HDR output; DoVi P5 may not decode in the sim at
  all).
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
- **Milestones outstanding** (HEL-48): hardware passes only — M2 Atmos
  (E-AC3 JOC passes through compressed, so it may already survive), M3
  HDR/DoVi tagging verification, M4 multichannel layouts. All engine
  code milestones (M1–M6) landed as of 2026-08-17; M4–M6 sim pass
  pending.

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
- Focus invariants: the video surface is focusable at **all** times (Menu
  would quit the app from an unfocusable screen).
- **SwiftUI's `onExitCommand` never fires inside a fullScreenCover on
  tvOS 26** — arrows and play/pause reach SwiftUI, but UIKit's
  presentation controller consumes Menu and dismisses the cover directly,
  and `interactiveDismissDisabled` doesn't gate it (verified with
  instrumented handlers). `MenuPressGate` hosts the player content in a
  UIHostingController that intercepts the press at the responder-chain
  level: panel open → close panel, else → explicit dismiss. It must catch
  **both** `UIPress.PressType.menu` (Siri Remote) and a keyboard Escape
  press (`key?.keyCode == .keyboardEscape`; the simulator's keyboard
  sends type = 2000 + HID usage, never `.menu`).
- `defaultFocus` is only honored when a fresh scene appears — any
  mid-screen reveal must assign its `@FocusState` programmatically
  (immediately, plus a settled retry) or focus strands.
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
