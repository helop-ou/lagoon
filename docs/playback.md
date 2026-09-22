# Playback

All media plays through the `PlayerEngine` protocol and Lagoon's
sample-buffer engine, and the UI talks only to the protocol. Never add an
AVPlayer or mpv path. Implementation details are in the [engineering
notes](reference/playback/README.md).

## Ownership and pipeline

```text
PlaybackController
  ├─ Jellyfin negotiation, subtitles and system media
  ├─ PlaybackReportingSession → start/progress/stop and report ledger
  ├─ PlaybackSuccessorPreparation → next episode negotiation
  ├─ PlaybackDiagnosticsSampler → optional HUD and decode trace
  ├─ PlaybackIncidentMonitor → opt-in incident sampling
  └─ PlayerEngine (LagoonEngine package)
       → a picture, a clock, a byte cache, and a verdict when it fails
```

Playback lives in `Lagoon/Features/Playback/`. `PlaybackController.swift`
owns the session; `Views/VideoPlayerView.swift` retains it with `@State`.
Surfaces, controls, overlays and PiP presentation are in `Views/`.

Demux, decode and render are **not in this repository**. The `LagoonEngine`
package knows nothing of Jellyfin, accounts or SwiftUI: it takes a media
source, track metadata and an optional credential, and returns a picture and
a verdict. Start at [the engine
guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md).
This repository decides what to hand it and what to do with what comes back.

## Network transport

The engine owns the transport: every HTTP open goes through URLSession, and
its libavformat has no network stack. The app supplies the credential.

- Build media authorization in the shared helpers and pass it with the
  request. Credentials go in the authorization header, never in the URL.
- Endpoint and cross-origin rules stay in the shared authorization helpers,
  not at call sites.
- `BoundedDownload`'s size caps are a transport safeguard, unrelated to the
  offline [Downloads](#downloads) feature.

## Stream resolution

`DeviceProfile` advertises the device's codec envelope. Negotiation and the
failure-driven delivery ladder go direct play → remux → video transcode.

- Only the transcode rung has the 1080p ceiling.
- Remux selection is not `SupportsDirectStream`.
- Moving down a rung keeps the failure cause and the resume position.
- **Descend only on the engine's verdict about the samples.** `.undecodable`
  skips remux and is one-way: it costs a reload, the embedded subtitle tracks
  and server CPU per viewer, so a failure that says nothing about the
  bitstream must never reach it.
- **A `.delivery` verdict is never a reason to re-encode.**

The engine guards its own verdicts: a reclaimed decode session is rebuilt,
not reported undecodable, and a just-flushed renderer refuses a non-keyframe.
See the engine's [stream recovery
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/stream-recovery.md).

Codecs:

- Progressive H.264: compressed sample-buffer path.
- Interlaced H.264: software decode and deinterlace, on the stream's probed
  field order, never the server's flag.
- HEVC: decoded ahead through VideoToolbox.
- AV1: hardware where available, the repo-built dav1d otherwise.
- Other supported legacy codecs: bounded software decode.
- E-AC-3 JOC keeps its compressed Atmos path. TrueHD decodes to lossless LPCM
  without its Atmos objects.
- Codec limits and HDR routing live in the profile and decode policy, never
  in views.
- iOS metered-path limits apply to static and streaming bitrate offers and can
  be overridden in Playback settings.

**HDR10+ needs no code.** VideoToolbox attaches the dynamic metadata to each
decoded frame (an undocumented `HDR10PlusData` attachment with the T.35
payload, country code 0xB5 first), it rides through the queues, and tvOS
engages HDR10+ on a capable display. Verified on an Apple TV 4K (3rd
generation) with an HDR10+ panel: `HDR10Plus` and `DOVIWithHDR10Plus` titles
badge HDR10+, `DOVIWithHDR10` badges plain HDR. A display without Dolby Vision
falls back to the base layer and still uses the HDR10+ metadata, so no
display-capability check is needed. When checking by eye:

- Screen mirroring from the Apple TV disables HDR output, so any badge read
  with it on is meaningless.
- The panel shows no badge in Filmmaker Mode.

Subtitles come from embedded streams or Jellyfin's permission-gated routes;
there is no direct provider login. Disc images use the app's bounded byte
source and UDF handling.

See [negotiation and
delivery](reference/playback/stream-resolution.md#stream-resolution), [disc
images](reference/playback/stream-resolution.md#disc-images) and [decode
details](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/decode.md).

### Audio track selection

`TrackSelectionPolicy` picks automatically: the viewer's audio mode, then
preferred languages, then Jellyfin's default. Some releases defeat all three
(The 100's season-one remux has five untagged audio streams, four identical
DTS 5.1, and the default is the first, Russian). There, the viewer's
correction decides.

`AudioTrackMemoryStore` keeps one audio choice per series (per item for a
film) per account, written through to `UserDefaults` so it survives closing
the player.

Recording:

- Record when the viewer chooses, from the engine's `onTrackSelectionChanged`.
  Only `selectAudioTrack` fires it, and only the track panel and system
  now-playing menu call that, so every stored value is deliberate.
- Never read the selection back at exit: by then the scope, layout and engine
  may belong to the next episode.
- The write is guarded to the current engine and skipped when the engine's
  track count differs from the server's layout. A remux or transcode rung
  delivers one track where the source lists several, so ordinals do not
  transfer.
- Choosing what automatic selection would have picked _forgets_ the override,
  so later preference changes still apply.

`AudioTrackMemoryPolicy` applies it as a ladder: a description naming exactly
one track, then the remembered position if the layout fingerprint is
unchanged, then the first track in the right language. Ambiguity is a
failure, not a coin flip. Position only decides between identically tagged or
untagged tracks, never against a specific description, and a re-tagged
release or added commentary track retires it.

Match on `MediaStream.title`, never `displayTitle`: Jellyfin builds the
latter from codec and layout, so all four DTS tracks display as
`DTS-HD MA - 5.1`. The engine appends the position to colliding track names so
rows can be told apart and recognised later.

### Subtitle track selection

The same ladder, in subtitle ordinals: embedded tracks, then external ones,
with 0 meaning none. `SubtitleTrackMemoryStore` keeps one choice per series
per account under its own key. Both stores are `TrackMemoryStore` (re-read,
merge, evict, persist); the policies stay separate because layout shape
differs and off is a valid answer.

- **Off is stored like any other choice.** It is the choice a server default
  most often overrules, and it describes no track, so no layout change
  retires it.
- A subtitle layout's shape includes forced, hearing-impaired and external,
  the distinctions a release makes between same-language tracks.
- Subtitle search appends tracks mid-episode, so the write requires at least
  as many engine tracks as the captured layout, not exactly as many, and
  refuses an ordinal pointing at an appended track.

## Lifecycle and memory

These are the app's obligations. The engine's own (two-phase stop, never
reviving a stopped engine, queue watermarks, decoded-frame budgets) are in
[the engine
guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md#lifecycle).

- **The controller owns the engine. Player views hold it through
  `@PlayerEngineRef`, and view builders and gesture closures never capture an
  engine strongly**: SwiftUI can keep old view values after an episode
  handoff. The engine cannot enforce this, and it has regressed most often.
- Network reporting never blocks dismissal.
- The byte cache belongs to the engine. `prepare` takes an item ID and a
  delivery and decides whether to cache; `stageSuccessor` warms the next
  episode; `bufferState` feeds the scrub bar. Nothing here builds a cache
  session or runs a fill loop. The engine enforces one active scope and at
  most one staged successor across engine replacements; exit, failure,
  account replacement and handoff retire scopes. The cache is transient, not
  an offline library.
- Do not replace queue ownership with unstructured tasks during a file
  reorganization.

### Downloads

Before negotiating or consulting a prepared successor, the controller asks
`DownloadStore` whether the item is a finished download. If so, playback
starts without the network: no negotiation, `playbackInfo` or `streamURL`;
direct play from the file on disk, with no cache scope in front of it.

- **Track metadata.** An original-quality download is the source file, so its
  stream list drives audio and subtitle selection as usual. A High/Standard
  download is a server transcode (different container, one audio track, no
  external subtitles), so the controller passes empty track metadata. The
  engine and selection policies fall back to what the file demuxes to; only
  language and title labels are lost.
- **No chapters, trickplay or skip segments offline.** Those requests are
  skipped, not awaited, because an unreachable server would burn the full
  request timeout before the engine starts. This is an accepted gap.
- **The start report is not awaited** for a download, so an unreachable
  server never delays the progress loop, HUD or next-up warm-up.
- **Position.** A download resumes from its locally recorded point, not the
  server's. Start from beginning still starts at 0. Stopping records the
  position with `DownloadStore.recordPosition`, cleared in the last 2% of the
  runtime.
- For any item, a stop report the server refuses or cannot reach is queued as
  a `PendingPlaybackReport` and flushed on reconnect.

### Group transport hooks

The engine exposes four hooks for server-driven transport: `clockPosition`,
`play(atHostTime:)`, `setCorrectionRate(_:)` and `onSeekReady`. [The engine
guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md#driving-the-clock-from-outside)
states their contracts. Two matter constantly here:

- `clockPosition` is the synchronizer's clock, never the optimistic position
  a seek sets before anything is demuxed. A Buffering report must carry it.
- `setCorrectionRate(_:)` is not `rate`. `rate` stays the viewer's choice and
  is what the speed row and Now Playing show.

The controller is the boundary; a group driver never holds the engine.

- It starts playback with `start(startPosition:startPaused:)`. The server's
  position outranks every resume rule, and a member can wait primed and
  paused until the group starts.
- It drives `playGroup(atHostTime:)`, `pauseGroup()`, `seekGroup(to:)` and
  `setCorrectionRate(_:)`, reads `clockPosition` and `isPrimedAndPaused`, and
  listens to `onEngineReady` and `onClosed`.
- Group transport is separate from viewer controls, so the driver can turn
  the viewer's Play and Pause into group requests without recursing into
  itself.
- The wiring lives in `start`, so episode handoff and delivery fallback carry
  it to the successor engine.

### Watch Together (SyncPlay)

`SyncPlayStore` (`Lagoon/Features/SyncPlay/`) owns membership: socket, clock,
group, queue. `GroupPlaybackDriver` owns everything that touches playback,
holding the controller weakly and the engine not at all.

- **The viewer's transport is a request.** Play, pause, seek, skips, scrub
  commit and the lock screen go to `groupTransport`, not the engine. Nothing
  moves locally; the server's echo moves every member. Audio track,
  subtitles, audio delay and speed stay local.
- **A report says where the engine is, not where it was.** `beginPlayback`
  anchors the clock before announcing the end of buffering. A Ready more than
  half a second off earns a corrective `Seek`, and a wrong report stalls the
  room.
- **Open the socket before joining.** Joining mid-handshake loses
  `GroupJoined` and the `PlayQueue` update, and the member never hears from
  the group again.
- **Leaving the player is not leaving the group.** `onClosed` posts
  `SetIgnoreWait(true)`; `rejoinPlayback()` reopens where the group is now,
  not where the last command pointed.
- **Waiting is not buffering.** A member primed and paused at the group's
  position is not stalled, and the spinner says so.
- Drift is corrected by `SyncCorrectionPolicy`: nothing under 60 ms, a rate
  nudge through `setCorrectionRate` up to 1.5 s, a seek beyond. Never by
  changing the viewer's `rate`.

To verify with two members: `-debug.syncPlayJoinGroup <name>` joins after the
regression bootstrap, and `-debug.playbackHUD YES` shows the `Sync:` line.

Opening, command handling, `SyncPlayGroupSession`'s refusal rules, the sheet
and panel tab, notices and account switching are in [Watch
Together](reference/playback/watch-together.md).

### The player's Observation scope

Observation subscribes to the reads that actually run, so:

- The player root never reads `timePosition`, current subtitle values or other
  tick-rate state in its body, modifier IDs or animation values. Those reads
  belong in small overlay leaves.
- Return before reading the playhead when there is no applicable segment or
  successor, and avoid position reads in the hidden timeline.
- The panel host's `Equatable` boundary separately shields its interior.
  Keep both boundaries.

See the [scope
measurements](reference/playback/controls-and-reporting.md#the-players-observation-scope)
and the engine's [memory
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/frame-loss-bench.md).

## Progress reporting

- `Sessions/Playing` once, progress every 10 seconds, and
  `Sessions/Playing/Stopped` exactly once after capturing the final position.
  Use the `Ticks` helpers.
- A reporting failure never interrupts playback.
- Presenting screens await `client.playbackReports.settle()` before fetching
  watch state after dismissal. API cache bypass and `MediaItem` value equality
  are both needed for the new resume point to reach the UI.
- Test far enough into a title to pass the server's resume threshold.

See [reporting
details](reference/playback/controls-and-reporting.md#progress-reporting).

## Controls and presentation

**iPhone and iPad controls:**

- A surface tap toggles the transport. Centre play/pause and ±10 s buttons use
  `.glass(.clear)`.
- While playing, controls fade after four seconds idle. Paused playback and
  VoiceOver keep them up (with the options sheet closed). Hidden controls
  disable hit testing and are accessibility-hidden. The layout stays mounted,
  so fading and toolbar safe-area changes cannot shift the centre cluster.
- Double-tapping either half seeks 10 s without revealing controls. Repeats
  within the 700 ms feedback window add up; changing direction resets.
- Dragging the timeline previews trickplay and commits on release. Skip and Up
  Next take direct taps. Close and Info are in the native toolbar. The options
  sheet suppresses surface interaction.
- Swipe up over free video opens the options panel. Swipe down drags the whole
  player and, past the threshold, minimizes it into Picture in Picture (or
  closes it where PiP is unavailable). The timeline drag and every button win
  over the swipe.
- The player follows device orientation and never forces a rotation. Audio
  uses movie-playback behavior: volume keys control output, and Silent Mode
  does not mute.

**Background (iOS).** Locking the phone or leaving the app keeps playing under
the `audio` background mode. The picture is dropped until the scene returns,
unless PiP or AirPlay shows it. Lock screen controls drive the engine. Skip
and Up Next are decided by `PlaybackAutomation` off the engine's clock, never
in a view body, so intros are skipped and the next episode starts with the
screen off. tvOS pauses on background. See [system
integration](reference/playback/system-integration.md).

**Countdowns:**

- Action and visible fill share a monotonic deadline, and only the fill
  redraws, so a newly mounted overlay shows elapsed progress at once.
- Countdowns run on wall time and can fall due during a stall. A skip due
  while buffering waits until the picture moves (seeking would spend the
  buffer the stall is waiting on), and is taken only if the playhead is still
  inside the segment. Select and a tap go straight through.
- An accepted hand-off keeps its card through `playNext` while the successor
  prepares, so the offer never looks withdrawn.

**iOS presentation:**

- A screen only _requests_ playback through `playerPresentation`. The single
  `playerPresentationHost` at the tab root, `PlayerPresentationHub`, presents
  it and keeps the hosting controller across PiP.
- The swipe down requests PiP; only PiP's successful start callback hides
  fullscreen. Restore reuses the same controller. Closing PiP or withdrawing
  the request cleans up, and `onDismiss` still reaches the requesting screen.
- **Never present the host from inside a `NavigationStack` destination.** A
  presenter in a pushed detail page closed the player about a second after it
  opened, from any detail page.
- The host is presented `.overFullScreen`. `.fullScreen` removes the
  presenting hierarchy and re-runs the `.task`s beneath, including the
  regression bootstrap.
- Physical PiP, background and caption acceptance are still open.

**tvOS:**

- The video surface owns focus. Select prioritizes scrub, Skip, Up Next, then
  play/pause.
- **A light Siri Remote touch is a separate input that reveals controls. It
  never becomes Select.**
- Menu cancels scrubbing, then closes the panel, then exits.
- Keep the mounted panel and remote command ordering intact.

See [remote
reveal](reference/playback/controls-and-reporting.md#siri-remote-transport-reveal)
and [tvOS
gotchas](reference/playback/controls-and-reporting.md#player-view-gotchas-learned-the-hard-way-on-tvos).

## Diagnostic reporting

Unexpected playback and request failures report automatically through
`Diagnostics.shared`: a vendor-neutral hub with a rolling history and an
app-owned Sentry envelope transport. There is no SDK.

- Only keys in `DiagnosticSchema.fields` leave the device. A title, URL,
  message or `localizedDescription` handed to it is dropped and counted.
- A new failure path gives `PlaybackEngineFailure` a `PlaybackFailureDetail`
  with stage, error domain and code; never rely on its message.
- Record the moment with `Diagnostics.record`, and report with a fingerprint
  that never varies per occurrence.
- Keep `record` cheap and off the pump queues. The hub already runs the sink
  on its own queue.

Detectors, thresholds, limits, tester controls and Sentry setup are in the
[diagnostics reference](reference/playback/diagnostics.md).

## Regression checks

- Build both platforms and run the relevant logic tests.
- `TouchPlayerUITests` covers iPhone/iPad touch and auto-hide.
  `PlayerRegressionUITests` covers remote input, reporting, handoff and
  teardown. Both pass on the simulator; physical checks are still owed.
- The [regression lane reference](reference/regression-lane.md) covers what a
  journey may assume about server and simulator state, and the resolver flags
  that open a title by property.
- XCTest can see faded buttons and nonzero frames despite
  `accessibilityHidden`. For auto-hide, assert the launch-gated `transport`
  state, toolbar disappearance and screenshots together. Use full-screen
  screenshots for landscape; app screenshots can be cropped.
- Simulator evidence does not establish physical VoiceOver or PiP acceptance.

Measurement:

- Background fill: `scripts/fill-bench.sh` plays one title hands-off on a
  simulator and reports cached and network megabytes over time from the decode
  trace, to compare two builds on the same asset and link.
- Performance: `scripts/framedrop-bench.sh` and
  `scripts/playback-lifecycle-bench.sh`. Compare the same fixture, scene,
  media-time window, build configuration and display path over at least three
  untouched runs. On device, compare Release builds without coverage or
  diagnostic overlays.
- Keep physical full-film, captions/HDR and teardown acceptance separate from
  simulator results.

See the [frame-loss
procedure](reference/playback/frame-loss-bench.md#frame-loss-bench).
