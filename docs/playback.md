# Playback

All media plays through `PlayerEngine` and Lagoon's sample-buffer engine. The
UI uses that protocol. Do not add an alternative AVPlayer or mpv path. Read
this guide before changing player behavior, then follow the focused links into
the [engineering notes](reference/playback/README.md) for implementation
details.

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
owns the session. `Views/VideoPlayerView.swift` retains it with `@State`.
Surfaces, controls, overlays and PiP presentation live in `Views/`.

The demux/decode/render pipeline is **not in this repository**. It is the
`LagoonEngine` package, which knows nothing of Jellyfin, accounts or SwiftUI:
it is handed a media source, track metadata and an optional credential, and it
returns a picture and a verdict. Its guides live with it — start at [the
engine guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md).
What stays here is everything that decides *what* to hand it and what to do
with what comes back.

## Network transport

The engine owns the transport: every HTTP open goes through URLSession, and
its libavformat has no network stack. The app's part is the credential.

Build media authorization in the shared helpers and hand it to the engine with
the request. Credentials travel in the authorization header, never in
token-bearing URLs. Keep endpoint and cross-origin rules in the shared
authorization helpers rather than at call sites. The size-capped fetches
`BoundedDownload` applies are a transport safeguard, not the offline Downloads
feature: see [Downloads](#downloads) for the feature that keeps a whole file
on disk.

## Stream resolution

`DeviceProfile` advertises the current device's supported codec envelope.
Jellyfin negotiation and the failure-driven delivery ladder choose direct
play, remux, then video transcode. Only the re-encode rung has the 1080p
ceiling. Do not confuse remux selection with `SupportsDirectStream`. Preserve
the failure cause and resume position when moving down a rung.

Descend only on the engine's verdict. `.undecodable` skips the remux rung and
is one-way: it costs a reload, the embedded subtitle tracks, and server CPU
per viewer. A failure that says nothing about the bitstream must never reach
it.

The engine is responsible for not faking that verdict — a decode session the
system reclaimed is rebuilt rather than reported as undecodable, and a
just-flushed renderer refuses a sample the container does not call a keyframe.
Both guards, and the measurements behind them, are in the engine's [stream
recovery notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/stream-recovery.md).
What this side must not do is treat a `.delivery` verdict as a reason to
re-encode.

Progressive H.264 uses the compressed sample-buffer path. Interlaced H.264 is
software-decoded and deinterlaced, on the stream's probed field order, never
the server's flag. HEVC is decoded ahead through VideoToolbox. AV1 uses
hardware where available and the repo-built dav1d otherwise. Other supported
legacy/software codecs use bounded software decode. Codec limits and HDR
routing belong in the existing profile and decode policy, not duplicated
checks in views. iOS metered-path limits affect both static and streaming
bitrate offers and can be overridden in Playback settings.

HDR10+ needs no handling of its own, and code to "add" it would be code that
does nothing. VideoToolbox stamps the dynamic metadata onto every decoded
frame itself — an undocumented `HDR10PlusData` pixel-buffer attachment
carrying the T.35 payload verbatim, country code 0xB5 first — it rides the
frame through the queues to the renderer, and tvOS engages HDR10+ on a
display that supports it. Verified 2026-09-21 on an Apple TV 4K 3rd
generation driving an HDR10+ Samsung panel, reading the TV's own Picture Mode
badge: a `HDR10Plus` title reports HDR10+, and so does a `DOVIWithHDR10Plus`
title whose track carries our supplementary `dvvC`. On a display with no
Dolby Vision the system falls back to the base layer and still uses its
HDR10+ metadata, so the Dolby Vision tagging costs nothing there and no
display-capability check is needed. A `DOVIWithHDR10` title reports plain HDR
on the same panel, which is what rules out a display that simply badges
everything.

Two traps sit around measuring this. Screen mirroring from the Apple TV
suppresses HDR output entirely, so any badge read while it is on is
worthless — that confound produced an afternoon of false negatives and a
wrong diagnosis before it was spotted. And the badge is not shown at all in
the panel's Filmmaker Mode, so a missing badge there means nothing either
way.

E-AC-3 JOC keeps its compressed Atmos path. TrueHD decodes to lossless LPCM.
Its Atmos objects are not preserved. Subtitles come from embedded streams or
Jellyfin's permission-gated subtitle routes. There is no direct provider
login. Disc images use the app's bounded byte source and UDF handling.

See [negotiation and
delivery](reference/playback/stream-resolution.md#stream-resolution), [disc
images](reference/playback/stream-resolution.md#disc-images), and
[decode
details](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/decode.md).

### Audio track selection

`TrackSelectionPolicy` chooses automatically: the viewer's audio mode, then
their preferred languages, then Jellyfin's default. Some releases defeat all
three. The 100's season-one remux carries five audio streams with no language,
no title and no default flag. Four of them are identical DTS 5.1, and the
first is Russian. `DefaultAudioStreamIndex` names that first stream, because
the server had nothing to go on either, so every mode lands on it.

Where metadata cannot decide, the viewer's correction does.
`AudioTrackMemoryStore` holds one audio choice per series, or per item for a
film, per account. It writes through to `UserDefaults`, so a correction
survives closing the player, not just an autoplay handoff.

Record the choice when the viewer makes it, from the engine's
`onTrackSelectionChanged`. Only `selectAudioTrack` fires it, and only the
track panel and the system now-playing menu call that, so everything stored is
deliberate. Reading the selection back at exit looks equivalent but is not: by
then the scope, layout and live engine can each belong to the next episode,
and a viewer who left a non-applying memory alone would lose the whole show's
correction. The write is identity-guarded to the current engine and skipped
when the engine's track count disagrees with the server's layout — a remux or
transcode rung delivers one track where the source lists several, so an
ordinal from one means nothing in the other. Landing on what automatic
selection would have chosen _forgets_ the override rather than storing it,
which would freeze the show against a later change of preferences.

`AudioTrackMemoryPolicy` applies it as a ladder: a description that names
exactly one track, then the remembered position against a layout whose
fingerprint is unchanged, then the first track of the right language.
Ambiguity is failure rather than a coin flip. Position is what expresses a
choice between tracks tagged identically and tracks tagged not at all. It
never overrules a description that identifies something specific. A release
that gains proper tagging or an added commentary track retires it.

Match on `MediaStream.title`, never `displayTitle`. Jellyfin synthesizes the
latter from codec and channel layout, so all four of those DTS tracks display
as `DTS-HD MA - 5.1`. Matching on it silently returns the first one rather
than the track the viewer picked. The engine appends the position to track
names that collide, because otherwise the rows cannot be told apart in the
panel or recognised again afterwards.

### Subtitle track selection

The same ladder, in the subtitles' own ordinal space: embedded tracks first,
then external ones, with 0 meaning none. `SubtitleTrackMemoryStore` holds one
choice per series per account, beside the audio one and under its own key.
Both are `TrackMemoryStore`, which owns the re-read, merge, evict and persist
mechanism the two would otherwise keep two copies of; the policies stay apart,
because what makes a layout's shape differs and because off is an answer here.

Off is the difference worth knowing. There is no such thing as no audio, but
"no subtitles" is a deliberate choice and the one a server default is most
likely to overrule on the next episode, so it is stored like any other — and
it describes no track, so no layout change can retire it. A layout's shape
includes forced, hearing-impaired and external, because those are exactly the
distinctions a release makes between tracks that otherwise share a language.
Subtitle search appends tracks while the episode plays, so the engine can list
more than the layout captured at the start. The captured prefix still lines
up: the write asks for at least as many rather than exactly as many, and
refuses an ordinal naming one of the appended tracks, which would mean nothing
next episode.

## Lifecycle and memory

These are the app's obligations. The engine's own lifecycle and memory
invariants — two-phase stop, never reviving a stopped engine, queue
watermarks, decoded-frame byte budgets — are stated and evidenced in [the
engine guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md#lifecycle).

- The controller owns the engine. SwiftUI player views hold it through
  `@PlayerEngineRef`. View builders and gesture closures must not capture an
  engine strongly, because SwiftUI can retain old view values after an episode
  handoff. This is the rule the engine cannot enforce for us, and the one that
  has regressed most often.
- Network reporting never blocks dismissal.
- The byte cache belongs to the engine, not to this repository. `prepare`
  takes an item ID and a delivery and decides for itself whether to cache;
  `stageSuccessor` warms the next episode; `bufferState` is what a scrub bar
  reads back. Nothing here builds a cache session or runs a fill loop — every
  input that paces one is engine state. There is still one active scope and at
  most one staged successor, and the engine enforces it across engine
  replacements: exit, failure, account replacement and handoff retire the
  appropriate scopes. The cache is transient playback storage, not an offline
  library.
- Do not replace queue ownership with unstructured tasks as part of a file
  reorganization.

### Downloads

Before negotiating, and before consulting a prepared successor, the controller
asks `DownloadStore` whether the item is a finished download. When one exists,
playback never touches the network to start: negotiation, `playbackInfo` and
`streamURL` are skipped outright, the method is direct play, and the stream is
the file on disk. This keeps the existing rule that a local file needs no
cache in front of it: the engine opens no scope for a file URL, so a
downloaded title plays with nothing in front of it, the same as any other
file on disk.

Track metadata depends on what was downloaded. An original-quality download is
the stored file, so its source's stream list still describes it and drives
audio and subtitle selection exactly as a negotiated stream would. A
high/standard download is a transcode the server built for offline use: a
different container carrying one audio track and no external subtitles. Its
source's stream list does not describe the file on disk, so the controller
hands the engine empty track metadata rather than stale descriptions. Both the
engine's own track construction and the ordinal selection policies already
degrade to what the file demuxes to when given nothing. The picker panel
reflects whatever the engine finds. Only the language and title labels are
lost for a transcode, not track selection itself.

A downloaded title also has no chapters, trickplay, or skip segments. The
garnish requests that ride alongside negotiation for a streamed title are
skipped rather than awaited, since asking an unreachable server for them would
burn the client's full request timeout before the engine ever starts. Losing
chapters, trickplay, and skip segments offline is an accepted gap for this
feature's first pass. The start report follows the same reasoning: it fires
without being awaited for a downloaded title, so a server the device cannot
currently reach never delays the progress loop, HUD, or next-up warm-up.

Position handling runs in both directions. Starting a downloaded title prefers
its own locally recorded resume point over the server's last known position,
since there was no negotiation to fetch a fresh one. Choosing to start from
beginning still starts at 0 for a downloaded title, exactly as it does for a
streamed one. Stopping one records the position back through
`DownloadStore.recordPosition`, cleared once the position lands in the last 2%
of the runtime, so a downloaded title resumes correctly the next time it plays
with no server involved. Whether or not an item is downloaded, a stop report
the server refuses or cannot reach is queued as a `PendingPlaybackReport` and
flushed on reconnect, so a session's true stopping point is never silently
lost to a bad connection.

### Group transport hooks

Jellyfin SyncPlay makes the server the transport authority. The engine
exposes four hooks for exactly this case — `clockPosition`,
`play(atHostTime:)`, `setCorrectionRate(_:)` and `onSeekReady` — and [the
engine guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md#driving-the-clock-from-outside)
states what each one promises. Two of those promises matter constantly on this
side: `clockPosition` is the synchronizer's clock and never the optimistic
position a seek moves before anything is demuxed, which is what a Buffering
report must carry; and `setCorrectionRate(_:)` is not `rate`, which stays the
viewer's own choice and is what the speed row and Now Playing publish.

The controller is the boundary: a group driver never holds the engine. It
starts playback through `start(startPosition:startPaused:)`. The server's
position outranks every resume rule, and a member can sit primed and paused
until the group starts. The driver also drives `playGroup(atHostTime:)`,
`pauseGroup()`, `seekGroup(to:)` and `setCorrectionRate(_:)`, reads
`clockPosition` and `isPrimedAndPaused`, and hears about readiness and
dismissal through `onEngineReady` and `onClosed`. Keeping the group transport
separate from the viewer-facing controls is deliberate: the driver will later
intercept the viewer's Play and Pause and turn them into group requests, and
needs a way back down to the engine that does not recurse into itself. Because
the wiring lives in `start`, an episode handoff or a delivery fallback carries
it onto the successor engine for free.

### Watch Together (SyncPlay)

A group makes the server the transport authority. `SyncPlayStore`
(`Lagoon/Features/SyncPlay/`) owns membership: the socket, the clock, the
group and its queue. `GroupPlaybackDriver` owns everything that touches
playback, holding the controller weakly and the engine not at all.

The rules that must not be broken:

- **The viewer's transport is a request.** Play, pause, seek, skips, scrub
  commit and lock screen all reach `groupTransport` rather than the engine.
  Nothing moves locally; the server's echo moves every member. Audio track,
  subtitles, audio delay and speed stay local — they are the viewer's, not the
  group's.
- **A report says where the engine is, not where it was.** `beginPlayback`
  anchors the clock before announcing the end of buffering. A Ready more than
  half a second out gets a corrective `Seek` from the server, and a report that
  lies stalls the room it was meant to release.
- **The socket must be open before the join.** Joining mid-handshake loses
  both `GroupJoined` and the `PlayQueue` update, and the member never hears
  from the group again.
- **Leaving the player is not leaving the group.** `onClosed` posts
  `SetIgnoreWait(true)`; `rejoinPlayback()` reopens at wherever the group has
  reached, never at the position the last command named.
- **Waiting is not buffering.** A member primed and paused at the group's
  position is not stalled, and the spinner says so.

Drift is corrected by `SyncCorrectionPolicy` — nothing under 60 ms, a rate
nudge through `setCorrectionRate` up to 1.5 s, a seek beyond that — never by
touching the viewer's `rate`.

Verifying it takes two members: `-debug.syncPlayJoinGroup <name>` joins after
the regression bootstrap, and `-debug.playbackHUD YES` shows the `Sync:` line.

Opening and command handling, the refusal rules in `SyncPlayGroupSession`, the
sheet and panel tab, notices, and the account-switch behaviour are in [Watch
Together](reference/playback/watch-together.md).

### The player's Observation scope

The player root must not read `timePosition`, current subtitle values, or
other tick-rate state in its body, modifier IDs, or animation values. Those
reads belong in small overlay leaves. Return before reading the playhead when
there is no applicable segment or successor. Avoid position reads in the
hidden timeline. Observation subscribes to reads that actually execute.

The panel host's `Equatable` boundary separately protects its interior from
unnecessary renders. Preserve both boundaries. See the [scope
measurements](reference/playback/controls-and-reporting.md#the-players-observation-scope)
and [memory/lifecycle
notes](reference/playback/frame-loss-bench.md#decoded-frame-memory-ceiling).

## Progress reporting

Send `Sessions/Playing` once, progress every 10 seconds, and
`Sessions/Playing/Stopped` exactly once after capturing the final position.
Use the existing `Ticks` helpers. Reporting failure must not interrupt
playback.

Presenting screens await `client.playbackReports.settle()` before fetching
watch state after dismissal. Keep API cache bypass and `MediaItem` value
equality: both are needed for the fetched resume point to reach the UI. Test
far enough into a title to pass the server's configured resume threshold. See
[reporting
details](reference/playback/controls-and-reporting.md#progress-reporting).

## Controls and presentation

On iPhone and iPad, a surface tap toggles transport visibility. Centered
play/pause and ±10-second buttons use `.glass(.clear)`. While playing,
controls fade after four seconds without interaction. Paused playback and
VoiceOver keep them available with the options sheet closed. Hidden controls
disable hit testing and are marked accessibility-hidden. Keep the layout
mounted, so fading and toolbar safe-area changes cannot move the center
cluster.

Double-tapping either half seeks ten seconds without revealing controls.
Repeated double-taps within the 700 ms feedback window accumulate the shown
amount. Changing direction resets it. Dragging the timeline previews trickplay
and commits on release. Skip and Up Next accept direct taps. Close and Info
live in the native toolbar. The options sheet suppresses surface interaction.
Close closes the player outright. A swipe up over free video opens the options
panel. A swipe down carries the whole player with the finger, YouTube-style,
and past the threshold minimizes it into the phone's popup player, which is
Picture in Picture. Where PiP is not possible, it closes instead. The
timeline's own drag and every button win over the swipe, based on viewer
feedback.

On iPhone and iPad, locking the phone or leaving the app keeps playback going.
Audio continues under the `audio` background mode. The picture is dropped
until the scene is back, unless PiP or AirPlay is still showing it. The lock
screen's controls drive the engine. Skip and Up Next are decided by
`PlaybackAutomation` off the engine's clock, never in a view body, so intros
are still skipped and the next episode still starts with the screen off. The
overlays only draw its state.

Each countdown's action and visible fill share a monotonic deadline. Only the
fill redraws, so a newly mounted overlay shows elapsed progress immediately
rather than animating from a previous value — which is why both fills used to
read as full for their whole run.

A countdown runs on wall time, so it comes due during a stall as readily as
during playback. The commit waits: a skip due while buffering is held until
the picture moves, because seeking spends the very buffer the stall waits on.
It is taken up only while the playhead is still inside its segment — past the
end, seeking would drag the viewer back through an intro they have watched.
Select and a tap go straight through.

An accepted hand-off keeps its timing: the card outlives `playNext` while the
successor is prepared. A bar that emptied underneath it would read as the
offer being withdrawn. tvOS pauses on background as before. See [system
integration](reference/playback/system-integration.md).

The player follows the device on iPhone and iPad. It never forces a rotation.
A title opened in portrait plays letterboxed in portrait until the viewer
turns the phone. This replaced an earlier landscape lock, based on viewer
feedback. Audio uses normal movie-playback behavior. Volume keys control
output, and Silent Mode does not silence the movie.

On iOS, a screen only _requests_ playback, through `playerPresentation`. The
one `playerPresentationHost` at the tab root, `PlayerPresentationHub`,
presents it and retains the hosting controller across PiP. The swipe down
requests PiP when available. Only its successful start callback hides
fullscreen. Restore reuses the same controller. Closing PiP or withdrawing the
request cleans up the session, and `onDismiss` still reaches the requesting
screen. Physical PiP, background, and caption acceptance remain open.

Never present the host from inside a `NavigationStack` destination again. That
regressed once: a presenter hosted in a pushed detail page made the stack
briefly show its root, a view update in that window dropped the destination,
and its teardown closed the player about a second after it opened, from any
detail page. Only Home and Continue Watching, which are not pushed, survived,
which is why it looked title-dependent. The host is presented
`.overFullScreen`. `.fullScreen` removes the presenting hierarchy and re-runs
the `.task`s underneath, the regression bootstrap included.

On tvOS, the video surface owns focus. Select prioritizes scrub, Skip, Up
Next, then play/pause, in that order. A light Siri Remote touch is a separate
input that reveals controls. It must never become Select. Menu cancels
scrubbing, then closes the panel, then exits. Keep the mounted panel and
remote command ordering intact. See [remote
reveal](reference/playback/controls-and-reporting.md#siri-remote-transport-reveal)
and [tvOS
gotchas](reference/playback/controls-and-reporting.md#player-view-gotchas-learned-the-hard-way-on-tvos).

## Diagnostic reporting

Unexpected playback and request failures are reported automatically through
`Diagnostics.shared`. It is a vendor-neutral hub with a rolling history and a
Sentry envelope transport that the app owns itself. There is no SDK. Only keys
in `DiagnosticSchema.fields` can leave the device. A title, URL, message, or
`localizedDescription` handed to it is dropped and counted instead. When
adding a failure path, give `PlaybackEngineFailure` a `PlaybackFailureDetail`
with a stage, error domain, and code, rather than relying on its message.
Record the moment with `Diagnostics.record`, and report it with a fingerprint
that never varies per occurrence. Keep `record` cheap and off the pump queues.
The hub already runs the sink on its own queue. Detectors, thresholds, limits,
tester controls, and the Sentry setup are in the [diagnostics
reference](reference/playback/diagnostics.md).

## Regression checks

Build both platforms and run the relevant pure logic tests. Use
`TouchPlayerUITests` for iPhone/iPad touch and auto-hide, and
`PlayerRegressionUITests` for remote input, reporting, handoff, and teardown.
The simulator journeys pass in both suites. Physical checks are still owed.
The [regression lane reference](reference/regression-lane.md) covers what a
journey may assume about the server and the simulator's state, and the
resolver flags that open a title by property.

XCTest can expose faded buttons and nonzero frames even with
`accessibilityHidden`. For auto-hide, assert the launch-gated `transport`
state, toolbar disappearance, and screenshots together. Use full-screen
screenshots for landscape. App screenshots can be cropped. Simulator evidence
does not establish physical VoiceOver or PiP acceptance.

For background fill, `scripts/fill-bench.sh` plays one title hands-off on a
simulator. It reports cached and network megabytes over time from the decode
trace, so two builds can be compared on the same asset and link. For
performance, use `scripts/framedrop-bench.sh` and
`scripts/playback-lifecycle-bench.sh`. Compare the same fixture, scene,
media-time window, build configuration, and display path over at least three
untouched runs. Release measurements without coverage and diagnostic-overlay
interference are the useful device comparison. Keep physical full-film,
captions/HDR, and teardown acceptance separate from simulator results. See the
[frame-loss
procedure](reference/playback/frame-loss-bench.md#frame-loss-bench).
