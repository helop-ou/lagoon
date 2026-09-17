# Progress reporting and player controls

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [current playback guide](../../playback.md) and the
[notes index](README.md).

## Progress reporting

Positions are ticks (see jellyfin-api.md). Three report points, all fire-
and-forget (`try?` — reporting must never interrupt playback):

- `Sessions/Playing` once playback starts.
- `Sessions/Playing/Progress` every 10 s from a detached loop, including
  `IsPaused` from the engine.
- `Sessions/Playing/Stopped` exactly once from `stop()` (guarded by
  `didReportStop`), called on dismiss. This is what moves the server-side
  resume point and reorders Continue Watching.

The screens underneath re-fetch in `fullScreenCover`'s `onDismiss`: the detail
pages re-read the item (and, for a series, what is up next), Home re-reads its
Resume/Next Up rails and republishes the Top Shelf (HEL-119). Until HEL-132
that re-fetch never reached the screen, for three separate reasons, each of
which would have been enough on its own — and each fix is a live invariant:

- **It raced the stop report.** The report only starts from the player's
  `onDisappear` (Menu calls `dismiss()` directly), which lands in the same
  run-loop turn as `onDismiss`, and against the fixture server it takes about
  2.5 s to return because the server tears the session down before answering —
  so the GET always read the position from before it.
  `JellyfinClient.playbackReports` (a `PlaybackReportLedger`) closes the gap:
  the controller opens a session in it the moment `playbackSessionActive` is
  set and closes it when the stop report returns, and every presenting screen
  awaits `settle()` before re-fetching. The wait is bounded (8 s) so a vanished
  server costs one pause rather than a hang, and returns at once when nothing
  is open; dismissal itself never waits on the network, only the re-fetch does.
- **URLSession answered from its cache.** Jellyfin sends item JSON with no
  cache headers at all and CFNetwork still kept and reused it
  (`cache_hit=true` in its own log), so every API request sets
  `reloadIgnoringLocalCacheData` and the client runs without a `urlCache`;
  images and the playback cache have their own sessions.
- **The write never re-rendered.** `MediaItem` compared equal by id alone, and
  SwiftUI drops a `@State` write whose new value compares equal to the old one,
  so the fetched item with the new resume point was written, readable, and
  never rendered. `MediaItem` now compares by value and the id-only identity
  moved to `ContentNavigationRoute`, the one place that wanted it. The same bug
  explains rails whose cards kept a stale progress bar across a refresh that
  did not change item ids.

`playback-reports` in the unified log (subsystem `ee.helop.lagoon`) carries the
stop report's position and outcome and how long `settle()` waited.

When re-testing this, leave the title well into its runtime: the server keeps
no resume point inside the first `MinResumePct` (5 % by default) or past
`MaxResumePct` (90 %), so stopping a two-hour film after two minutes
legitimately comes back as Play, and stopping in the credits comes back as
played.

## Siri Remote transport reveal

A light tap on the Siri Remote touch surface reveals the transport and restarts
its four-second dwell (HEL-134). It is deliberately informational: the tap
never pauses, seeks, commits a scrub, accepts a Skip/Up Next offer, or moves
focus, and it is ignored while the control panel is open because the panel
already owns the screen and the remote.

It cannot share the surface's SwiftUI `onTapGesture`, because on tvOS that
gesture is the Select **press**, whose priority chain commits a scrub, skips an
intro, accepts Up Next, or toggles pause. `MenuPressGate` therefore owns a
second `UITapGestureRecognizer` with `allowedPressTypes = []` (Apple's
documented switch from the Select press to a tap on a touchpad-like surface),
`allowedTouchTypes = [.indirect]` (the trackpad touch type), and
`cancelsTouchesInView = false`, so a recognized, non-destructive reveal does
not cancel delivery to the hosted surface and directional swipes still fail the
tap recognizer and keep their focus/scrub path. It calls `pokeControls()`, the
same path every other interaction uses, so showing the bar and resetting
auto-hide cannot drift apart. Xcode's tvOS UI automation can press remote
buttons but cannot produce a light touch-surface tap, so the gesture-delivery
check itself exists only on a physical remote.

## Putting controls in the transport (tvOS)

The area around the scrubber is the obvious home for shortcut buttons —
subtitles, audio, speed, whatever comes next — and the reference player puts
its buttons exactly there. Playback speed was built there once and reverted;
the cost was mostly in rediscovering the constraints below.

**Nothing in the transport is focusable today, and that is deliberate.** The
overlay sets `allowsHitTesting(false)` on tvOS and the surface owns focus at
all times, because `onMoveCommand` lives *on the surface* and the moment focus
leaves it the arrows stop scrubbing (HEL-63); the skip prompt and the Up Next
card are visible-but-not-focusable for the same reason and are driven by Select
instead. The remote grammar is fully allocated except Up: left/right seek or
walk the scrub playhead, down opens the panel, Menu cancels/closes/exits,
Play/Pause toggles.

A focusable control there needs *all* of the following, and the first three are
not optional:

1. The overlay must become hit-testable (`allowsHitTesting(transportVisible)`).
2. Focusability must be gated on `transportVisible`, or focus walks into an
   invisible control while the transport is hidden.
3. The four-second auto-hide must not fire while it holds focus, or focus is
   stranded on a control that is then disabled.
4. It needs a way back: down should return `playerFocus = .surface`, because
   the surface must own focus for the arrows to scrub.

Platform limits, all verified on device rather than inferred:

- **SwiftUI `Menu` never presents inside the player's `fullScreenCover`** — the
  button takes focus and Select does nothing at all, the same class of tvOS-26
  fullScreenCover gap that `MenuPressGate` exists for, and the HIG documents
  the pop-up button this would be as *"Not supported in tvOS or watchOS."* A
  menu has to be built from ordinary buttons.
- **Focusable buttons nested inside another `Button`'s overlay stop taking
  focus entirely**, so anchor a popup from *outside* its button: publish the
  corner with `anchorPreference` and place the popup as a sibling.
- **A default tvOS button enforces its own minimum height**, around 66 pt;
  neither a smaller font nor `.frame(height:)` moves it, and
  `.controlSize(.small)` is the only lever short of drawing the focus lozenge
  by hand, which this codebase does not do.
- **Follow the current panel styles**: `.glass` for tvOS panel tabs and action
  buttons, native buttons inside the regular-material content card for track
  rows. Keep `.glassProminent` out of this white-accent app and never override
  foreground colours on focusable lozenges or their ancestors — the system must
  be free to choose a readable label when focus changes. See the shared
  [focus strategy](../../design-system.md#focus-strategy).

## Player view gotchas (learned the hard way on tvOS)

- The custom player UI (`CustomPlayerView`) talks **only to the `PlayerEngine`
  protocol**; engine internals must never leak into it.
- **No player view owns the engine** (HEL-152): a gesture closure captures the
  view by value and SwiftUI keeps that stale copy beside the refreshed one, so
  a strong `let engine` leaked one drained `SampleBufferPlayerEngine` per Up
  Next handoff. Every view declares `@PlayerEngineRef var engine`
  (`Lagoon/Features/Playback/Views/PlayerEngineRef.swift`, weak, with the memberwise
  initializer unchanged), `PlaybackController` is the only owner,
  `VideoPlayerView`'s surface builder captures `[weak]`, and a copy that
  outlives its engine reads `DetachedPlayerEngine.shared` instead of crashing.
- The video surface is focusable at **all** times: Menu quits the app from an
  unfocusable screen.
- **Scrub grammar** (HEL-39 slice 2, reworked in HEL-55): arrows walk a virtual
  playhead (`scrubTarget`) whenever the duration is known, playing or paused
  alike; the extra `engine.isPaused` gate it once had left trickplay, chapter
  ticks and chapter hops unreachable unless you guessed you had to pause first.
  Only a live stream (`duration == 0`) falls back to blind ±10 s seeks.
  - Playback keeps running behind the chip, so nothing has to be restored on
    cancel and no small skip round-trips the synchronizer; the *fill* therefore
    keeps showing the live position (`fillMotion` stays on `liveMotion` on
    tvOS, since easing it per position update stutters the glide) while the
    *knob* walks ahead. Touch is the reverse: the fill is what the thumb drags.
  - A lone press is still a 10 s skip, because the scrub self-commits after
    `ScrubMetrics.runExpiry` + `ScrubMetrics.selfCommit` (600 + 600 ms) of
    quiet — both hardware-tuning knobs, too short to read or too slow to feel
    responsive if moved far.
  - Select/Play commits *and plays on* (the native tvOS grammar) while the
    self-commit timeout and iOS drags keep the previous play state; Menu
    cancels to the live position, so it outranks close-the-panel in
    `MenuPressGate`'s policy.
  - Walking accelerates 10 → 30 → 60 s, and up/down hop chapters only
    mid-scrub, because down otherwise opens the panel and would strand the
    virtual playhead behind it; backwards hops land on the current chapter's
    start first, the way track skip-back does.
  - Chapter ticks stay unlabelled: a film reports ~25 of them and that many
    captions along a TV-width bar collide into noise, so the chip names the
    chapter under the playhead instead.
  - iOS seeks on release only; seeking per drag update would flush the
    renderers and re-demux on every frame of the gesture.
- **Skip intro/recap** (HEL-63): `GET MediaSegments/{itemId}` is **native to
  Jellyfin 10.10+**, so no plugin-specific code even though a plugin (Intro
  Skipper) populates it, and `includeSegmentTypes` wants *repeated* query
  params (it 400s on a comma-joined list), so filtering is client-side.
  - Only `Intro` and `Recap` are skippable: `Preview` and `Commercial` turn up
    mid-film in real libraries, and `Outro` is the hand-off to the next episode
    rather than something to jump.
  - Episodes carry **two `Intro` segments** more than occasionally and an
    `Intro` can start at tick 0; both are handled, so don't "simplify" to
    first-of-each.
  - `SkipMode` offers auto-after-delay (default, 5 s fill then commit, Menu
    cancels), instant and ask-every-time.
  - **The button is deliberately not focusable**, because focus would move
    `onMoveCommand` off the video surface and kill scrubbing while it is up; it
    extends the priority chains instead — Select commits a scrub, else skips,
    else toggles pause; Menu cancels a scrub, else waves off a pending
    auto-skip, else closes the panel, else exits. The iOS pill takes a direct
    tap, there being no remote Select to route.
  - `handledSegmentIDs` marks a segment before seeking; otherwise landing near
    its end puts the playhead back inside it and re-arms everything.
- **Autoplay the next episode** (HEL-66): the credits hand off inside the same
  player — `PlaybackController.playNextEpisode()` reports the finished episode
  stopped, resets its one-shot state, then starts the next. `AutoplayMode`
  offers automatic (default), ask-every-time and off; the countdown is 5 s to
  match `SkipMode`, since two countdowns at different speeds read as a bug.
  - HEL-86 keeps the player and its UIKit-backed `AVSampleBufferDisplayLayer`
    mounted across the handoff: inside the last 120 s the controller negotiates
    the successor's PlaybackInfo and warms up to its first 8 MiB (direct file)
    on the same one-chunk cooperative scheduler, superseding active-title
    proactive fill so credits never carry two competing downloads. Advancing
    reports the old session stopped and retires its demuxer and render
    synchronizer, and only once the lifecycle counters reach zero does
    `SampleBufferVideoSurface.updateUIView` attach the successor to the same
    layer — seamless here means a persistent surface and pre-negotiated
    playback, never overlapping decoders. Presentation has to survive the
    boundary too: the old final frame stays under a non-focusable "Starting
    next episode" overlay rather than flashing the presenting screen, PiP swaps
    its transport delegate while keeping the content source, and audio-session,
    Now Playing and tvOS display-match ownership stay put.
  - An `Episode Handoff` signpost measures the advance through to the
    successor's primed presentation clock; the hardware journey injects a
    seven-second renderer-retirement delay to model slow decoder teardown, so
    the single-pipeline invariant is tested rather than assumed.
  - **Never resolve the next episode from `Shows/NextUp`**: it returns the
    episode *in progress* when there is one (`enableResumable` defaults to
    `true`, per the server's own OpenAPI document), and when an episode
    finishes its stop report has not landed yet, so NextUp hands back the
    episode that just ended and autoplay loops on it forever.
    `episodeAfter(_:)` uses
    `Shows/{seriesId}/Episodes?startItemId=<current>&Limit=2` instead: index 1
    is the next episode, it doesn't depend on watch state, and naming no season
    carries a binge across a season boundary. It also guards that item 0 *is*
    the anchor, because a mismatch means the server started from the top of the
    series and rolling into episode 1 is far worse than doing nothing.
  - **Two anchors, not one**: the card appears at the `Outro` segment's start
    when the server marked one and the countdown runs from there, since cutting
    the credits short is the point; with no outro nothing says where the
    episode stops being the episode, so the card appears on a fixed 15 s
    run-out with the *fill* pinned to the last 5 s of the file. One anchor
    would either hide the card until it was useless or eat content nobody
    called credits.
  - **Track selection carries over matched by language and title, not
    ordinal**, because episodes of one show only usually share a stream layout
    and a commentary track on one of them would shift every choice below it.
    Subtitles-off is carried as a choice of its own, or the successor
    reinstates the server default; an external sidecar whose URL won't resolve
    has to leave the stream list as well as the engine's list, or every ordinal
    past it names the wrong track.
  - **A cancel has to outlive the card**: Back sets `nextUpDismissed`, but the
    credits still run and `didFinish` then arrives and autoplays over the "no"
    (verified happening), so `onCancelNextUp` is plumbed up to
    `VideoPlayerView`, which holds the flag until the next episode starts.
    `didFinish` still advances when nothing was cancelled — with no outro the
    countdown and the end of the file land within a frame of each other, and
    `playNextEpisode` is guarded (`isAdvancing`) against being taken up twice.
  - The card is **not focusable**, same trap and same fix as the skip pill, and
    shares the bottom-trailing shelf because intros and recaps live at the
    front of an episode and credits at the back.
  - Its background is `.regularMaterial`, not a black wash: credits are white
    text on black and at *any* opacity a flat scrim lets them through as
    readable letters, so only blurring stops it.
- **Trickplay** (slice 3, Jellyfin 10.9+): `BaseItemDto.Trickplay` is
  `[mediaSourceId: [width: TrickplayInfo]]`, its `Interval` is
  **milliseconds**, and `Videos/{id}/Trickplay/{width}/{n}.jpg` returns one
  sprite sheet per `TileWidth × TileHeight` grid (the default 10×10 at 10 s
  covers ~16 minutes each). Unlike `Items/…/Images/…` the route **401s without
  credentials**, so `TrickplayLoader` builds its request through
  `MediaRequestAuthorization`, with the token in the `Authorization` header
  rather than the URL. A sheet is ~23 MB decoded, which is why the loader keeps
  its own two instead of going through `ImageCache` (one scrub would evict
  every poster), caps source responses at 16 MiB and its compressed cache at
  32 MiB, and cancels obsolete transfers while retaining the previous frame.
  Tile crops derive from the *decoded* sheet's size, never the declared
  numbers: the decode caps sheets at 3200 px and a film's last sheet is only
  partly filled, so its height isn't `rows` tiles.
- Chapters and trickplay are fetched by the player itself (`playbackExtras`,
  concurrent with the PlaybackInfo negotiation), not taken from the `MediaItem`
  it was handed, because playback also starts from rails whose list requests
  don't carry those fields. Both degrade to nothing on servers that never
  generated them.
- A faded-out overlay **still hit-tests**: the transport gates
  `allowsHitTesting` on its own visibility, or the invisible iOS scrubber
  swallows drags meant for the video, and tvOS keeps the whole transport
  non-hit-testable because Select belongs to the focused surface.
- **SwiftUI's `onExitCommand` never fires inside a fullScreenCover on tvOS 26**
  — UIKit's presentation controller consumes Menu and dismisses the cover
  directly, and `interactiveDismissDisabled` doesn't gate it. `MenuPressGate`
  owns the policy (panel open → close panel, else → explicit dismiss) and
  **needs BOTH interception layers**: a real `.menu` press is eaten by UIKit's
  dismissal *gesture recognizer* before press delivery reaches any responder,
  so only our own `UITapGestureRecognizer` with `allowedPressTypes = [.menu]`
  preempts it (on hardware, responder-chain overrides alone let Menu kill the
  whole player), while the simulator's keyboard Escape arrives as a keyboard
  press (type = 2000 + HID usage, never `.menu`) that no recognizer matches, so
  the `pressesEnded` override must catch `key?.keyCode == .keyboardEscape`.
  Each environment exercises only one of the two paths.
- `defaultFocus` is only honored when a fresh scene appears, so any mid-screen
  reveal must assign its `@FocusState` programmatically (immediately, plus a
  settled retry) or focus strands.
- **Nothing that *appears* inside the player can animate — animate values
  instead.** The animation transaction doesn't survive the `MenuPressGate`
  hosting boundary (state lives outside the `UIHostingController` and updates
  cross via `rootView` reassignment), so `withAnimation` lands instantly while
  value-driven `.animation(_, value:)` inside the hosted tree works and covers
  opacity, offset and asymmetric timing. **Transitions are the trap**:
  `.transition()` on a conditionally-inserted view has no value to hang an
  animation on at the moment of insertion, so it never runs however it is
  wrapped — an animated `Group` around the `if` and forwarding
  `context.transaction` around the `rootView` assignment were both tried and
  both failed, with frame capture showing the panel still appearing whole
  between two frames 0.04 s apart. The panel therefore stays mounted
  permanently and slides via `.offset` + `.opacity`, with
  `.disabled(!panelOpen)` keeping its buttons out of the focus engine while
  closed. **Verify animations by recording, not screenshots**: `simctl io
  recordVideo`, then step frames out with `AVAssetImageGenerator`, because a
  screenshot lands after the animation has finished.
- Never nest `SharedState.withLock` (non-recursive lock — nesting was the
  engine's first real deadlock); `sample <pid>` on the host names the exact
  stuck line when a queue wedges.
- Native buttons only; never draw custom chrome tied to focus — the system
  lozenge is the design (see the Infuse reference on HEL-35).
- On failure the engine is set to **nil** and replaced with an error overlay
  carrying a Back button and `.onExitCommand`, because a dead surface would
  swallow the Menu press and trap the user.
- The loading state is `LoadingView` (focusable) for the same Menu-button
  reason as everywhere else.
- tvOS does not restore focus to the presenting screen after the player cover
  dismisses (custom focusable content inside), so every screen that presents
  the player wraps in `.restoresFocusAfterPlayer(isPresented:)`
  (`Lagoon/Shared/UI/FocusRestoration.swift`: focus scope + `resetFocus`
  timed past the dismissal transition).
