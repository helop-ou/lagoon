# Playback

All media plays through `PlayerEngine` and Lagoon's sample-buffer engine.
The UI uses that protocol; do not add an alternative AVPlayer or mpv path.
Read this guide before changing player behavior, then follow the focused links
into the [engineering notes](reference/playback/README.md) for implementation details.

## Ownership and pipeline

```text
PlaybackController
  ├─ Jellyfin negotiation, subtitles and system media
  ├─ PlaybackReportingSession → start/progress/stop and report ledger
  ├─ PlaybackSuccessorPreparation → next episode negotiation and warm-up
  ├─ PlaybackDiagnosticsSampler → optional HUD and decode trace
  ├─ PlaybackIncidentMonitor → opt-in incident sampling
  ├─ PlaybackCacheCoordinator → scoped file/range cache
  └─ SampleBufferPlayerEngine
       ├─ FFmpegDemuxer → compressed packets
       ├─ VideoToolbox / software decode + conversion
       └─ audio/video queues → AVSampleBuffer renderers and synchronizer
```

Playback lives in `Lagoon/Features/Playback/`. `PlaybackController.swift` owns
the session; `Views/VideoPlayerView.swift` retains it with `@State`. Surfaces,
controls, overlays and PiP presentation live in `Views/`, the demux/decode/render
pipeline in `Engine/`, byte sources and cache in `Transport/`, subtitle
processing in `Subtitles/`, and sampling/benchmarks in `Diagnostics/`.

## Network transport

Every HTTP open uses `FFmpegNetworkTransport` over URLSession, including HLS
playlists and segments. Repo-built libavformat has its network stack disabled.
Do not restore native FFmpeg HTTP/TLS as a cache fallback. System certificate
trust, account-scoped authorization, redirect rules, cancellation, and the
size-capped fetches `BoundedDownload` applies to subtitles and artwork must
apply to every streamed media path. That bound is a transport safeguard, not
the offline Downloads feature: see [Downloads](#downloads-hel-166) below for
the feature that keeps a whole file on disk.

Media credentials use the authorization header rather than token-bearing URLs.
Keep endpoint/cross-origin rules in the shared authorization and transport
helpers. Cache incompatibility changes the byte-source strategy, not the
security policy. Failures remain errors; only a successfully read resource's
end is EOF. See [transport details](reference/playback/transport.md#network-transport),
[TLS validation](archive/hel-142-native-tls-validation.md), and the
[libavformat build record](../Packages/LagoonFFmpeg/Artifacts/Libavformat.README.md).

## Stream resolution

`DeviceProfile` advertises the current device's supported codec envelope.
Jellyfin negotiation and the failure-driven delivery ladder choose direct
play, remux, then video transcode; only the re-encode rung has the 1080p ceiling.
Do not confuse remux selection with `SupportsDirectStream`. Preserve the
failure cause and resume position when moving down a rung.

Progressive H.264 uses the compressed sample-buffer path; interlaced H.264 is
software-decoded and deinterlaced, on the stream's probed field order, never
the server's flag (HEL-170). HEVC is decoded ahead through VideoToolbox. AV1
uses hardware where available and the repo-built dav1d otherwise. Other
supported legacy/software codecs use bounded software decode.
Codec limits and HDR routing belong in the existing profile and decode policy,
not duplicated checks in views. iOS metered-path limits affect both static and
streaming bitrate offers and can be overridden in Playback settings.

E-AC-3 JOC keeps its compressed Atmos path. TrueHD decodes to lossless LPCM;
its Atmos objects are not preserved. Subtitles come from embedded streams or
Jellyfin's permission-gated subtitle routes; there is no direct provider login.
Disc images use the app's bounded byte source and UDF handling.

See [negotiation and delivery](reference/playback/stream-resolution.md#stream-resolution),
[disc images](reference/playback/stream-resolution.md#disc-images-hel-133), and
[decode details](reference/playback/engine.md#the-engine-lagoonfeaturesplaybackengine).

## Lifecycle and memory

- The controller owns the engine. SwiftUI player views hold it through
  `@PlayerEngineRef`, and view builders/gesture closures must not capture an
  engine strongly. SwiftUI can retain old view values after an episode handoff.
- Stop is two-phase: cancel clocks/work and interrupt FFmpeg immediately;
  serialize renderer stop/flush and release on the pump queue, and decoder
  destruction on the demux queue. Network reporting never blocks dismissal.
- Replacement waits for the outgoing engine's demux loop and renderers to
  retire, with a bounded timeout. Never revive a stopped engine or overlap two
  pipelines because teardown timed out.
- There is one active cache scope and at most one staged successor. Exit,
  failure, account replacement, and handoff cancel and remove the appropriate
  scopes. The cache is transient playback storage, not an offline library.
- Preserve decoded-frame byte budgets, reorder depth, queue watermarks, and
  backpressure across both queued packets and decode work in flight. A frame
  count alone is not a sufficient memory budget for 4K software decoding.
- Arm `requestMediaDataWhenReady` only while a queue has data to offer.
  Returning empty-handed in a still-armed callback creates a busy loop.
- Compressed packets retain their FFmpeg backing buffer. Decoded LPCM is
  copied into CoreMedia-owned storage at emit; the previous zero-copy LPCM
  handoff leaked a whole decoded audio stream.
- Preserve sample-exact audio timelines, seek generations, decoder callback
  ordering, and bounded stall recovery. Do not replace queue ownership with
  unstructured tasks as part of a file reorganization.
- A seek into a container with no index (a plain MPEG-TS file, such as a
  transcode download) must still start video on a keyframe: the demuxer
  peeks the landing packet and re-seeks to the last keyframe before the
  target, and drops non-start packets until one arrives (HEL-166).
  `TransportStreamSeekTests` pins it against the fixture named by
  `LAGOON_TS_SEEK_FIXTURE_URL`, injected into the xctestrun.

The repo builds dav1d with arm64 assembly. After changing its artifact, run
`scripts/build-dav1d.sh --verify-only Packages/LagoonFFmpeg/Artifacts/Libdav1d.xcframework`.
Software 10-bit conversion uses the asynchronous Metal path; synchronous
conversion changes its performance characteristics. Native dependency
changes also need matching acknowledgements, license text, and build evidence.

### Downloads (HEL-166)

Before negotiating, and before consulting a prepared successor, the
controller asks `DownloadStore` whether the item is a finished download. When
one exists, playback never touches the network to start: negotiation,
`playbackInfo` and `streamURL` are skipped outright, the method is direct
play, and the stream is the file on disk. This keeps the existing rule that a
local file needs no cache in front of it; a downloaded title plays with no
`PlaybackCacheCoordinator` scope at all, the same as any other file URL.

Track metadata depends on what was actually downloaded. An original-quality
download is the stored file, so its source's stream list still describes it
and drives audio/subtitle selection exactly as a negotiated stream would. A
high/standard download is a transcode the server built for offline use, a
different container carrying one audio track and no external subtitles, so
its source's stream list does not describe the file on disk; the controller
hands the engine empty track metadata rather than stale descriptions, and
both the engine's own track construction and the ordinal selection policies
already degrade to what the file demuxes to when given nothing. The picker
panel reflects whatever the engine actually finds; only the language/title
labels are lost for a transcode, not track selection itself.

A downloaded title also has no chapters, trickplay, or skip segments: the
garnish requests that ride alongside negotiation for a streamed title are
skipped rather than awaited, since asking an unreachable server for them
would burn the client's full request timeout before the engine ever starts.
Losing chapters, trickplay, and skip segments offline is an accepted gap for
this feature's first pass. The start report follows the same reasoning: it
is fired without being awaited for a downloaded title, so a server the
device cannot currently reach never delays the progress loop, HUD, or
next-up warm-up.

Position handling runs in both directions. Starting a downloaded title
prefers its own locally recorded resume point over the server's last known
position, since there was no negotiation to fetch a fresh one; choosing to
start from beginning still starts at 0 for a downloaded title exactly as it
does for a streamed one. Stopping one
records the position back through `DownloadStore.recordPosition`, cleared
once the position lands in the last 2% of the runtime, so a downloaded title
resumes correctly the next time it plays with no server involved. Whether or
not an item is downloaded, a stop report the server refuses or cannot reach
is queued as a `PendingPlaybackReport` and flushed on reconnect, so a
session's true stopping point is never silently lost to a bad connection.

### The player's Observation scope (HEL-150)

The player root must not read `timePosition`, current subtitle values, or
other tick-rate state in its body, modifier IDs, or animation values. Those
reads belong in small overlay leaves. Return before reading the playhead when
there is no applicable segment/successor, and avoid position reads in the
hidden timeline. Observation subscribes to reads that actually execute.

The panel host's `Equatable` boundary separately protects its interior from
unnecessary renders. Preserve both boundaries. See the
[scope measurements](reference/playback/engine.md#the-players-observation-scope-hel-150)
and [memory/lifecycle notes](reference/playback/frame-loss-bench.md#decoded-frame-memory-ceiling-hel-109).

## Progress reporting

Send `Sessions/Playing` once, progress every 10 seconds, and
`Sessions/Playing/Stopped` exactly once after capturing the final position.
Use the existing `Ticks` helpers. Reporting failure must not interrupt playback.

Presenting screens await `client.playbackReports.settle()` before fetching
watch state after dismissal. Keep API cache bypass and `MediaItem` value
equality: both are needed for the fetched resume point to reach the UI.
Test far enough into a title to pass the server's configured resume threshold.
See [reporting details](reference/playback/controls-and-reporting.md#progress-reporting).

## Controls and presentation

On iPhone and iPad, a surface tap toggles transport visibility. Centered
play/pause and ±10-second buttons use `.glass(.clear)`. While playing, controls
fade after four seconds without interaction. Paused playback and VoiceOver
keep them available with the options sheet closed. Hidden controls disable
hit testing and are marked accessibility-hidden; keep the layout mounted so
fading and toolbar safe-area changes cannot move the center cluster.

Double-tapping either half seeks ten seconds without revealing controls.
Repeated double-taps within the 700 ms feedback window accumulate the shown
amount; changing direction resets it. Dragging the timeline previews trickplay
and commits on release. Skip and Up Next accept direct taps. Close and Info
live in the native toolbar; the options sheet suppresses surface interaction.
Close closes the player outright. A swipe up over free video opens the options
panel; a swipe down carries the whole player with the finger, YouTube-style,
and past the threshold minimizes it into the phone's popup player, which is
Picture in Picture (where PiP is not possible it closes instead). The
timeline's own drag and every button win over the swipe (HEL-162 feedback).

The player follows the device on iPhone and iPad and never forces a rotation:
a title opened in portrait plays letterboxed in portrait until the viewer turns
the phone (HEL-162 feedback, superseding the HEL-153 landscape lock). Audio
uses normal movie-playback behavior: volume keys control output, and Silent
Mode does not silence the movie.

On iOS, screens only *request* playback through `playerPresentation`; the one
`playerPresentationHost` at the tab root (`PlayerPresentationHub`) presents it
and retains the hosting controller across PiP. The swipe down requests PiP
when available; only its successful start callback hides fullscreen. Restore reuses
the same controller; closing PiP or withdrawing the request cleans up the
session, and `onDismiss` still reaches the requesting screen. Physical
PiP/background/caption acceptance remains open. Never present from inside a
`NavigationStack` destination again: a presenter hosted in a pushed detail page
made the stack briefly show its root, a view update in that window dropped the
destination, and its teardown closed the player about a second after it opened
from any detail page (HEL-162). Only Home and Continue Watching, which are not
pushed, survived, which is why it looked title-dependent. The host is presented
`.overFullScreen`: `.fullScreen` removes the presenting hierarchy and re-runs
the `.task`s underneath, the regression bootstrap included.

On tvOS, the video surface owns focus. Select prioritizes scrub, Skip,
Up Next, then play/pause. A light Siri Remote touch is a separate input that
reveals controls; it must not become Select. Menu cancels scrubbing, closes the
panel, then exits. Keep the mounted panel and remote command ordering intact.
See [remote reveal](reference/playback/controls-and-reporting.md#siri-remote-transport-reveal) and
[tvOS gotchas](reference/playback/controls-and-reporting.md#player-view-gotchas-learned-the-hard-way-on-tvos).

## Diagnostic reporting

Unexpected playback and request failures are reported automatically
(HEL-159) through `Diagnostics.shared`: a vendor-neutral hub with a rolling
history and a Sentry envelope transport the app owns. There is no SDK. Only
keys in `DiagnosticSchema.fields` can leave the device; a title, URL, message
or `localizedDescription` handed to it is dropped and counted. When adding a
failure path, give `PlaybackEngineFailure` a `PlaybackFailureDetail` (stage,
error domain, code) rather than relying on its message, record the moment
with `Diagnostics.record`, and report with a fingerprint that never varies
per occurrence. Keep `record` cheap and off the pump queues; the hub already
runs the sink on its own queue. Detectors, thresholds, limits, tester
controls and the Sentry setup are in the [diagnostics reference](reference/playback/diagnostics.md).

## Regression checks

Build both platforms and run the relevant pure logic tests. Use
`TouchPlayerUITests` for iPhone/iPad touch and auto-hide, and
`PlayerRegressionUITests` for remote input, reporting, handoff, and teardown.
The [touch validation record](archive/hel-153-touch-validation.md) records the
passing simulator journeys and remaining physical checks. What a journey may
assume about the server and the simulator's state, and the resolver flags
that open a title by property, are in the
[regression lane reference](reference/regression-lane.md).

XCTest can expose faded buttons and nonzero frames even with
`accessibilityHidden`. For auto-hide, assert the launch-gated `transport`
state, toolbar disappearance, and screenshots together. Use full-screen
screenshots for landscape; app screenshots can be cropped. Simulator evidence
does not establish physical VoiceOver or PiP acceptance.

For background fill, `scripts/fill-bench.sh` plays one title hands-off on a
simulator and reports cached and network megabytes over time from the decode
trace, so two builds can be compared on the same asset and link (HEL-160).
For performance, use `scripts/framedrop-bench.sh` and
`scripts/playback-lifecycle-bench.sh`. Compare the same fixture, scene,
media-time window, build configuration, and display path over at least three
untouched runs. Release measurements without coverage and diagnostic-overlay
interference are the useful device comparison. Keep physical full-film,
captions/HDR, and teardown acceptance separate from simulator results.
See the [frame-loss procedure](reference/playback/frame-loss-bench.md#frame-loss-bench-hel-64).
