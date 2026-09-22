import LagoonEngine
import MediaAccessibility
import OSLog
import SwiftUI

/// Bench hook (`debug.benchBareSurface`): nothing but the video surface, so
/// a hardware run can say whether the chrome layered over an HDR frame is
/// what keeps it off the display's optimized composition path. Read once; a
/// shipping launch never sets it. File-private because the view is generic
/// and cannot hold a static stored property.
private let benchBareSurface = UserDefaults.standard.bool(forKey: "debug.benchBareSurface")

/// Bench hook (`debug.benchFlatCues`): HDR frame-loss bench on Apple TV
/// found the subtitle cue text costing dropped frames — its shadow/outline
/// (`SubtitleEdgeModifier`) and translucent background are filtered every
/// composited frame while the cue is on screen. `rasterizedCue()` bakes
/// those into one Metal-rendered texture via `.drawingGroup()` so steady
/// cues cost the compositor nothing extra; setting this flag skips that and
/// keeps the old per-frame path, for an on-device A/B from the same binary.
/// Read once; default off, i.e. the cache is on by default. File-private
/// for the same reason as `benchBareSurface`.
private let benchFlatCues = UserDefaults.standard.bool(forKey: "debug.benchFlatCues")

private extension View {
    /// Rasterizes the cue (shadow/outline + background already applied) into
    /// a single offscreen texture instead of re-filtering a live layer every
    /// frame. Must be applied after those modifiers and before any
    /// accessibility identifier/label, which stay outside the drawing group
    /// so `player.subtitle.text` is still queryable by UI tests.
    @ViewBuilder
    func rasterizedCue() -> some View {
        if benchFlatCues {
            self
        } else {
            self.drawingGroup()
        }
    }
}

/// Full-screen custom player: title block over a thin scrubber, and a
/// swipe-down panel of pill tabs (Info · Video · Audio · Subtitles, plus
/// Together in a group). Talks only to `PlayerEngine`.
///
/// **Never read `timePosition`, `currentSubtitle*` or anything else the engine
/// moves at tick rate from this body.** Observation tracks reads per body, and
/// one such read re-hosts `MenuPressGate`'s whole tree every tick. The child
/// overlays read them in their own bodies. Handler and task closures are not
/// body reads.
///
/// tvOS: the surface stays focusable always, or Menu quits the app. Touch tap
/// reveals, play/pause toggles anywhere, left/right seek ±10 s playing and
/// walk the playhead paused, down opens the panel, then left/right walk tabs
/// and down enters rows. `MenuPressGate` takes Menu at the UIKit press layer
/// (`onExitCommand` never fires inside a fullScreenCover on tvOS 26):
/// scrubbing cancels, else the panel closes, else exit.
///
/// iOS: tap toggles rather than reveals, double-tap either half seeks ±10 s
/// and stacks within the glyph's dismiss window, the centred cluster is
/// buttons under the thumb, the scrubber drags, pills are tapped.
struct CustomPlayerView<Surface: View>: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// Stable media identity, independent of the engine object's lifetime.
    /// Changing it resets episode-only chrome while preserving this view's
    /// structural position and its UIKit video surface.
    let playbackIdentity: String
    /// Debug measurement supplied by the host for asserting that UIKit did
    /// not replace the render surface at an episode boundary.
    var playerSurfaceIdentity = ""
    /// Most recent successor-ready latency, exposed only through the launch-
    /// gated hardware probe and the optional performance HUD.
    var handoffMilliseconds: Double? = nil
    /// Negotiated Jellyfin mode and transport ownership are carried into the
    /// launch-gated probe so regressions prove the intended path actually ran.
    var playbackMethod: PlayMethod = .directPlay
    /// The delivery-ladder rung backing `playbackMethod`: Jellyfin's
    /// own `PlayMethod` reports `Transcode` for both the cheap remux rung and
    /// the expensive re-encode rung, so the regression probe needs this to
    /// tell them apart.
    var deliveryRung: PlaybackDelivery = .negotiated
    var isPlaybackCacheActive = false
    /// The legacy byte-zero prefix remains in the regression probe. The
    /// visible scrubber renders every sparse direct-file cache island.
    var bufferedFraction: Double? = nil
    var bufferedRanges: [PlaybackBufferedRange] = []
    var playheadPrefetchCount = 0
    let info: PlayerItemInfo
    /// Skip and Up Next, decided off the engine's clock by the controller;
    /// the overlays draw it and Select/Menu act on it.
    let automation: PlaybackAutomation
    /// Where the viewer's play, pause and seek go. Supplied by the player
    /// host so a SyncPlay group can turn them into requests to the server
    /// instead of local moves. Nil means straight to the engine,
    /// which is what the developer-settings preview wants and what every
    /// call below falls back to.
    var transport: PlayerTransportActions? = nil
    let onDismiss: () -> Void
    /// Lets the host react to the panel opening (the debug HUD hides so
    /// it can't sit on top of the track card).
    var onPanelToggle: ((Bool) -> Void)? = nil
    /// Incremented by the host when a gesture it owns (the iOS swipe up)
    /// asks for the options panel; the view opens it as Info would.
    var openPanelRequest = 0
    /// The episode queued behind this one. Nil for movies, at the
    /// end of a series, and until the lookup lands.
    var nextUp: NextUpEpisode? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    /// The Watch Together group owning this session, or nil outside one.
    /// A value, supplied by the host: the player root must not
    /// read a store, and this is what decides whether a fifth tab exists.
    var together: PlayerTogetherState? = nil
    var onLeaveGroup: (() -> Void)? = nil
    var onSetIgnoreWait: ((Bool) -> Void)? = nil
    /// The group is holding for a member that is not ready, so the
    /// spinner earns a line saying why nothing is moving.
    var isWaitingForGroup = false
    var subtitleStyle: SubtitleRenderStyle = .fallback
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    @ViewBuilder let surface: () -> Surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private struct SeekFeedback: Equatable {
        let forward: Bool
        let token: Int
        /// Stacked total for the iOS double-tap grammar; always
        /// 10 for the tvOS remote's plain ±10 s seek.
        var seconds: Int = 10
    }

    @State private var controlsVisible = true
    /// Swaps the remaining time for the clock time the item will finish at.
    /// Toggled by a further touch-surface tap while the transport is already
    /// up, and reset with the item.
    @State private var showsEndTime = false
    @State private var interactionToken = 0
    @State private var panelOpen = false
    @State private var selectedTab: PlayerPanelTab = .info
    @State private var seekFeedback: SeekFeedback?
    @State private var showsBuffering = false
    /// The virtual playhead's position while scrubbing; nil when the
    /// transport is live.
    @State private var scrubTarget: Double?
    /// Debug-only regression evidence for the most recent explicit/self
    /// commit; harmless in normal builds and omitted from the visible UI.
    @State private var lastCommittedScrubTarget: Double = -1
    /// How many scrub steps this run of uninterrupted input has taken —
    /// what the step size accelerates on. Expires with `scrubStepToken`.
    @State private var scrubRunLength = 0
    @State private var scrubStepToken = 0
    /// Whether the last scrub input was a chapter hop rather than a step —
    /// they get different self-commit windows (see the task below).
    @State private var scrubHopped = false
    /// Only exists when the server generated trickplay tiles.
    @State private var trickplay: TrickplayLoader?
    @FocusState private var playerFocus: PlayerControlFocus?
    #if os(tvOS)
    @Namespace private var panelFocusScope
    @Environment(\.resetFocus) private var resetFocus
    #endif
    #if os(iOS)
    /// The video surface's width, read via `.onGeometryChange` so a
    /// double-tap's x position can be read as "back half" vs "forward half"
    /// of the screen.
    @State private var surfaceWidth: CGFloat = 0
    #endif
    @State private var panelRevealSignpostActive = false
    private let panelSignpostID = OSSignpostID(log: PlaybackPerformance.log)

    /// Slide the panel in on, and back out with, the swipe that summons it.
    private var panelMotion: Animation? {
        reduceMotion ? nil : .spring(duration: Motion.fast, bounce: 0.05)
    }
    private var transientScaleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }
    /// Far enough to carry the tabs and card clear of the top edge.
    private var panelSlideDistance: CGFloat { 720 }

    var body: some View {
        #if os(tvOS)
        // Menu never reaches SwiftUI inside a fullScreenCover on tvOS 26;
        // the gate intercepts the press itself (see MenuPressGate).
        MenuPressGate(onMenu: {
            handleMenu()
        }, onRemoteTouchTap: {
            handleRemoteTouchTap()
        }) {
            playerContent
        }
        .ignoresSafeArea()
        #else
        NavigationStack {
            playerContent
                // Toolbar visibility changes the navigation safe area. Keep
                // the video and its centered controls in stable screen bounds.
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close, action: onDismiss)
                            .accessibilityIdentifier("player.close")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // Play/Pause moved to the centred touch cluster,
                        // which owns the accessibility identifier
                        // now; Info stays here.
                        Button("Info", systemImage: "info.circle", action: openPanel)
                            .accessibilityIdentifier("player.info")
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar(transportVisible ? .visible : .hidden, for: .navigationBar)
        }
            .sheet(isPresented: $panelOpen, onDismiss: closePanel) {
                panel
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: openPanelRequest) { _, _ in
                guard !panelOpen else { return }
                openPanel()
            }
        #endif
    }

    /// Deliberately free of anything the engine updates at tick rate.
    ///
    /// Observation tracks property reads per body, and on tvOS this whole
    /// tree is rebuilt inside `MenuPressGate.updateUIViewController`, so one
    /// `engine.timePosition` read in here used to re-host the hosting
    /// controller's entire view tree ten times a second. The views
    /// that actually display the playhead, the cues and the skip/Up Next
    /// windows read those properties in their own bodies instead, and the
    /// per-tick invalidation stops at them. Reads inside event handlers and
    /// task closures are not body reads and are fine; the computed properties
    /// below that touch `engine.timePosition` exist only for those.

    private var playerContent: some View {
        ZStack {
            videoSurface

            if !benchBareSurface {
                PlayerSubtitleOverlay(
                    engine: engine,
                    style: subtitleStyle,
                    onDisplayedCaption: reportDisplayedCaption
                )

                if case .failed = engine.subtitleLoadState, !panelOpen {
                    VStack {
                        Label("Subtitles couldn't load. Open Subtitles to retry or choose another track.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .padding(Metrics.Space.l)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.Space.l))
                            .padding(.horizontal, Metrics.screenGutter)
                            .padding(.top, Metrics.Space.xl)
                            .accessibilityIdentifier("player.subtitleLoad.notice")
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }

                // Every animation in here is value-driven (.animation + value:).
                // withAnimation doesn't survive the MenuPressGate hosting
                // boundary, and neither do transitions — see the panel below and
                // the write-up in docs/playback.md.
                Group {
                    if showsBuffering || isWaitingForGroup {
                        // The same spinner, with the group's reason under
                        // it: a member primed and paused at the group's
                        // position is not buffering, and without the line
                        // a still picture and a live spinner look like a
                        // stall.
                        VStack(spacing: Metrics.Space.m) {
                            ProgressView()
                                .tint(.white)
                            if isWaitingForGroup {
                                Text("Waiting for the group")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("player.together.waiting")
                            }
                        }
                        // Waiting keeps the engine paused, which keeps the
                        // touch grammar's 88pt play button up for as long
                        // as the line is on screen — and it sits in this
                        // exact spot. Drop the pair into the empty band
                        // below it rather than behind it.
                        .offset(y: waitingDrop)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: Motion.fast), value: showsBuffering)
                .animation(.easeInOut(duration: Motion.fast), value: isWaitingForGroup)

                Group {
                    if let feedback = seekFeedback {
                        seekIndicator(feedback)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: seekFeedback)

                PlayerSkipOverlay(automation: automation, reduceMotion: reduceMotion, onSkip: skip)

                PlayerNextUpOverlay(
                    automation: automation,
                    episode: nextUp,
                    reduceMotion: reduceMotion,
                    hint: hint
                )

                PlayerTransportOverlay(
                    engine: engine,
                    info: info,
                    isVisible: transportVisible,
                    scrubTarget: scrubTarget,
                    showsEndTime: showsEndTime,
                    showsPanelHint: showsPanelHint,
                    bufferedFraction: bufferedFraction,
                    bufferedRanges: bufferedRanges,
                    trickplay: trickplay,
                    onScrubPreview: { seconds in
                        scrubTarget = seconds
                        pokeControls()
                    },
                    onCommitScrub: { seconds, resume in
                        commitScrub(to: seconds, resume: resume)
                    },
                    onCancelScrub: cancelScrub,
                    onPoke: pokeControls
                )
                    .opacity(transportVisible ? 1 : 0)
                    // A faded-out overlay still hit-tests: without this the
                    // invisible iOS scrubber would swallow drags meant for the
                    // video (and the button row taps). tvOS is never touched —
                    // Select goes to the focused surface — so nothing down
                    // there may take a press at all.
                    #if os(tvOS)
                    .allowsHitTesting(false)
                    #else
                    .allowsHitTesting(transportVisible)
                    .accessibilityHidden(!transportVisible)
                    #endif
                    // Asymmetric: target-state-conditional animation — fast
                    // in, gentle out.
                    .animation(
                        controlsVisible ? .easeOut(duration: Motion.fast) : .easeInOut(duration: Motion.slow),
                        value: controlsVisible
                    )
                    .animation(.easeInOut(duration: Motion.fast), value: engine.isPaused)
                    .animation(.easeInOut(duration: Motion.fast), value: panelOpen)

                #if os(iOS)
                // The touch grammar's equivalent of the remote's Select and
                // left/right: the same transport visibility and
                // scrub suppression the bottom bar uses, so both fade and
                // hide together instead of drifting out of sync.
                PlayerTouchTransportCluster(
                    engine: engine,
                    onSkip: { forward in
                        requestSeek(by: forward ? TouchSeekPolicy.step : -TouchSeekPolicy.step)
                        showSeekFeedback(forward: forward)
                        pokeControls()
                    },
                    onTogglePlayPause: {
                        requestTogglePause()
                        pokeControls()
                    }
                )
                .opacity(transportVisible && !isScrubbing ? 1 : 0)
                .allowsHitTesting(transportVisible && !isScrubbing)
                // Opacity preserves layout; explicitly hide unavailable
                // controls from assistive navigation as well as touch input.
                .accessibilityHidden(!transportVisible || isScrubbing)
                .animation(.easeInOut(duration: Motion.fast), value: controlsVisible)
                .animation(.easeInOut(duration: Motion.fast), value: isScrubbing)
                #endif

                // The panel stays mounted and slides out of frame rather than
                // being inserted. A *transition* needs an animation transaction
                // at the moment of insertion, and none survives MenuPressGate's
                // rootView reassignment — tried twice, including forwarding
                // context.transaction, and frame capture showed it still popping
                // between two frames 0.04 s apart. A plain value change does
                // survive, so the slide is an offset. Disabled while closed so
                // its buttons stay out of the focus engine's reach.
                #if os(tvOS)
                panel
                    .focusScope(panelFocusScope)
                    .offset(y: panelOpen ? 0 : -panelSlideDistance)
                    .opacity(panelOpen ? 1 : 0)
                    .disabled(!panelOpen)
                    .animation(panelMotion, value: panelOpen)
                #endif

            }
        }
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        .onPlayPauseCommand {
            if let target = scrubTarget {
                commitScrub(to: target, resume: true)
            } else {
                requestTogglePause()
                pokeControls()
            }
        }
        #endif
        // Leaving the group takes its tab with it, and a selection left
        // pointing at a tab that is no longer drawn leaves the panel
        // showing nothing.
        .onChange(of: together == nil) { _, hasNoGroup in
            if hasNoGroup, selectedTab == .together { selectedTab = .info }
        }
        .onChange(of: playerFocus) { _, focus in
            if case .tab(let tab) = focus {
                // The native focus lozenge already animates. Animating the
                // selected state as well made SwiftUI interpolate the entire
                // material card and long track hierarchy on every arrow press.
                selectedTab = tab
            }
        }
        .task(id: interactionToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !panelOpen, !engine.isPaused, !isScrubbing else { return }
            controlsVisible = false
        }
        // The spinner only earns screen time when buffering persists —
        // instant local seeks used to flash it on every press.
        .task(id: engine.isBuffering) {
            if engine.isBuffering {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                showsBuffering = true
            } else {
                showsBuffering = false
            }
        }
        .task(id: seekFeedback?.token) {
            guard seekFeedback != nil else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            seekFeedback = nil
        }
        .task(id: playbackIdentity) {
            resetForPlaybackIdentity()
        }
        // Frames follow the virtual playhead, not playback: the loader
        // no-ops until the target crosses into the next thumbnail.
        .onChange(of: scrubTarget) { _, target in
            if let target { trickplay?.update(to: target) }
        }
        .onDisappear {
            reportDisplayedCaption(nil)
        }
        // Two beats of quiet, both timed from the last press. The first
        // ends the acceleration run, so the next press steps 10 s again.
        // The second lands the scrub on its own: without it, opening scrub
        // during playback would cost a Select to confirm every small skip,
        // and the ±10 s nudge would have nowhere to live.
        .task(id: scrubStepToken) {
            guard isScrubbing else { return }
            try? await Task.sleep(for: ScrubMetrics.runExpiry)
            guard !Task.isCancelled else { return }
            scrubRunLength = 0
            try? await Task.sleep(for: scrubHopped ? ScrubMetrics.chapterSelfCommit : ScrubMetrics.selfCommit)
            guard !Task.isCancelled, let target = scrubTarget else { return }
            // Landing on the timeout keeps whatever the play state was;
            // only an explicit Select/Play means "go here *and* play on".
            commitScrub(to: target, resume: false)
        }
    }

    private func seekIndicator(_ feedback: SeekFeedback) -> some View {
        PlayerSeekIndicator(forward: feedback.forward, seconds: feedback.seconds)
            .transition(transientScaleTransition)
    }

    // MARK: - Surface & remote commands

    private func handleMenu() {
        if isScrubbing {
            cancelScrub()
        } else if automation.dismissSkip() {
            // Back during the countdown means "no" — the one mode with a
            // pending action to call off. In `button` mode there is nothing
            // to cancel, so Menu keeps meaning "leave".
        } else if automation.dismissNextUp() {
            // Same rule as the skip pill: Back only cancels where something
            // is pending. In `card` mode the offer sits there unanswered and
            // Menu still means "leave".
        } else if panelOpen,
                  selectedTab == .subtitles,
                  let subtitleSearch,
                  subtitleSearch.isBrowsingResults {
            // One more level of the same nesting the panel itself follows:
            // Back leaves the results browser before it would close the panel,
            // just as it closes the panel before it would leave playback.
            subtitleSearch.closeResults()
            playerFocus = .track("subtitle-search")
        } else if panelOpen {
            closePanel()
        } else {
            onDismiss()
        }
    }

    /// A light tap is intentionally non-destructive: reveal the existing
    /// transport and restart its four-second dwell without changing play,
    /// scrub, skip, or Up Next state. The panel already owns the whole remote
    /// while it is open, so a touch there is ignored.
    private func handleRemoteTouchTap() {
        guard !panelOpen else { return }
        // The first tap only reveals the transport. A further tap while it is
        // already up swaps the remaining time for the clock time the item
        // finishes at, and a third swaps it back. Neither touches
        // play, scrub, skip or Up Next state.
        if transportVisible {
            showsEndTime.toggle()
        }
        pokeControls()
    }

    #if os(iOS)
    /// A double-tap on either half of the surface seeks ±10 s and, unlike
    /// every other touch gesture here, does not summon the transport — every
    /// phone player leaves double-tap seek silent on chrome, and popping the
    /// bars under the thumb mid-tap would fight repeated double-taps.
    /// Ignored mid-scrub and while the panel owns the
    /// screen, same as the single tap beside it.
    private func handleTouchSeek(at point: CGPoint) {
        guard !panelOpen, !isScrubbing else { return }
        let forward = point.x >= surfaceWidth / 2
        requestSeek(by: forward ? TouchSeekPolicy.step : -TouchSeekPolicy.step)
        // A further double-tap on the same side inside the glyph's dismiss
        // window (the `.task(id: seekFeedback?.token)` below) adds another
        // step rather than resetting it, so three quick double-taps forward read
        // "30 s" instead of restarting at 10 each time.
        let total = TouchSeekPolicy.accumulated(
            previous: seekFeedback?.seconds,
            sameDirection: seekFeedback?.forward == forward
        )
        showSeekFeedback(forward: forward, seconds: total)
    }
    #endif

    private var videoSurface: some View {
        surface()
            .ignoresSafeArea()
        #if os(tvOS)
            // The surface owns focus during playback. It stays eligible
            // during the panel animation so there is never a focusless
            // full-screen cover; `onMoveCommand` bridges any first command
            // that arrives before a tab has accepted focus.
            .focusable()
            .focused($playerFocus, equals: .surface)
        #endif
            // The regression suite reads state from the surface that owns
            // focus. The probe is a modifier so the tick-rate values it
            // reports are read in its body rather than this one.
            .modifier(
                PlayerRegressionValue(
                    engine: engine,
                    info: info,
                    playbackIdentity: playbackIdentity,
                    playerSurfaceIdentity: playerSurfaceIdentity,
                    playbackMethod: playbackMethod,
                    deliveryRung: deliveryRung,
                    isPlaybackCacheActive: isPlaybackCacheActive,
                    bufferedFraction: bufferedFraction,
                    bufferedRanges: bufferedRanges,
                    playheadPrefetchCount: playheadPrefetchCount,
                    handoffMilliseconds: handoffMilliseconds,
                    nextUpCardStart: automation.nextUpCardStart,
                    isNextUpSuppressed: panelOpen || isScrubbing || automation.nextUpDismissed,
                    isScrubbing: isScrubbing,
                    isTransportVisible: transportVisible,
                    lastCommittedScrubTarget: lastCommittedScrubTarget,
                    panelOpen: panelOpen,
                    selectedTab: selectedTab,
                    focus: playerFocus,
                    trickplay: trickplay
                )
            )
            // The panel and an open scrub own the screen and the remote, so
            // neither prompt may act underneath them.
            .onChange(of: panelOpen || isScrubbing, initial: true) { _, suppressed in
                automation.isSuppressed = suppressed
            }
        #if os(tvOS)
            .onMoveCommand { direction in
                if panelOpen {
                    // tvOS can retain the full-screen surface until the
                    // sliding tabs fully enter its focus region. Do not eat
                    // that first command: move the selection and focus to
                    // the tab the command was trying to reach.
                    let tabs = PlayerPanelTab.offered(inGroup: together != nil)
                    if direction == .left || direction == .right,
                       let index = tabs.firstIndex(of: selectedTab) {
                        let delta = direction == .right ? 1 : -1
                        let targetIndex = min(max(index + delta, 0), tabs.count - 1)
                        let target = tabs[targetIndex]
                        selectedTab = target
                        playerFocus = .tab(target)
                    } else {
                        playerFocus = .tab(selectedTab)
                    }
                    return
                }
                switch direction {
                // Left/right open scrub rather than seeking blind, playing
                // or paused. A lone press still reads as a 10 s
                // skip — it just previews the frame first and lands itself
                // a beat later; holding accelerates into a real scrub.
                case .left where canScrub:
                    stepScrub(direction: -1)
                case .right where canScrub:
                    stepScrub(direction: 1)
                // No duration to walk along (live streams): blind ±10 s,
                // with the glyph as the only feedback available.
                case .left:
                    requestSeek(by: -10)
                    showSeekFeedback(forward: false)
                case .right:
                    requestSeek(by: 10)
                    showSeekFeedback(forward: true)
                // Mid-scrub, up/down hop chapters. Down
                // keeps the panel everywhere else — opening it mid-scrub
                // would strand a virtual playhead behind it.
                case .up where isScrubbing:
                    jumpChapter(direction: 1)
                case .down where isScrubbing:
                    jumpChapter(direction: -1)
                case .down:
                    openPanel()
                default:
                    break
                }
                pokeControls()
            }
        #endif
        #if os(iOS)
            // Attached before the single-tap gesture below so SwiftUI
            // recognizes the double-tap and delays the single tap while it
            // waits to see whether a second one follows — the standard
            // trade-off every phone player makes for a working double-tap.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { surfaceWidth = $0 }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                handleTouchSeek(at: point)
            }
        #endif
            .onTapGesture {
                guard !panelOpen else { return }
                #if os(tvOS)
                // Select commits a scrub and plays on from there — the
                // native tvOS grammar; otherwise it's play/pause.
                if let target = scrubTarget {
                    commitScrub(to: target, resume: true)
                } else if let segment = automation.activeSegment, automation.skipMode != .instant {
                    // The button is deliberately not focusable: taking focus
                    // would move `onMoveCommand` off the surface and kill
                    // scrubbing while it is up. Select acts on it
                    // instead, which is also the grammar Jaagop described.
                    skip(segment)
                } else if automation.showsNextUp {
                    // Not focusable either, and for the same reason.
                    automation.playNext()
                } else {
                    requestTogglePause()
                    pokeControls()
                }
                #else
                if controlsVisible {
                    controlsVisible = false
                } else {
                    pokeControls()
                }
                #endif
            }
    }

    private func pokeControls() {
        controlsVisible = true
        interactionToken += 1
    }

    /// The SwiftUI player hierarchy deliberately survives autoplay. Clear
    /// only state that belongs to the finished item; focus and the hosted
    /// display layer remain in place for a seamless engine swap.
    private func resetForPlaybackIdentity() {
        controlsVisible = true
        showsEndTime = false
        interactionToken += 1
        panelOpen = false
        onPanelToggle?(false)
        selectedTab = .info
        seekFeedback = nil
        showsBuffering = false
        scrubTarget = nil
        lastCommittedScrubTarget = -1
        scrubRunLength = 0
        scrubStepToken += 1
        scrubHopped = false
        // Skip and Up Next state belongs to the controller's automation,
        // which starts each item clean.
        trickplay = info.trickplay.map(TrickplayLoader.init(source:))
        reportDisplayedCaption(nil)
        #if os(tvOS)
        playerFocus = .surface
        #endif
    }

    private func showSeekFeedback(forward: Bool, seconds: Int = 10) {
        seekFeedback = SeekFeedback(forward: forward, token: (seekFeedback?.token ?? 0) + 1, seconds: seconds)
    }

    /// Custom renderers must tell Media Accessibility which caption text is
    /// currently onscreen; an empty array explicitly clears the report.
    private func reportDisplayedCaption(_ text: String?) {
        let strings: NSArray = text.map { [$0] } ?? []
        MACaptionAppearanceDidDisplayCaptions(strings)
    }

    // MARK: - Scrub mode

    private var isScrubbing: Bool { scrubTarget != nil }

    /// How far the buffering spinner steps down to clear the centre
    /// transport cluster while it carries the group's waiting line. Only
    /// touch has a cluster in the middle of the screen; the TV's transport
    /// is a bottom bar, so nothing moves there.
    private var waitingDrop: CGFloat {
        #if os(iOS)
        isWaitingForGroup ? Metrics.Space.section * 2 : 0
        #else
        0
        #endif
    }

    private var transportVisible: Bool {
        (controlsVisible || voiceOverEnabled || engine.isPaused || isScrubbing) && !panelOpen
    }

    /// Walking a virtual playhead needs a known duration to walk along;
    /// without one (live streams) the arrows stay plain ±10 s seeks.
    ///
    /// Playback is deliberately no bar to it. This used to also require
    /// `engine.isPaused`, which left trickplay, chapter ticks and chapter
    /// hopping unreachable for anyone who never guessed they had to pause
    /// first.
    private var canScrub: Bool {
        engine.duration > 0
    }

    /// Walks the virtual playhead one step. Sustained input accelerates
    /// (10 s → 30 s → 60 s) so crossing a feature-length film isn't fifty
    /// presses; the run expires after a beat of no input, so a deliberate
    /// single press is always a 10 s step.
    private func stepScrub(direction: Double) {
        let origin = scrubTarget ?? engine.timePosition
        let step: Double = switch scrubRunLength {
        case ..<4: 10
        case 4..<10: 30
        default: 60
        }
        let limit = engine.duration > 0 ? engine.duration : origin + step
        scrubTarget = min(max(origin + direction * step, 0), limit)
        scrubRunLength += 1
        scrubHopped = false
        scrubStepToken += 1
    }

    /// Lands the virtual playhead. `resume` is the tvOS grammar for an
    /// explicit commit — Select/Play scrubs *and* plays on. Touch drags and
    /// the self-commit timeout keep whatever the play state already was.
    private func commitScrub(to target: Double, resume: Bool) {
        lastCommittedScrubTarget = target
        endScrub()
        requestSeek(to: target, resume: resume)
        pokeControls()
    }

    // MARK: - Transport intentions
    //
    // The viewer asked for something; who acts on it is not this view's
    // business. With a `transport` the player host answers — a SyncPlay
    // group turns each of these into a request to the server and moves
    // nothing locally. Without one they are the engine calls that used to
    // be written here. The engine is read through `@PlayerEngineRef` at
    // the moment of the press and never captured.

    private func requestTogglePause() {
        guard let transport else {
            engine.togglePause()
            return
        }
        transport.togglePause()
    }

    private func requestSeek(by seconds: Double) {
        guard let transport else {
            engine.seek(by: seconds)
            return
        }
        transport.seekBy(seconds)
    }

    private func requestSeek(to seconds: Double, resume: Bool = false) {
        guard let transport else {
            // Resume before seeking: the engine re-anchors the synchronizer
            // when the seek primes, so unpausing afterwards fights that
            // hand-off.
            if resume, engine.isPaused { engine.togglePause() }
            engine.seek(to: seconds)
            return
        }
        transport.seek(seconds, resume)
    }

    private func cancelScrub() {
        endScrub()
        pokeControls()
    }

    private func endScrub() {
        scrubTarget = nil
        scrubRunLength = 0
        scrubHopped = false
        // The loader deliberately keeps its last frame: the chip fades out
        // showing the picture you committed to, and a later scrub in the
        // same neighbourhood opens on it instead of a placeholder.
    }

    /// Chapter hop while scrubbing. Backwards lands on the
    /// current chapter's start first, the way track skip-back does, so a
    /// second press is what reaches the previous one.
    private func jumpChapter(direction: Int) {
        let origin = scrubTarget ?? engine.timePosition
        let target = direction > 0
            ? info.chapters.first { $0.start > origin + 0.5 }
            : info.chapters.last { $0.start < origin - 3 }
        guard let target else { return }
        scrubTarget = min(max(target.start, 0), engine.duration)
        // A hop isn't part of a walking run — the next arrow press should
        // step 10 s, not 60.
        scrubRunLength = 0
        scrubHopped = true
        scrubStepToken += 1
    }

    // MARK: - Skip intro / recap and Up Next

    /// Select or a tap on the pill. The automation decides *whether* a
    /// segment is active, from the same clock the pill draws, so Select and
    /// the pill cannot disagree; this only adds the reveal.
    private func skip(_ segment: MediaSegment) {
        automation.skip(segment)
        pokeControls()
    }

    private var hint: LocalizedStringKey {
        #if os(tvOS)
        automation.autoplayMode == .autoDelay ? "Select to play now · Back to stay" : "Select to play now"
        #else
        "Tap to play now"
        #endif
    }

    private func openPanel() {
        if !panelRevealSignpostActive {
            panelRevealSignpostActive = true
            os_signpost(
                .begin,
                log: PlaybackPerformance.log,
                name: "Player Panel Reveal",
                signpostID: panelSignpostID
            )
        }
        panelOpen = true
        onPanelToggle?(true)
        // defaultFocus is only honored when a fresh scene appears — for a
        // mid-screen reveal tvOS leaves focus where it was, stranding the
        // panel. The panel is mounted but disabled while closed, so a focus
        // assignment in the same update that enables it can be rejected by
        // the focus engine even though the FocusState retains the requested
        // value. Claim after the reveal begins, once SwiftUI has applied
        // `panelOpen` and removed the panel's disabled focus environment.
        playerFocus = .surface
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(225))
            guard panelOpen else {
                finishPanelRevealSignpost()
                return
            }

            // The panel stays mounted off-screen, so defaultFocus alone does
            // not run when it slides in. Re-entering its dedicated scope asks
            // tvOS to resolve a visible default, while the explicit binding
            // keeps the selected tab and focus state in lockstep.
            #if os(tvOS)
            playerFocus = nil
            await Task.yield()
            guard panelOpen else {
                finishPanelRevealSignpost()
                return
            }
            resetFocus(in: panelFocusScope)
            #endif
            playerFocus = .tab(selectedTab)
            finishPanelRevealSignpost()
        }
    }

    private func closePanel() {
        finishPanelRevealSignpost()
        panelOpen = false
        onPanelToggle?(false)
        pokeControls()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !panelOpen else { return }
            playerFocus = .surface
        }
    }

    private func finishPanelRevealSignpost() {
        guard panelRevealSignpostActive else { return }
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Player Panel Reveal",
            signpostID: panelSignpostID
        )
        panelRevealSignpostActive = false
    }

    // MARK: - Transport

    /// The transport itself is `PlayerTransportOverlay`; only the hint's
    /// condition is decided here, because it turns on the subtitle load
    /// state and the scrub, not on the playhead.
    private var showsPanelHint: Bool {
        if case .failed = engine.subtitleLoadState { return false }
        return !isScrubbing
    }

    // MARK: - Panel

    private var panel: some View {
        PlayerControlPanelHost(
            engine: engine,
            selectedTab: $selectedTab,
            focus: $playerFocus,
            info: info,
            subtitleSearch: subtitleSearch,
            isPictureInPicturePossible: isPictureInPicturePossible,
            isPictureInPictureActive: isPictureInPictureActive,
            onTogglePictureInPicture: onTogglePictureInPicture,
            together: together,
            onLeaveGroup: onLeaveGroup,
            onSetIgnoreWait: onSetIgnoreWait,
            onDismiss: closePanel
        )
        .equatable()
    }
}

struct PlayerSubtitleText: View {
    let text: String
    let style: SubtitleRenderStyle
    var accessibilityIdentifier = "player.subtitle.text"

    var body: some View {
        Text(text)
            .font(style.font)
            .multilineTextAlignment(.center)
            .foregroundStyle(style.foregroundColor)
            .subtitleEdge(style.edgeStyle, color: style.edgeColor)
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
            .background(
                style.backgroundColor.opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .rasterizedCue()
            .padding(.bottom, style.bottomPadding)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Renders the small inline-style subset retained from ASS override blocks.
/// Placement is owned by `PositionedSubtitleLayout`; this view deliberately
/// has no dialogue-shelf padding of its own.
struct PlayerStyledSubtitleText: View {
    let cue: SubtitleTextCue
    let style: SubtitleRenderStyle
    /// Simultaneous authored cues are separate elements, so only the first
    /// keeps the canonical identifier — several elements answering to one
    /// name is an ambiguous match for anything querying it.
    var accessibilityIdentifier = "player.subtitle.text"

    var body: some View {
        styledText
            .font(style.font)
            .multilineTextAlignment(cue.alignment?.textAlignment ?? .center)
            .foregroundStyle(style.foregroundColor)
            .subtitleEdge(style.edgeStyle, color: style.edgeColor)
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
            .background(
                style.backgroundColor.opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .rasterizedCue()
            .accessibilityLabel(cue.text)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var styledText: Text {
        cue.runs.reduce(Text("")) { partial, run in
            var fragment = Text(run.text)
            if run.isBold { fragment = fragment.bold() }
            if run.isItalic { fragment = fragment.italic() }
            if let color = run.primaryColor {
                fragment = fragment.foregroundColor(color.swiftUIColor)
            }
            // Interpolation, not `+`: tvOS 26 deprecates `Text.+` and its
            // fix-it points here. Reads like a style choice, is not one.
            return Text("\(partial)\(fragment)")
        }
    }
}

private extension SubtitleTextAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .bottomLeft, .middleLeft, .topLeft: .leading
        case .bottomCenter, .middleCenter, .topCenter: .center
        case .bottomRight, .middleRight, .topRight: .trailing
        }
    }
}

private extension SubtitleTextColor {
    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

struct PlayerSeekIndicator: View {
    let forward: Bool
    /// The iOS double-tap grammar's stacked total; tvOS's remote
    /// seek never exceeds the base step, so this stays at its default there
    /// and the glyph alone renders exactly as before.
    var seconds: Int = 10
    var accessibilityIdentifier = "player.seekFeedback"

    var body: some View {
        VStack(spacing: Metrics.Space.xs) {
            HStack {
                if forward { Spacer() }
                Image(systemName: forward ? "goforward.10" : "gobackward.10")
                    .font(Typography.glyph.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6)
                if !forward { Spacer() }
            }
            if seconds > 10 {
                HStack {
                    if forward { Spacer() }
                    Text("\(seconds) s")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                    if !forward { Spacer() }
                }
            }
        }
        .padding(.horizontal, Metrics.screenGutter * 2)
        .allowsHitTesting(false)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// When an item will finish in real time, kept apart from the view so the
/// projection can be tested without one.
///
/// The viewer's chosen speed is what the remaining media time is divided by,
/// and `PlayerEngine.rate` deliberately survives a pause, so a paused item
/// still projects against the speed it will resume at. Because the remaining
/// time then stops falling while the clock keeps running, the answer slides
/// later for as long as playback is held.
nonisolated enum PlaybackFinish {
    /// Anything beyond a day is a live stream or a duration the demuxer has
    /// not worked out yet, not something worth projecting a finish for.
    static let longestProjection: TimeInterval = 24 * 60 * 60

    static func date(from now: Date, remaining: TimeInterval, rate: Double) -> Date? {
        guard remaining.isFinite, remaining >= 0 else { return nil }
        let speed = rate.isFinite && rate > 0 ? rate : 1
        let seconds = remaining / speed
        guard seconds.isFinite, seconds <= longestProjection else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// The clock time as the viewer's region writes it, so a 24-hour locale
    /// gets 21:45 and a 12-hour one gets 9:45 PM.
    static func label(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        )
    }
}
