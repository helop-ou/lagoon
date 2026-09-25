import LagoonEngine
import MediaAccessibility
import OSLog
import SwiftUI

/// Bench hook (`debug.benchBareSurface`): draw only the video surface, to
/// test whether chrome over an HDR frame costs composition. File-private
/// because a generic view cannot hold a static stored property.
private let benchBareSurface = UserDefaults.standard.bool(forKey: "debug.benchBareSurface")

/// Bench hook (`debug.benchFlatCues`): skip `rasterizedCue()` for an
/// on-device A/B. Cue shadow and background filtered every frame cost dropped
/// frames on Apple TV HDR; rasterizing them fixes that.
private let benchFlatCues = UserDefaults.standard.bool(forKey: "debug.benchFlatCues")

private extension View {
    /// Bakes the cue into one texture. Apply after edge and background, and
    /// before the accessibility identifier, so UI tests can still query
    /// `player.subtitle.text`.
    @ViewBuilder
    func rasterizedCue() -> some View {
        if benchFlatCues {
            self
        } else {
            self.drawingGroup()
        }
    }
}

/// Full-screen player: transport, overlays and the options panel. Talks only
/// to `PlayerEngine`.
///
/// **Never read `timePosition`, `currentSubtitle*` or other tick-rate engine
/// state in this body.** One such read re-hosts `MenuPressGate`'s whole tree
/// every tick. Child overlays read them in their own bodies. Handler and task
/// closures are not body reads.
///
/// tvOS: the surface must stay focusable, or Menu quits the app.
/// `MenuPressGate` takes Menu at the UIKit layer (`onExitCommand` never fires
/// in a fullScreenCover on tvOS 26): cancel scrub, else dismiss a skip or Up
/// Next prompt, else close panel, else exit.
struct CustomPlayerView<Surface: View>: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// Changing it resets episode chrome but keeps this view and its UIKit
    /// video surface in place.
    let playbackIdentity: String
    /// Lets tests assert UIKit kept the render surface across an episode.
    var playerSurfaceIdentity = ""
    var handoffMilliseconds: Double? = nil
    var playbackMethod: PlayMethod = .directPlay
    /// Jellyfin reports `Transcode` for both remux and re-encode; the probe
    /// needs this to tell them apart.
    var deliveryRung: PlaybackDelivery = .negotiated
    var isPlaybackCacheActive = false
    /// Probe only; the scrubber draws `bufferedRanges`.
    var bufferedFraction: Double? = nil
    var bufferedRanges: [PlaybackBufferedRange] = []
    var playheadPrefetchCount = 0
    let info: PlayerItemInfo
    /// Skip and Up Next, decided off the engine's clock by the controller.
    let automation: PlaybackAutomation
    /// Where play, pause and seek go; a SyncPlay group sends them to the
    /// server. Nil means straight to the engine.
    var transport: PlayerTransportActions? = nil
    let onDismiss: () -> Void
    var onPanelToggle: ((Bool) -> Void)? = nil
    /// Bumped by the host (iOS swipe up) to open the options panel.
    var openPanelRequest = 0
    var nextUp: NextUpEpisode? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    /// A value, not a store: the player root must not read a store.
    var together: PlayerTogetherState? = nil
    var onLeaveGroup: (() -> Void)? = nil
    var onSetIgnoreWait: ((Bool) -> Void)? = nil
    var isWaitingForGroup = false
    var subtitleStyle: SubtitleRenderStyle = .fallback
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    @ViewBuilder let surface: () -> Surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private struct SeekFeedback: Equatable {
        let forward: Bool
        let token: Int
        /// Stacked iOS double-tap total; always 10 on tvOS.
        var seconds: Int = 10
    }

    @State private var controlsVisible = true
    /// Shows the finish clock time instead of the remaining time.
    @State private var showsEndTime = false
    @State private var interactionToken = 0
    @State private var panelOpen = false
    @State private var selectedTab: PlayerPanelTab = .info
    @State private var seekFeedback: SeekFeedback?
    @State private var showsBuffering = false
    /// The virtual playhead while scrubbing; nil otherwise.
    @State private var scrubTarget: Double?
    /// Regression-probe evidence only.
    @State private var lastCommittedScrubTarget: Double = -1
    /// Steps in the current input run; the step size accelerates on it.
    @State private var scrubRunLength = 0
    @State private var scrubStepToken = 0
    /// Chapter hops get a different self-commit window than steps.
    @State private var scrubHopped = false
    @State private var trickplay: TrickplayLoader?
    @FocusState private var playerFocus: PlayerControlFocus?
    #if os(tvOS)
    @Namespace private var panelFocusScope
    @Environment(\.resetFocus) private var resetFocus
    #endif
    #if os(iOS)
    /// Splits double-taps into back and forward halves.
    @State private var surfaceWidth: CGFloat = 0
    #endif
    @State private var panelRevealSignpostActive = false
    private let panelSignpostID = OSSignpostID(log: PlaybackPerformance.log)

    private var panelMotion: Animation? {
        reduceMotion ? nil : .spring(duration: Motion.fast, bounce: 0.05)
    }
    private var transientScaleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }
    private var panelSlideDistance: CGFloat { 720 }

    var body: some View {
        #if os(tvOS)
        MenuPressGate(onMenu: {
            handleMenu()
        }, canTakeSelect: {
            !panelOpen
        }, onSelect: {
            handleSelect()
        }, onRemoteTouchTap: {
            handleRemoteTouchTap()
        }) {
            playerContent
        }
        .ignoresSafeArea()
        #else
        NavigationStack {
            playerContent
                // Toolbar visibility changes the safe area; keep the video
                // and centre controls from moving.
                .ignoresSafeArea(.container, edges: .top)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close, action: onDismiss)
                            .accessibilityIdentifier("player.close")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
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

    /// Must stay free of tick-rate reads (see the type comment). Computed
    /// properties below that read `engine.timePosition` are for handlers only.

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

                // Animations here are value-driven only: withAnimation and
                // transitions don't survive the MenuPressGate hosting boundary.
                Group {
                    if showsBuffering || isWaitingForGroup {
                        // Without the reason, a paused group member
                        // looks stalled.
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
                        // Waiting keeps the paused touch play button in
                        // this spot, so drop below it.
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
                    // A faded overlay still hit-tests and would swallow
                    // drags. On tvOS Select belongs to the focused surface, so
                    // nothing here may take a press.
                    #if os(tvOS)
                    .allowsHitTesting(false)
                    #else
                    .allowsHitTesting(transportVisible)
                    .accessibilityHidden(!transportVisible)
                    #endif
                    // Fast in, gentle out.
                    .animation(
                        controlsVisible ? .easeOut(duration: Motion.fast) : .easeInOut(duration: Motion.slow),
                        value: controlsVisible
                    )
                    .animation(.easeInOut(duration: Motion.fast), value: engine.isPaused)
                    .animation(.easeInOut(duration: Motion.fast), value: panelOpen)

                #if os(iOS)
                // Shares the bottom bar's visibility so both fade together.
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
                .accessibilityHidden(!transportVisible || isScrubbing)
                .animation(.easeInOut(duration: Motion.fast), value: controlsVisible)
                .animation(.easeInOut(duration: Motion.fast), value: isScrubbing)
                #endif

                // Stays mounted and slides by offset: no insertion transition
                // survives MenuPressGate's rootView reassignment. Disabled
                // while closed to keep its buttons out of focus.
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
            traceInput("playPause via=onPlayPauseCommand")
            if let target = scrubTarget {
                commitScrub(to: target, resume: true)
            } else {
                requestTogglePause()
                pokeControls()
            }
        }
        #endif
        // A selection on a vanished tab leaves the panel blank.
        .onChange(of: together == nil) { _, hasNoGroup in
            if hasNoGroup, selectedTab == .together { selectedTab = .info }
        }
        .onChange(of: playerFocus) { _, focus in
            if case .tab(let tab) = focus {
                // Don't animate: it interpolates the whole card on every
                // arrow press.
                selectedTab = tab
            }
        }
        .task(id: interactionToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !panelOpen, !engine.isPaused, !isScrubbing else { return }
            controlsVisible = false
        }
        // Only show the spinner when buffering persists.
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
        .onChange(of: scrubTarget) { _, target in
            if let target { trickplay?.update(to: target) }
        }
        .onDisappear {
            reportDisplayedCaption(nil)
        }
        // Two quiet beats after the last press: the first ends the
        // acceleration run, the second commits the scrub on its own so a lone
        // press still works as a ±10 s skip.
        .task(id: scrubStepToken) {
            guard isScrubbing else { return }
            try? await Task.sleep(for: ScrubMetrics.runExpiry)
            guard !Task.isCancelled else { return }
            scrubRunLength = 0
            try? await Task.sleep(for: scrubHopped ? ScrubMetrics.chapterSelfCommit : ScrubMetrics.selfCommit)
            guard !Task.isCancelled, let target = scrubTarget else { return }
            // Only an explicit Select/Play resumes.
            commitScrub(to: target, resume: false)
        }
    }

    private func seekIndicator(_ feedback: SeekFeedback) -> some View {
        PlayerSeekIndicator(forward: feedback.forward, seconds: feedback.seconds)
            .transition(transientScaleTransition)
    }

    // MARK: - Surface & remote commands

    private func handleMenu() {
        traceInput("menu")
        if isScrubbing {
            cancelScrub()
        } else if automation.dismissSkip() {
            // A visible prompt is a layer above the player: Back answers it
            // before it leaves.
            PlayerInputTrace.log("menu -> dismiss skip")
        } else if automation.dismissNextUp() {
            // Same rule as the skip pill.
            PlayerInputTrace.log("menu -> dismiss up next")
        } else if panelOpen,
                  selectedTab == .subtitles,
                  let subtitleSearch,
                  subtitleSearch.isBrowsingResults {
            // Back leaves the results browser before closing the panel.
            subtitleSearch.closeResults()
            playerFocus = .track("subtitle-search")
        } else if panelOpen {
            closePanel()
        } else {
            PlayerInputTrace.log("menu -> close player")
            onDismiss()
        }
    }

    /// `debug.playerInputTrace`: the state an input found. Arguments are only
    /// built when the flag is on.
    private func traceInput(_ input: String) {
        PlayerInputTrace.log(
            "\(input) segment=\(automation.activeSegment?.id ?? "none") skipMode=\(automation.skipMode.rawValue)"
                + " nextUp=\(automation.showsNextUp ? 1 : 0) autoplay=\(automation.autoplayMode.rawValue)"
                + " panel=\(panelOpen ? 1 : 0) scrubbing=\(isScrubbing ? 1 : 0) focus=\(String(describing: playerFocus))"
        )
    }

    /// A light touch-surface tap only reveals the transport. It must never
    /// act as Select: no play, scrub, skip or Up Next changes.
    private func handleRemoteTouchTap() {
        traceInput("touch-tap")
        guard !panelOpen else { return }
        // A further tap while visible toggles remaining time and end time.
        if transportVisible {
            showsEndTime.toggle()
        }
        pokeControls()
    }

    #if os(iOS)
    /// Seeks ±10 s without revealing the transport, which would fight
    /// repeated double-taps.
    private func handleTouchSeek(at point: CGPoint) {
        guard !panelOpen, !isScrubbing else { return }
        let forward = point.x >= surfaceWidth / 2
        requestSeek(by: forward ? TouchSeekPolicy.step : -TouchSeekPolicy.step)
        // Same-side double-taps within the glyph's window stack (10, 20, 30 s).
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
            // Stays focusable during the panel animation so the cover is
            // never focusless; `onMoveCommand` bridges the first command.
            .focusable()
            .focused($playerFocus, equals: .surface)
        #endif
            // A modifier so its tick-rate reads stay out of this body.
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
            .onChange(of: panelOpen || isScrubbing, initial: true) { _, suppressed in
                automation.isSuppressed = suppressed
            }
        #if os(tvOS)
            .onMoveCommand { direction in
                if panelOpen {
                    // tvOS can keep focus on the surface until the tabs slide
                    // in; send this first command to the intended tab.
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
                // Left/right scrub, playing or paused. A lone press
                // self-commits as a 10 s skip.
                case .left where canScrub:
                    stepScrub(direction: -1)
                case .right where canScrub:
                    stepScrub(direction: 1)
                // No duration (live): blind ±10 s.
                case .left:
                    requestSeek(by: -10)
                    showSeekFeedback(forward: false)
                case .right:
                    requestSeek(by: 10)
                    showSeekFeedback(forward: true)
                // Mid-scrub, up/down hop chapters rather than opening the
                // panel over a virtual playhead.
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
            // Must precede the single-tap gesture so the double-tap wins.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { surfaceWidth = $0 }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                handleTouchSeek(at: point)
            }
            .onTapGesture {
                guard !panelOpen else { return }
                if controlsVisible {
                    controlsVisible = false
                } else {
                    pokeControls()
                }
            }
        #endif
    }

    #if os(tvOS)
    /// Select: commit scrub, Skip, Up Next, then play/pause. MenuPressGate
    /// delivers it, never the surface's `onTapGesture` (see its comment).
    private func handleSelect() {
        traceInput("select via=pressesEnded")
        guard !panelOpen else { return }
        if let target = scrubTarget {
            commitScrub(to: target, resume: true)
        } else if let segment = automation.activeSegment, automation.skipMode != .instant {
            // Not focusable: taking focus would move `onMoveCommand`
            // off the surface and break scrubbing.
            PlayerInputTrace.log("select -> skip")
            skip(segment)
        } else if automation.showsNextUp {
            // Not focusable either, and for the same reason.
            PlayerInputTrace.log("select -> play next")
            automation.playNext()
        } else {
            PlayerInputTrace.log("select -> toggle pause")
            requestTogglePause()
            pokeControls()
        }
    }
    #endif

    private func pokeControls() {
        controlsVisible = true
        interactionToken += 1
    }

    /// The hierarchy survives autoplay; clear only per-item state and keep
    /// the display layer for a seamless engine swap.
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
        trickplay = info.trickplay.map(TrickplayLoader.init(source:))
        reportDisplayedCaption(nil)
        #if os(tvOS)
        playerFocus = .surface
        #endif
    }

    private func showSeekFeedback(forward: Bool, seconds: Int = 10) {
        seekFeedback = SeekFeedback(forward: forward, token: (seekFeedback?.token ?? 0) + 1, seconds: seconds)
    }

    /// Custom renderers must report on-screen captions to Media
    /// Accessibility; an empty array clears it.
    private func reportDisplayedCaption(_ text: String?) {
        let strings: NSArray = text.map { [$0] } ?? []
        MACaptionAppearanceDidDisplayCaptions(strings)
    }

    // MARK: - Scrub mode

    private var isScrubbing: Bool { scrubTarget != nil }

    /// Clears the iOS centre cluster; tvOS has none.
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

    /// Needs a known duration; deliberately not gated on pause.
    private var canScrub: Bool {
        engine.duration > 0
    }

    /// Sustained input accelerates 10 → 30 → 60 s; a single press is 10 s.
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

    /// `resume` is an explicit Select/Play; drags and the timeout keep the
    /// play state.
    private func commitScrub(to target: Double, resume: Bool) {
        lastCommittedScrubTarget = target
        endScrub()
        requestSeek(to: target, resume: resume)
        pokeControls()
    }

    // MARK: - Transport intentions
    //
    // The engine is read through `@PlayerEngineRef` at the press, never
    // captured.

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
            // Resume before seeking: unpausing after fights the engine's
            // synchronizer re-anchor.
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
        // Trickplay keeps its last frame on purpose.
    }

    /// Backwards lands on the current chapter's start first, like track
    /// skip-back.
    private func jumpChapter(direction: Int) {
        let origin = scrubTarget ?? engine.timePosition
        let target = direction > 0
            ? info.chapters.first { $0.start > origin + 0.5 }
            : info.chapters.last { $0.start < origin - 3 }
        guard let target else { return }
        scrubTarget = min(max(target.start, 0), engine.duration)
        scrubRunLength = 0
        scrubHopped = true
        scrubStepToken += 1
    }

    // MARK: - Skip intro / recap and Up Next

    private func skip(_ segment: MediaSegment) {
        automation.skip(segment)
        pokeControls()
    }

    private var hint: LocalizedStringKey {
        #if os(tvOS)
        "Select to play now · Back to stay"
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
        // defaultFocus doesn't run for a mounted panel, and focusing it in
        // the same update that enables it can be rejected. Claim focus after
        // the reveal begins.
        playerFocus = .surface
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(225))
            guard panelOpen else {
                finishPanelRevealSignpost()
                return
            }

            // Resetting the scope makes tvOS resolve a visible default.
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

/// Inline ASS styling. Placement belongs to `PositionedSubtitleLayout`, so
/// no shelf padding here.
struct PlayerStyledSubtitleText: View {
    let cue: SubtitleTextCue
    let style: SubtitleRenderStyle
    /// Only the first simultaneous cue keeps the canonical identifier.
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
            // tvOS 26 deprecates `Text.+`.
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
    /// Stacked iOS double-tap total; tvOS stays at 10.
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

/// When an item will finish in wall-clock time. `PlayerEngine.rate`
/// survives a pause, so a paused item projects at its resume speed.
nonisolated enum PlaybackFinish {
    /// Beyond a day is live or an unknown duration.
    static let longestProjection: TimeInterval = 24 * 60 * 60

    static func date(from now: Date, remaining: TimeInterval, rate: Double) -> Date? {
        guard remaining.isFinite, remaining >= 0 else { return nil }
        let speed = rate.isFinite && rate > 0 ? rate : 1
        let seconds = remaining / speed
        guard seconds.isFinite, seconds <= longestProjection else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// Follows the locale's 12- or 24-hour clock.
    static func label(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        )
    }
}
