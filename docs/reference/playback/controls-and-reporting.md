# Progress reporting and player controls

The reasoning behind the controls and reporting rules in the [playback
guide](../../playback.md). See also the [notes index](README.md).

## Progress reporting

Positions are ticks ([Jellyfin API](../../jellyfin-api.md#wire-format)). Three
reports, all fire-and-forget via `try?` so reporting never interrupts
playback:

- `Sessions/Playing` once playback starts.
- `Sessions/Playing/Progress` every 10 s from a detached loop, with
  `IsPaused` from the engine.
- `Sessions/Playing/Stopped` exactly once from `stop()`, called on dismiss and
  guarded by `didReportStop`. This moves the server's resume point and
  reorders Continue Watching.

Screens underneath re-fetch in `fullScreenCover`'s `onDismiss`: detail pages
re-read the item (and, for a series, what is up next); Home re-reads Resume
and Next Up and republishes Top Shelf. Three invariants make that re-fetch see
the new position, and each alone was enough to break it:

- **Wait for the stop report.** It starts in the player's `onDisappear`, in
  the same run-loop turn as `onDismiss`, and takes about 2.5 s because the
  server tears the session down first. `JellyfinClient.playbackReports` (a
  `PlaybackReportLedger`) opens a session when `playbackSessionActive` is set
  and closes it when the stop report returns. Presenting screens await
  `settle()` before re-fetching. The wait is capped at 8 s and returns at once
  when nothing is open. Dismissal itself never waits.
- **Bypass the URL cache.** Jellyfin sends item JSON without cache headers,
  yet CFNetwork reused it (`cache_hit=true`). Every API request sets
  `reloadIgnoringLocalCacheData` and the client has no `urlCache`; images and
  the playback cache use their own sessions.
- **Compare `MediaItem` by value.** SwiftUI drops a `@State` write whose new
  value compares equal, so an id-only `==` meant the fetched item was stored
  but never rendered (and rails kept stale progress bars). Id-only identity
  lives in `ContentNavigationRoute`.

The `playback-reports` log category (subsystem `ee.helop.lagoon`) records the
stop report's position, outcome and how long `settle()` waited.

When re-testing, stop well into the runtime. The server keeps no resume point
before `MinResumePct` (5% by default) or after `MaxResumePct` (90%), so a
two-minute stop comes back as Play and a stop in the credits as played.

## Siri Remote transport reveal

A light tap on the touch surface reveals the transport and restarts its
four-second dwell. It never pauses, seeks, commits a scrub, accepts Skip or Up
Next, or moves focus, and is ignored while the control panel is open.

**A light touch-surface tap and a Select press are different inputs and never
share a path.** On tvOS the surface's SwiftUI `onTapGesture` fires on the
Select **press**, whose priority chain commits a scrub, skips an intro,
accepts Up Next or toggles pause. So `MenuPressGate` owns a second
`UITapGestureRecognizer`:

- `allowedPressTypes = []` is Apple's documented switch from Select presses to
  taps on a touchpad-like surface.
- `allowedTouchTypes = [.indirect]` is the trackpad touch type.
- `cancelsTouchesInView = false` keeps delivery to the hosted surface, so
  directional swipes still fail the recognizer and keep their focus and scrub
  path.

The tap calls `pokeControls()`, the path every interaction uses, so showing
the bar and resetting auto-hide cannot drift apart. XCUITest cannot produce a
light touch-surface tap; this is checked only on a physical remote.

`-debug.playerInputTrace YES` (Debug builds) logs a `PlayerInput` line for
every press, the path that took it (gate recognizer, `pressesEnded`,
`onTapGesture`, `onPlayPauseCommand`, touch tap) and the prompt, panel, scrub
and focus state it found. It goes through `NSLog`, so it shows in
`devicectl … --console` and in a simulator's unified log. Back and Select
reach the player by different paths on a Siri Remote than in the simulator,
so compare the two before trusting a simulator result for remote input.

## Putting controls in the transport (tvOS)

**Nothing in the transport is focusable, deliberately.** The overlay sets
`allowsHitTesting(false)` on tvOS and the surface always owns focus:
`onMoveCommand` lives on the surface, so the arrows stop scrubbing the moment
focus leaves it. The skip prompt and Up Next card are visible but unfocusable
and driven by Select. The remote is fully allocated except Up: Left/Right seek
or walk the scrub playhead, Down opens the panel, Menu cancels/closes/exits,
Play/Pause toggles. (A speed control was built there once and reverted.)

A focusable control there needs all of these:

1. The overlay becomes hit-testable (`allowsHitTesting(transportVisible)`).
2. Focusability is gated on `transportVisible`, or focus walks into a hidden
   control.
3. Auto-hide does not fire while it holds focus, or focus is stranded on a
   disabled control.
4. Down returns `playerFocus = .surface`, since the surface must own focus to
   scrub.

Platform limits, verified on device:

- **SwiftUI `Menu` never presents inside the player's `fullScreenCover`.** The
  button takes focus and Select does nothing; the HIG lists pop-up buttons as
  unsupported on tvOS. Build menus from ordinary buttons.
- **Focusable buttons inside another `Button`'s overlay never take focus.**
  Anchor a popup from outside: publish the corner with `anchorPreference` and
  place the popup as a sibling.
- **A default tvOS button has a minimum height of about 66 pt.** Only
  `.controlSize(.small)` changes it, short of drawing the focus lozenge by
  hand, which this codebase avoids.
- Use the current panel styles and the shared [focus
  strategy](../../design-system.md#focus-strategy): `.glass` for tvOS panel tabs
  and actions, native buttons for track rows, no `.glassProminent`, no
  foreground colours on focusable lozenges or their ancestors.

## Player view gotchas (learned the hard way on tvOS)

**Engine and ownership:**

- `CustomPlayerView` talks **only to the `PlayerEngine` protocol**.
- **No player view owns the engine.** A gesture closure once captured the view
  by value, SwiftUI kept that stale copy, and a strong `let engine` leaked one
  drained engine per Up Next handoff. Every view declares
  `@PlayerEngineRef var engine` (weak, memberwise initializer unchanged) from
  `Lagoon/Features/Playback/Views/PlayerEngineRef.swift`.
  `PlaybackController` is the only owner, `VideoPlayerView`'s surface builder
  captures `[weak]`, and a stale copy reads `DetachedPlayerEngine.shared`
  instead of crashing.
- On failure the engine is set to **nil** and replaced with an error overlay
  that has a Back button and `.onExitCommand`; a dead surface would swallow
  Menu and trap the viewer.
- Never nest `SharedState.withLock`: it is non-recursive and nesting caused a
  deadlock. `sample <pid>` names the stuck line when a queue wedges.

**Focus:**

- The video surface is focusable at **all** times, or Menu quits the app.
- The loading state is `LoadingView`, which is focusable, for the same reason.
- `defaultFocus` is honoured only when a fresh scene appears. A mid-screen
  reveal must set its `@FocusState` in code, immediately plus a settled retry.
- tvOS does not restore focus to the presenting screen after the player cover
  closes, so every presenter wraps in `.restoresFocusAfterPlayer(isPresented:)`
  (`Lagoon/Shared/UI/FocusRestoration.swift`: a focus scope plus `resetFocus`
  after the dismissal transition).
- Native buttons only; the system lozenge is the design.

**Scrub grammar:**

- Arrows walk a virtual playhead (`scrubTarget`) whenever the duration is
  known, playing or paused. Only a live stream (`duration == 0`) falls back to
  blind ±10 s seeks.
- Playback continues behind the chip, and nothing is restored on cancel. The
  _fill_ shows the live position (`fillMotion` stays on `liveMotion` on tvOS;
  easing per update stutters) while the _knob_ walks ahead. Touch is the
  reverse: the thumb drags the fill.
- A lone press is still a 10 s skip: the scrub commits itself after
  `ScrubMetrics.runExpiry` plus `ScrubMetrics.selfCommit` (600 ms each) of
  quiet. Both are hardware-tuned.
- Select/Play commits _and plays_ (native tvOS grammar). The self-commit
  timeout and iOS drags keep the previous play state. Menu cancels to the live
  position, so it outranks closing the panel in `MenuPressGate`.
- Walking accelerates 10 → 30 → 60 s. Up/Down hop chapters only mid-scrub
  (Down otherwise opens the panel and would strand the playhead); a backwards
  hop lands on the current chapter's start first.
- Chapter ticks are unlabelled (a film can have ~25); the chip names the
  chapter under the playhead.
- iOS seeks on release only; seeking per drag update would flush and
  re-demux every frame.

**Skip intro/recap:**

- `GET MediaSegments/{itemId}` is native to Jellyfin 10.10+, whatever plugin
  fills it. `includeSegmentTypes` wants _repeated_ query params and 400s on a
  comma-joined list, so filtering is client-side.
- Only `Intro` and `Recap` are skippable. `Preview` and `Commercial` appear
  mid-film in real libraries; `Outro` hands off to the next episode.
- Episodes quite often have **two `Intro` segments**, and one can start at
  tick 0. Both cases are handled; do not "simplify" to first-of-each.
- `SkipMode`: auto after delay (default: 5 s fill then commit), instant, or
  ask every time. Menu dismisses the pill in both modes that draw it.
- **The button is not focusable**, since focus would pull `onMoveCommand` off
  the surface. It extends the priority chains instead: Select commits a
  scrub, else skips, else toggles pause; Menu cancels a scrub, else dismisses
  the pill or the Up Next card, else closes the panel, else exits. A prompt
  is a layer above the player, so Back answers it first, countdown or not
  (HIG, Playing video: give people a clear way to dismiss an overlay). The iOS pill takes a
  direct tap.
- `handledSegmentIDs` marks a segment before seeking, or landing near its end
  re-enters it and re-arms everything.

**Autoplay the next episode:**

- `PlaybackController.playNextEpisode()` reports the finished episode stopped,
  resets one-shot state and starts the next, in the same player.
  `AutoplayMode`: automatic (default), ask every time, off. The countdown is
  5 s, matching `SkipMode`.
- The player and its `AVSampleBufferDisplayLayer` stay mounted across the
  handoff. In the last 120 s the controller negotiates the successor's
  PlaybackInfo and warms its first 8 MiB (direct file) on the same
  cooperative scheduler, replacing the current title's proactive fill so
  credits never carry two downloads. Advancing reports the old session
  stopped and retires its demuxer and synchronizer; only when the lifecycle
  counters reach zero does `SampleBufferVideoSurface.updateUIView` attach the
  successor to the same layer. Never overlapping decoders.
- Presentation survives the boundary: the old frame stays under a
  non-focusable "Starting next episode" overlay, PiP swaps its transport
  delegate but keeps the content source, and audio session, Now Playing and
  tvOS display-match ownership stay put.
- An `Episode Handoff` signpost measures the advance to the successor's primed
  clock. The hardware journey injects a seven-second renderer-retirement delay
  so the single-pipeline invariant is tested.
- **Never resolve the next episode from `Shows/NextUp`**: before the stop
  report lands it returns the episode that just ended, and autoplay loops.
  `episodeAfter(_:)` uses
  `Shows/{seriesId}/Episodes?startItemId=<current>&Limit=2` and takes index 1.
  It checks that item 0 _is_ the anchor; a mismatch means the server started
  from the top, and rolling into episode 1 is worse than doing nothing.
- **Two anchors.** With an `Outro` segment, the card appears at its start and
  counts down from there. Without one, the card appears on a fixed 15 s
  run-out, with the fill pinned to the last 5 s of the file.
- **Track choices carry over by language and title, not ordinal**, since a
  commentary track on one episode shifts every ordinal below it.
  Subtitles-off carries over as its own choice. A carry that matches no
  track on the next item falls back to the viewer's automatic pick, for
  subtitles as for audio, never to the server's default. An external sidecar whose URL
  does not resolve must leave both the stream list and the engine's list, or
  later ordinals name the wrong track.
- **A cancel outlives the card.** Back sets `nextUpDismissed`, but the credits
  keep running and `didFinish` would autoplay over the "no". So
  `onCancelNextUp` reaches `VideoPlayerView`, which holds the flag until the
  next episode starts. `didFinish` still advances when nothing was cancelled,
  and `playNextEpisode` is guarded by `isAdvancing` against running twice.
- The card is **not focusable**, like the skip pill, and shares the
  bottom-trailing shelf (intros are at the start, credits at the end). Its
  background is `.regularMaterial`: white credits show through any flat scrim.

**Trickplay** (Jellyfin 10.9+):

- `BaseItemDto.Trickplay` is `[mediaSourceId: [width: TrickplayInfo]]`, and
  `Interval` is **milliseconds**. `Videos/{id}/Trickplay/{width}/{n}.jpg`
  returns one sprite sheet per `TileWidth × TileHeight` grid (10×10 at 10 s
  covers about 16 minutes).
- The route **401s without credentials**, so `TrickplayLoader` builds its
  request through `MediaRequestAuthorization` (header, not URL).
- A sheet is about 23 MB decoded, so the loader keeps its own two sheets
  separate from `ImageCache`. It caps responses at 16 MiB and its compressed
  cache at 32 MiB, and cancels obsolete transfers while keeping the previous
  frame.
- Tile crops come from the _decoded_ sheet's size: decode caps sheets at
  3200 px, and the last sheet is only partly filled.

**Other:**

- Chapters and trickplay are fetched by the player (`playbackExtras`,
  alongside PlaybackInfo), not taken from the `MediaItem`, because rail list
  requests omit those fields. Both degrade to nothing when absent.
- A faded overlay **still hit-tests**. The transport gates `allowsHitTesting`
  on its own visibility, or the invisible iOS scrubber swallows drags; tvOS
  keeps the whole transport non-hit-testable.
- **`onExitCommand` never fires inside a `fullScreenCover` on tvOS 26.**
  UIKit consumes Menu and dismisses the cover, and
  `interactiveDismissDisabled` does not stop it. `MenuPressGate` owns the
  policy (panel open closes the panel, else dismiss explicitly) and needs
  **both** layers:
  - A real `.menu` press is taken by UIKit's dismissal gesture recognizer
    before any responder, so only our own `UITapGestureRecognizer`
    (`allowedPressTypes = [.menu]`) pre-empts it. Responder overrides alone
    let Menu kill the player on hardware.
  - The simulator's Escape arrives as a keyboard press (never `.menu`), so
    `pressesEnded` must catch `key?.keyCode == .keyboardEscape`.
  Each environment exercises only one path.
- **Nothing that appears inside the player can use a transition; animate
  values instead.** The animation transaction does not cross the
  `MenuPressGate` hosting boundary (`rootView` reassignment), so
  `withAnimation` lands instantly while `.animation(_, value:)` inside the
  hosted tree works. `.transition()` on an inserted view never runs. The panel
  therefore stays mounted and slides with `.offset` + `.opacity`, with
  `.disabled(!panelOpen)` keeping it out of the focus engine when closed.
  Verify animations by recording (`simctl io recordVideo`, then step frames
  with `AVAssetImageGenerator`), not screenshots.

### Player panel performance

- The Debug-only Player Panel preview has a deterministic 30-track subtitle
  fixture. `PlayerRegressionUITests.testPlayerPanelPreviewPerformance` sweeps
  Info → Subtitles → Info five times, recording app CPU, instructions, memory,
  wall time and hitches, and walks focus through every fixture row so lazy
  construction cannot break remote navigation.
- Hard gates: one six-tab sweep under 1.75 s, and the full sweep plus 30-row
  walk may grow the footprint by at most 12 MB.
- Wall time is remote-input-bound (about 1.3 s) and peak memory sits in a
  64–80 MB band; treat movement in that band as noise unless it crosses
  XCTest's 10% tolerance. CPU and instruction counts are where panel work
  shows. Narrowing `GlassEffectContainer` from the whole panel to the four tab
  controls moved them most.
- Release builds emit a `Player Panel Reveal` interval in the
  `ee.helop.lagoon/PlaybackPerformance` signpost category. Use it with the
  Animation Hitches instrument on a physical Apple TV, where GPU composition
  is representative.
- `testLivePlayerPanelSweepPerformance` runs the same sweep over live playback
  to include the player's per-tick work. It has no timing assertion; only the
  CPU figures move.

The public demo covers navigation, generic playback, lifecycle and panel
tests but has no subtitle, multi-audio, chapter or intro fixtures; those tests
skip explicitly. To run them against a private library:

```sh
TEST_RUNNER_LAGOON_REGRESSION_SERVER='https://example.test' \
TEST_RUNNER_LAGOON_REGRESSION_USER='Regression' \
TEST_RUNNER_LAGOON_REGRESSION_PASS='…' \
xcodebuild test -project Lagoon.xcodeproj -scheme LagoonHardwareRegression \
  -destination 'platform=tvOS Simulator,name=Apple TV,OS=latest'
```

**The `TEST_RUNNER_` prefix is required.** `xcodebuild` forwards only
variables with that prefix to the runner, stripped. Without it the app quietly
falls back to the public demo and fixture tests fail as if the player were
broken. The values reach the DEBUG-only bootstrap through the launch
environment and are never persisted or compiled into Release.

#### The player's Observation scope

Observation tracks reads **per body**. When `CustomPlayerView` had one flat
scope, a single `engine.timePosition` read re-evaluated the whole player ten
times a second (surface, subtitles, overlays, transport, panel host), and on
tvOS reassigned the hosting controller's `rootView` each tick. On an Apple TV
that was `main=229–267 ms` per two-second window during plain playback.

The fix is a scope split. Everything that follows the playhead is its own
view reading tick-rate properties in its own body:

- `PlayerTransportOverlay` (its `PlayerScrubber` and `PlayerTimelineLabels`
  are the two leaves that legitimately tick)
- `PlayerSubtitleOverlay`, `PlayerSkipOverlay`, `PlayerNextUpOverlay`
- `PlayerRegressionValue`, a `ViewModifier` because a modifier has its own
  body and the tvOS probe must decorate the focusable surface, not a sibling
  that would steal arrow focus

Their `@State` moved with them (`autoSkipFill`, `nextUpFill`), each armed by a
`.task(id:)` keyed on its transition _and_ `playbackIdentity`, so autoplay
cannot inherit the old episode's fill. The parent hears real transitions
through closures (`onSkip`, `onPlayNext`, …), never per tick.

Two rules, both easy to break:

- **Nothing in `body`/`playerContent`, or in the `id:`/`value:` of a modifier
  on them, touches `timePosition`, `currentSubtitle*` or any other tick-rate
  property.** `isPaused`, `isBuffering`, `duration`, `subtitleLoadState` and
  `videoSize` change per item or action and are fine. `activeSegment` and
  `showsNextUp` read the position and are used only in `handleMenu`,
  `onTapGesture`, `onMoveCommand` and `onPlayPauseCommand`; reads in a closure
  that runs later are not body reads.
- **A leaf that can answer without the position must not read it.**
  `PlayerSkipOverlay` returns nil before reading `timePosition` when there is
  no skippable segment, and `PlayerNextUpOverlay` when there is no successor
  or autoplay is off (every movie). The read is the subscription.

The hidden transport stays mounted at opacity 0 for the fade; its scrubber
and timeline take an `isVisible` flag and read `engine.timePosition` only on
the visible branch, so a hidden transport shows the last position and holds
no subscription.

`PlayerControlPanelHost`'s `Equatable` boundary is separate and still needed:
it stops the panel's interior re-rendering when the player does.

Measured main-thread time per two-second window, plain playback, no chrome:

| Change | Where | Before → after |
| --- | --- | --- |
| Scope split | tvOS simulator, median | 61 → 34 ms |
| Scope split | Apple TV 4K (3rd gen), Release, Dolby Vision + CC, median | 259 → 186 ms |
| Hidden transport stops reading | tvOS simulator, median | 32.5 → 16.5 ms |

The live panel sweep barely moved (app CPU 0.384 → 0.375 s), as expected:
with the panel open the overlays are suppressed and the interior is already
behind its `Equatable` boundary. The gain is in ordinary playback.
