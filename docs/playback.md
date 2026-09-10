# Playback

All media plays through `PlayerEngine` and Lagoon's sample-buffer engine.
The UI uses that protocol; do not add an alternative AVPlayer or mpv path.
Read this guide before changing player behavior, then follow the focused links
into the [engineering notes](reference/playback/README.md) for implementation details.

## Ownership and pipeline

```text
PlaybackController
  ├─ Jellyfin negotiation, reporting, next episode, subtitles, system media
  ├─ PlaybackCacheCoordinator → scoped file/range cache
  └─ SampleBufferPlayerEngine
       ├─ FFmpegDemuxer → compressed packets
       ├─ VideoToolbox / software decode + conversion
       └─ audio/video queues → AVSampleBuffer renderers and synchronizer
```

`PlaybackController` currently lives in `VideoPlayerView.swift`. The UI lives
in `CustomPlayerView`, the transport, panel, subtitle, Skip, and Up Next views.
Engine implementation is under `Lagoon/Views/Player/SampleBuffer/`.
These are current locations; [Architecture](architecture.md#refactoring-priorities)
records the proposed cleanup.

## Network transport

Every HTTP open uses `FFmpegNetworkTransport` over URLSession, including HLS
playlists and segments. Repo-built libavformat has its network stack disabled.
Do not restore native FFmpeg HTTP/TLS as a cache fallback. System certificate
trust, account-scoped authorization, redirect rules, cancellation, and bounded
downloads must apply to every media path.

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

H.264 uses the compressed sample-buffer path; HEVC is decoded ahead through
VideoToolbox. AV1 uses hardware where available and the repo-built dav1d
otherwise. Other supported legacy/software codecs use bounded software decode.
Codec limits and HDR routing belong in the existing profile and decode policy,
not duplicated checks in views. iOS metered-path limits affect both static and
streaming bitrate offers and can be overridden in Playback settings.

E-AC-3 JOC keeps its compressed Atmos path. TrueHD decodes to lossless LPCM;
its Atmos objects are not preserved. Subtitles come from embedded streams or
Jellyfin's permission-gated subtitle routes; there is no direct provider login.
Disc images use the app's bounded byte source and UDF handling.

See [negotiation and delivery](reference/playback/stream-resolution.md#stream-resolution),
[disc images](reference/playback/stream-resolution.md#disc-images-hel-133), and
[decode details](reference/playback/engine.md#the-engine-lagoonviewsplayersamplebuffer).

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

The repo builds dav1d with arm64 assembly. After changing its artifact, run
`scripts/build-dav1d.sh --verify-only Packages/LagoonFFmpeg/Artifacts/Libdav1d.xcframework`.
Software 10-bit conversion uses the asynchronous Metal path; synchronous
conversion changes its performance characteristics. Native dependency
changes also need matching acknowledgements, license text, and build evidence.

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

iPhone fullscreen locks to landscape and releases the lock on exit. iPad
retains rotation/multitasking. Audio uses normal movie-playback behavior:
volume keys control output, and Silent Mode does not silence the movie.

On iOS, `playerPresentation` retains the hosting controller across PiP. Close
requests PiP when available; only its successful start callback hides fullscreen.
Restore reuses the same controller; closing PiP or removing the presenter
cleans up the session. Physical PiP/background/caption acceptance remains open.

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
passing simulator journeys and remaining physical checks.

XCTest can expose faded buttons and nonzero frames even with
`accessibilityHidden`. For auto-hide, assert the launch-gated `transport`
state, toolbar disappearance, and screenshots together. Use full-screen
screenshots for landscape; app screenshots can be cropped. Simulator evidence
does not establish physical VoiceOver or PiP acceptance.

For performance, use `scripts/framedrop-bench.sh` and
`scripts/playback-lifecycle-bench.sh`. Compare the same fixture, scene,
media-time window, build configuration, and display path over at least three
untouched runs. Release measurements without coverage and diagnostic-overlay
interference are the useful device comparison. Keep physical full-film,
captions/HDR, and teardown acceptance separate from simulator results.
See the [frame-loss procedure](reference/playback/frame-loss-bench.md#frame-loss-bench-hel-64).
