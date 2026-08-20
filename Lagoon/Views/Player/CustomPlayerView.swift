import MediaAccessibility
import OSLog
import SwiftUI

/// Full-screen custom player styled after the Infuse reference shots on
/// HEL-35: a "Swipe down for Info" hint, a bottom-left title block over a
/// thin scrubber, and a swipe-down panel of centered pill tabs
/// (Info · Video · Audio · Subtitles) above one floating material card.
/// Talks only to `PlayerEngine` so the HEL-48 engine swap never touches it.
///
/// tvOS focus invariants: the surface is focusable at all times (Menu
/// would quit the app from an unfocusable screen). Remote grammar:
/// play/pause toggles anywhere; on the surface left/right seek ±10 s while
/// playing and walk the scrub playhead while paused (HEL-39 slice 2), and
/// down opens the panel; in the panel left/right walk the tabs (selection
/// follows focus), down enters the track rows. Menu/Escape is intercepted
/// at the UIKit press layer by `MenuPressGate` — scrubbing cancels back to
/// the live position, else panel open closes the panel, otherwise the
/// player exits (SwiftUI's `onExitCommand` never fires inside a
/// fullScreenCover on tvOS 26).
struct CustomPlayerView<Surface: View>: View {
    let engine: any PlayerEngine
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
    var isPlaybackCacheActive = false
    /// Contiguous cached prefix mapped onto the title's declared duration.
    /// nil for HLS or an endpoint whose total length is not yet known.
    var bufferedFraction: Double? = nil
    let info: PlayerItemInfo
    let onDismiss: () -> Void
    /// Lets the host react to the panel opening (the debug HUD hides so
    /// it can't sit on top of the track card).
    var onPanelToggle: ((Bool) -> Void)? = nil
    /// The episode queued behind this one (HEL-66). Nil for movies, at the
    /// end of a series, and until the lookup lands.
    var nextUp: NextUpEpisode? = nil
    var onPlayNext: (() -> Void)? = nil
    /// Back during the countdown. The host has to hear about it too: the
    /// file still has its last seconds to run, and whoever handles the end
    /// of it must not autoplay over a "no".
    var onCancelNextUp: (() -> Void)? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    var subtitleStyle: SubtitleRenderStyle = .fallback
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    @ViewBuilder let surface: () -> Surface

    private struct SeekFeedback: Equatable {
        let forward: Bool
        let token: Int
    }

    @State private var controlsVisible = true
    @State private var interactionToken = 0
    @State private var panelOpen = false
    @State private var selectedTab: PlayerPanelTab = .info
    @State private var seekFeedback: SeekFeedback?
    @State private var showsBuffering = false
    /// The virtual playhead's position while scrubbing; nil when the
    /// transport is live (HEL-39 slice 2).
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
    /// Segments already acted on or waved away, so a committed skip (or a
    /// "no thanks") doesn't re-arm the moment the playhead lands.
    @State private var handledSegmentIDs: Set<String> = []
    /// 0…1, drives the auto-skip fill. Value-driven, because `withAnimation`
    /// does not survive the MenuPressGate hosting boundary (see below).
    @State private var autoSkipFill: Double = 0
    @AppStorage("playback.skipMode") private var skipModeRaw = SkipMode.autoDelay.rawValue
    /// The Up Next card, waved away with Back — stays down for the rest of
    /// the episode rather than re-arming on the next position tick.
    @State private var nextUpDismissed = false
    /// 0…1, drives the countdown fill, value-driven for the same reason
    /// `autoSkipFill` is.
    @State private var nextUpFill: Double = 0
    @AppStorage("playback.autoplayMode") private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue
    /// Only exists when the server generated trickplay tiles (slice 3).
    @State private var trickplay: TrickplayLoader?
    @FocusState private var playerFocus: PlayerControlFocus?
    @State private var panelRevealSignpostActive = false
    private let panelSignpostID = OSSignpostID(log: PlaybackPerformance.log)

    /// Slide the panel in on, and back out with, the swipe that summons it.
    private var panelMotion: Animation { .spring(duration: Motion.fast, bounce: 0.05) }
    /// Far enough to carry the tabs and card clear of the top edge.
    private var panelSlideDistance: CGFloat { 720 }

    var body: some View {
        #if os(tvOS)
        // Menu never reaches SwiftUI inside a fullScreenCover on tvOS 26;
        // the gate intercepts the press itself (see MenuPressGate).
        MenuPressGate {
            if isScrubbing {
                cancelScrub()
            } else if let segment = activeSegment, skipMode == .autoDelay {
                // Back during the countdown means "no" — the one mode with
                // a pending action to call off. In `button` mode there is
                // nothing to cancel, so Menu keeps meaning "leave".
                handledSegmentIDs.insert(segment.id)
            } else if showsNextUp, autoplayMode == .autoDelay {
                // Same rule as the skip pill: Back only cancels where
                // something is pending. In `card` mode the offer sits there
                // unanswered and Menu still means "leave".
                nextUpDismissed = true
                onCancelNextUp?()
            } else if panelOpen {
                closePanel()
            } else {
                onDismiss()
            }
        } content: {
            playerContent
        }
        .ignoresSafeArea()
        #else
        playerContent
        #endif
    }

    private var playerContent: some View {
        ZStack {
            videoSurface

            subtitleOverlay

            // Every animation in here is value-driven (.animation + value:).
            // withAnimation doesn't survive the MenuPressGate hosting
            // boundary, and neither do transitions — see the panel below and
            // the write-up in docs/playback.md.
            Group {
                if showsBuffering {
                    ProgressView()
                        .tint(.white)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: Motion.fast), value: showsBuffering)

            Group {
                if let feedback = seekFeedback {
                    seekIndicator(feedback)
                }
            }
            .animation(.easeOut(duration: Motion.fast), value: seekFeedback)

            skipOverlay

            nextUpOverlay

            transportOverlay
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
                #endif
                // Asymmetric: target-state-conditional animation — fast
                // in, gentle out.
                .animation(
                    controlsVisible ? .easeOut(duration: Motion.fast) : .easeInOut(duration: Motion.slow),
                    value: controlsVisible
                )
                .animation(.easeInOut(duration: Motion.fast), value: engine.isPaused)
                .animation(.easeInOut(duration: Motion.fast), value: panelOpen)

            // The panel stays mounted and slides out of frame rather than
            // being inserted. A *transition* needs an animation transaction
            // at the moment of insertion, and none survives MenuPressGate's
            // rootView reassignment — tried twice, including forwarding
            // context.transaction, and frame capture showed it still popping
            // between two frames 0.04 s apart. A plain value change does
            // survive, so the slide is an offset. Disabled while closed so
            // its buttons stay out of the focus engine's reach.
            panel
                .offset(y: panelOpen ? 0 : -panelSlideDistance)
                .opacity(panelOpen ? 1 : 0)
                .disabled(!panelOpen)
                .animation(panelMotion, value: panelOpen)

        }
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        .onPlayPauseCommand {
            if let target = scrubTarget {
                commitScrub(to: target, resume: true)
            } else {
                engine.togglePause()
                pokeControls()
            }
        }
        #endif
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
        // instant local seeks used to flash it on every press (HEL-39).
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
        .onChange(of: engine.currentSubtitleText, initial: true) { _, text in
            reportDisplayedCaption(text)
        }
        .onDisappear {
            reportDisplayedCaption(nil)
        }
        // Arms whenever the playhead crosses into a skippable segment.
        // Keyed on the segment id, so it fires once per segment rather than
        // on every position tick.
        .task(id: activeSegment?.id) {
            guard let segment = activeSegment else {
                autoSkipFill = 0
                return
            }
            switch skipMode {
            case .instant:
                skip(segment)
            case .autoDelay:
                autoSkipFill = 1
                try? await Task.sleep(for: .seconds(SkipMode.autoDelaySeconds))
                // Menu may have waved it away, or a scrub may have carried
                // the playhead out, while the fill was running.
                guard !Task.isCancelled, activeSegment?.id == segment.id else { return }
                skip(segment)
            case .button:
                break
            }
        }
        // Arms as the playhead crosses into the countdown window. Keyed on
        // the flag rather than the position so it fires once, not ten times
        // a second.
        .task(id: nextUpCountingDown) {
            guard nextUpCountingDown else {
                nextUpFill = 0
                return
            }
            nextUpFill = 1
            try? await Task.sleep(for: .seconds(AutoplayMode.countdownSeconds))
            // Back may have waved it away, or a scrub carried the playhead
            // back out of the credits, while the fill was running.
            guard !Task.isCancelled, nextUpCountingDown else { return }
            onPlayNext?()
        }
        // Two beats of quiet, both timed from the last press. The first
        // ends the acceleration run, so the next press steps 10 s again.
        // The second lands the scrub on its own: without it, opening scrub
        // during playback would cost a Select to confirm every small skip,
        // and the ±10 s nudge would have nowhere to live (HEL-55).
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
        PlayerSeekIndicator(forward: feedback.forward)
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    // MARK: - Surface & remote commands

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
            // The regression suite reads state from the surface that owns
            // focus. A separate invisible accessibility element stole arrow
            // focus on the first hardware run and therefore tested the
            // probe, not the player.
            .accessibilityIdentifier(
                UserDefaults.standard.bool(forKey: "debug.playerRegression")
                    ? "player.regression.state"
                    : ""
            )
            .accessibilityValue(
                UserDefaults.standard.bool(forKey: "debug.playerRegression")
                    ? regressionAccessibilityValue
                    : ""
            )
            .onMoveCommand { direction in
                if panelOpen {
                    // tvOS can retain the full-screen surface until the
                    // sliding tabs fully enter its focus region. Do not eat
                    // that first command: move the selection and focus to
                    // the tab the command was trying to reach.
                    if direction == .left || direction == .right,
                       let index = PlayerPanelTab.allCases.firstIndex(of: selectedTab) {
                        let delta = direction == .right ? 1 : -1
                        let targetIndex = min(max(index + delta, 0), PlayerPanelTab.allCases.count - 1)
                        let target = PlayerPanelTab.allCases[targetIndex]
                        selectedTab = target
                        playerFocus = .tab(target)
                    } else {
                        playerFocus = .tab(selectedTab)
                    }
                    return
                }
                switch direction {
                // Left/right open scrub rather than seeking blind, playing
                // or paused (HEL-55). A lone press still reads as a 10 s
                // skip — it just previews the frame first and lands itself
                // a beat later; holding accelerates into a real scrub.
                case .left where canScrub:
                    stepScrub(direction: -1)
                case .right where canScrub:
                    stepScrub(direction: 1)
                // No duration to walk along (live streams): blind ±10 s,
                // with the glyph as the only feedback available.
                case .left:
                    engine.seek(by: -10)
                    showSeekFeedback(forward: false)
                case .right:
                    engine.seek(by: 10)
                    showSeekFeedback(forward: true)
                // Mid-scrub, up/down hop chapters (HEL-39 slice 3). Down
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
            .onTapGesture {
                guard !panelOpen else { return }
                #if os(tvOS)
                // Select commits a scrub and plays on from there — the
                // native tvOS grammar; otherwise it's play/pause.
                if let target = scrubTarget {
                    commitScrub(to: target, resume: true)
                } else if let segment = activeSegment, skipMode != .instant {
                    // The button is deliberately not focusable: taking focus
                    // would move `onMoveCommand` off the surface and kill
                    // scrubbing while it is up (HEL-63). Select acts on it
                    // instead, which is also the grammar Jaagop described.
                    skip(segment)
                } else if showsNextUp {
                    // Not focusable either, and for the same reason.
                    onPlayNext?()
                } else {
                    engine.togglePause()
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
        handledSegmentIDs.removeAll()
        autoSkipFill = 0
        nextUpDismissed = false
        nextUpFill = 0
        trickplay = info.trickplay.map(TrickplayLoader.init(source:))
        reportDisplayedCaption(nil)
        #if os(tvOS)
        playerFocus = .surface
        #endif
    }

    private func showSeekFeedback(forward: Bool) {
        seekFeedback = SeekFeedback(forward: forward, token: (seekFeedback?.token ?? 0) + 1)
    }

    /// Custom renderers must tell Media Accessibility which caption text is
    /// currently onscreen; an empty array explicitly clears the report.
    private func reportDisplayedCaption(_ text: String?) {
        let strings: NSArray = text.map { [$0] } ?? []
        MACaptionAppearanceDidDisplayCaptions(strings)
    }

    // MARK: - Scrub mode (HEL-39 slice 2)

    private var isScrubbing: Bool { scrubTarget != nil }

    private var transportVisible: Bool {
        (controlsVisible || engine.isPaused || isScrubbing) && !panelOpen
    }

    /// Walking a virtual playhead needs a known duration to walk along;
    /// without one (live streams) the arrows stay plain ±10 s seeks.
    ///
    /// Playback is deliberately no bar to it. This used to also require
    /// `engine.isPaused`, which left trickplay, chapter ticks and chapter
    /// hopping unreachable for anyone who never guessed they had to pause
    /// first — the whole of HEL-55.
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
        // Resume before seeking: the engine re-anchors the synchronizer
        // when the seek primes, so unpausing afterwards fights that
        // hand-off.
        if resume, engine.isPaused {
            engine.togglePause()
        }
        engine.seek(to: target)
        pokeControls()
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

    /// Chapter hop while scrubbing (HEL-39 slice 3). Backwards lands on the
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

    /// The chapter the scrub playhead is sitting in, for the chip's caption.
    private var scrubChapter: PlayerChapter? {
        guard let target = scrubTarget else { return nil }
        return info.chapters.last { $0.start <= target }
    }

    /// Where the playhead knob sits: the virtual position while scrubbing,
    /// the engine's otherwise.
    private var knobFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        let seconds = scrubTarget ?? engine.timePosition
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    // MARK: - Skip intro / recap (HEL-63)

    private var skipMode: SkipMode { SkipMode(rawValue: skipModeRaw) ?? .autoDelay }

    /// The skippable segment the playhead is inside, if any.
    ///
    /// Suppressed while the panel is open or a scrub is up: both own the
    /// screen and the remote, and a button that quietly rewrites what Select
    /// does underneath them would be a trap.
    private var activeSegment: MediaSegment? {
        guard !panelOpen, !isScrubbing else { return nil }
        return info.segments.first {
            $0.kind.isSkippable
                && !handledSegmentIDs.contains($0.id)
                && $0.contains(engine.timePosition)
        }
    }

    private func skip(_ segment: MediaSegment) {
        // Marked before seeking: landing near the end would otherwise put
        // the playhead back inside the segment and re-arm the whole thing.
        handledSegmentIDs.insert(segment.id)
        autoSkipFill = 0
        engine.seek(to: segment.end)
        pokeControls()
    }

    /// Bottom-trailing, clear of the transport — the shelf the reference
    /// players use. Not focusable; Select drives it (see `onTapGesture`).
    @ViewBuilder
    private var skipOverlay: some View {
        Group {
            if let segment = activeSegment, skipMode != .instant {
                PlayerSkipPrompt(
                    title: segment.kind.skipTitle,
                    showsCountdown: skipMode == .autoDelay,
                    fill: autoSkipFill
                )
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, Metrics.screenGutter)
                .padding(.bottom, SkipMetrics.bottomInset)
            }
        }
        .animation(.easeOut(duration: Motion.fast), value: activeSegment?.id)
        #if os(tvOS)
        .allowsHitTesting(false)
        #else
        .onTapGesture {
            if let segment = activeSegment, skipMode != .instant {
                skip(segment)
            }
        }
        .accessibilityAddTraits(.isButton)
        #endif
    }

    // MARK: - Up Next (HEL-66)

    private var autoplayMode: AutoplayMode { AutoplayMode(rawValue: autoplayModeRaw) ?? .autoDelay }

    /// The credits, when the server marked them. `MediaSegment.Kind.outro`
    /// is deliberately not skippable (HEL-63) — this is what it is for.
    private var outro: MediaSegment? {
        info.segments.first { $0.kind == .outro }
    }

    /// When the card appears. With an outro that is where the credits start;
    /// without one it is a short fixed run-out, because guessing any earlier
    /// would put the card over the closing scene.
    private var nextUpStart: Double? {
        guard nextUp != nil, autoplayMode != .off, engine.duration > 0 else { return nil }
        if let outro { return outro.start }
        return engine.duration - NextUpMetrics.fallbackLeadIn
    }

    /// When the fill starts, which is not always when the card does.
    ///
    /// With an outro there are credits to cut short, so the countdown runs
    /// from their first frame — the whole point of the feature. Without one
    /// the server has told us nothing about where the episode stops being
    /// the episode, so the fill is pinned to the last seconds of the file
    /// and autoplay can never eat content nobody called credits.
    private var nextUpCountdownStart: Double? {
        guard let nextUpStart else { return nil }
        if outro != nil { return nextUpStart }
        return max(nextUpStart, engine.duration - AutoplayMode.countdownSeconds)
    }

    /// Suppressed while the panel is open or a scrub is up, exactly as the
    /// skip pill is: both own the screen and the remote.
    private var showsNextUp: Bool {
        guard let nextUpStart, !nextUpDismissed, !panelOpen, !isScrubbing else { return false }
        return engine.timePosition >= nextUpStart
    }

    private var nextUpCountingDown: Bool {
        guard showsNextUp, autoplayMode == .autoDelay, let start = nextUpCountdownStart else { return false }
        return engine.timePosition >= start
    }

    /// Bottom-trailing, on the same shelf as the skip pill. The two can
    /// never be up together — intro and recap live at the front of an
    /// episode, the credits at the back — so they share the corner rather
    /// than competing for it.
    @ViewBuilder
    private var nextUpOverlay: some View {
        Group {
            if showsNextUp, let nextUp {
                PlayerNextUpCard(
                    episode: nextUp,
                    showsCountdown: autoplayMode == .autoDelay,
                    fill: nextUpFill,
                    hint: hint
                )
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, Metrics.screenGutter)
                .padding(.bottom, NextUpMetrics.bottomInset)
                #if !os(tvOS)
                // Touch has no Select to route, so the card takes the tap
                // itself — see the hit-testing note below.
                .onTapGesture { onPlayNext?() }
                #endif
            }
        }
        .animation(.easeOut(duration: Motion.fast), value: showsNextUp)
        // tvOS drives this from the surface's Select, and a focusable card
        // would move `onMoveCommand` off the surface and kill scrubbing
        // while it is up — the same trap the skip pill documents.
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }

    private var hint: LocalizedStringKey {
        #if os(tvOS)
        autoplayMode == .autoDelay ? "Select to play now · Back to stay" : "Select to play now"
        #else
        "Tap to play now"
        #endif
    }

    // MARK: - Subtitles (HEL-48 M5)

    /// Bitmap cues (PGS/VobSub) land exactly where they compose on the
    /// video plane; text cues sit bottom-center Infuse-style.
    private var subtitleOverlay: some View {
        GeometryReader { proxy in
            let videoRect = displayedVideoRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(engine.currentSubtitleImages.enumerated()), id: \.offset) { _, cue in
                    Image(decorative: cue.image, scale: 1)
                        .resizable()
                        .accessibilityIdentifier("player.subtitle.image")
                        .frame(
                            width: videoRect.width * cue.rect.width,
                            height: videoRect.height * cue.rect.height
                        )
                        .position(
                            x: videoRect.minX + videoRect.width * cue.rect.midX,
                            y: videoRect.minY + videoRect.height * cue.rect.midY
                        )
                }
                if let text = engine.currentSubtitleText {
                    VStack {
                        Spacer()
                        PlayerSubtitleText(text: text, style: subtitleStyle)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Where the aspect-fit video actually sits inside the surface.
    private func displayedVideoRect(in container: CGSize) -> CGRect {
        guard let videoSize = engine.videoSize, videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
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

    private var transportOverlay: some View {
        VStack {
            #if os(tvOS)
            VStack(spacing: Metrics.Space.hair) {
                Text("Swipe down for Info")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.compact.down")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.top, Metrics.railTopPadding)
            // Down is dead while scrubbing — don't advertise it.
            .opacity(isScrubbing ? 0 : 1)
            .animation(.easeInOut(duration: Motion.fast), value: isScrubbing)
            #else
            HStack(spacing: Metrics.Space.m) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                Spacer()
                Button {
                    openPanel()
                } label: {
                    Image(systemName: "info.circle")
                }
                Button {
                    engine.togglePause()
                } label: {
                    Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                }
            }
            .buttonStyle(.glass)
            .padding(Metrics.screenGutter)
            #endif

            Spacer()

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                        if let subtitle = info.subtitle {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Text(info.title)
                            .font(.title2.bold())
                    }
                    Spacer()
                    if engine.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                // Scrubbing hands this space to the time pill (and, from
                // slice 3, the trickplay frame).
                .opacity(isScrubbing ? 0 : 1)
                .animation(.easeInOut(duration: Motion.fast), value: isScrubbing)
                .allowsHitTesting(false)

                scrubber

                HStack {
                    Text(Self.timestamp(engine.timePosition))
                    Spacer()
                    Text("-" + Self.timestamp(max(engine.duration - engine.timePosition, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
            .padding(Metrics.screenGutter)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                // Taps in the gutter belong to the surface underneath —
                // as do the title and time rows above. On iOS the bar
                // between them is the one thing here that takes a touch.
                .allowsHitTesting(false)
            )
        }
        .foregroundStyle(.white)
    }

    /// The bar: a live-position fill, chapter ticks, the playhead knob
    /// (which detaches into the virtual playhead while scrubbing), and the
    /// scrub chip above it.
    private var scrubber: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.16))
                if let bufferedFraction, bufferedFraction > 0 {
                    Capsule()
                        .fill(.white.opacity(0.38))
                        .frame(width: width * CGFloat(min(max(bufferedFraction, 0), 1)))
                        .animation(liveMotion, value: bufferedFraction)
                }
                Capsule()
                    .fill(.white)
                    .frame(width: max(width * fillFraction, Metrics.scrubberHeight))
                    // Glides between the engine's 0.1 s position updates
                    // instead of ticking (HEL-39); big deltas (seeks)
                    // become a quick slide to the target.
                    .animation(fillMotion, value: fillFraction)
                chapterTicks(in: width)
                knob(in: width)
            }
            .overlay(alignment: .bottomLeading) { scrubChip(in: width) }
            #if os(iOS)
            // A 8pt bar is an unusable touch target on its own.
            .contentShape(Rectangle().inset(by: -16))
            .gesture(scrubDrag(in: width))
            #endif
        }
        .frame(height: Metrics.scrubberHeight)
    }

    @ViewBuilder
    private func knob(in width: CGFloat) -> some View {
        // tvOS only draws a knob while scrubbing — the rest of the time the
        // fill edge is the playhead, per the Infuse reference. Touch always
        // shows one: it's the drag affordance.
        #if os(tvOS)
        let visible = isScrubbing
        #else
        let visible = true
        #endif
        Capsule()
            .fill(.white)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .frame(width: ScrubMetrics.knobWidth, height: Metrics.scrubberHeight + ScrubMetrics.knobOverhang)
            .offset(x: min(max(width * knobFraction - ScrubMetrics.knobWidth / 2, 0), max(width - ScrubMetrics.knobWidth, 0)))
            .opacity(visible ? 1 : 0)
            .animation(scrubMotion, value: knobFraction)
            .animation(.easeOut(duration: Motion.fast), value: isScrubbing)
    }

    /// Chapter boundaries, drawn over the fill so they read on both halves
    /// of the bar. Nothing at 0:00 — a tick under the playhead is noise.
    @ViewBuilder
    private func chapterTicks(in width: CGFloat) -> some View {
        if engine.duration > 0 {
            ForEach(info.chapters.filter { $0.start > 1 && $0.start < engine.duration }) { chapter in
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: width * CGFloat(chapter.start / engine.duration))
            }
        }
    }

    /// What floats above the playhead while scrubbing: the trickplay frame
    /// when the server has tiles, the timestamp always, and the chapter it
    /// lands in when the item has chapters. Anchored bottom-left so the
    /// chip's height never has to be known — it grows upward off the bar.
    @ViewBuilder
    private func scrubChip(in width: CGFloat) -> some View {
        Group {
            if let target = scrubTarget {
                VStack(spacing: Metrics.Space.s) {
                    trickplayFrame
                    Text(Self.timestamp(target))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .frame(width: ScrubMetrics.pillWidth, height: ScrubMetrics.pillHeight)
                        .background(.black.opacity(0.7), in: Capsule())
                    if let name = scrubChapter?.name {
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, Metrics.Space.s)
                            .padding(.vertical, Metrics.Space.xs)
                            .background(.black.opacity(0.7), in: Capsule())
                    }
                }
                .foregroundStyle(.white)
                .frame(width: chipWidth)
                .offset(
                    x: min(max(width * knobFraction - chipWidth / 2, 0), max(width - chipWidth, 0)),
                    y: -(Metrics.scrubberHeight + 14)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                .animation(scrubMotion, value: knobFraction)
                .accessibilityIdentifier("player.scrub.chip")
            }
        }
        .animation(.easeOut(duration: Motion.fast), value: isScrubbing)
        .allowsHitTesting(false)
    }

    /// The preview image, or its empty frame while the sheet downloads —
    /// reserving the space keeps the chip from resizing under the caption
    /// when the picture lands.
    @ViewBuilder
    private var trickplayFrame: some View {
        if let size = previewSize {
            Group {
                if let image = trickplay?.frame {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.black.opacity(0.7)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.cardArtRadius)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
            .animation(.easeOut(duration: Motion.fast), value: trickplay?.frame == nil)
            .accessibilityIdentifier("player.scrub.preview")
        }
    }

    /// Preview size at the chip's width, in the tiles' own aspect ratio (not
    /// every library is 16:9).
    private var previewSize: CGSize? {
        guard trickplay?.isUnavailable != true,
              let source = info.trickplay, source.tileSize.width > 0, source.tileSize.height > 0 else { return nil }
        let width = ScrubMetrics.previewWidth
        return CGSize(width: width, height: (width * source.tileSize.height / source.tileSize.width).rounded())
    }

    private var chipWidth: CGFloat {
        max(previewSize?.width ?? 0, ScrubMetrics.pillWidth)
    }

    /// The live playhead's curve, matched to the engine's position-update
    /// cadence so the bar glides instead of ticking.
    private var liveMotion: Animation { .linear(duration: 0.25) }

    /// Scrub steps snap over; while live the knob must glide on exactly the
    /// fill's curve, or the two drift apart between position updates.
    private var scrubMotion: Animation {
        isScrubbing ? .easeOut(duration: Motion.fast) : liveMotion
    }

    /// What the *fill* follows, which is no longer the same thing. Now that
    /// scrub opens without pausing (HEL-55), the tvOS fill keeps showing the
    /// live position throughout a scrub — so it has to keep the live curve
    /// too, or every position update behind the chip would ease out and
    /// stall instead of gliding. Touch is the other way round: there the
    /// fill *is* what the thumb drags, so it takes the scrub curve.
    private var fillMotion: Animation {
        #if os(tvOS)
        liveMotion
        #else
        scrubMotion
        #endif
    }

    /// How much of the bar is filled. Touch drags the fill along with the
    /// thumb — direct manipulation, and release always commits. The remote
    /// leaves it at the frozen live position instead, so while the knob
    /// walks ahead the fill still shows where Menu would cancel back to.
    private var fillFraction: CGFloat {
        #if os(tvOS)
        progressFraction
        #else
        isScrubbing ? knobFraction : progressFraction
        #endif
    }

    #if os(iOS)
    /// Touch grammar: a tap on the bar is a seek, a drag is a scrub —
    /// both land the same way and neither changes the play state. Only
    /// the release seeks; every intermediate position would flush the
    /// engine's queues and re-demux.
    private func scrubDrag(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let seconds = scrubSeconds(at: value.location.x, in: width) else { return }
                scrubTarget = seconds
                pokeControls()
            }
            .onEnded { value in
                guard let seconds = scrubSeconds(at: value.location.x, in: width) else {
                    cancelScrub()
                    return
                }
                commitScrub(to: seconds, resume: false)
            }
    }

    private func scrubSeconds(at x: CGFloat, in width: CGFloat) -> Double? {
        guard width > 0, engine.duration > 0 else { return nil }
        return Double(min(max(x / width, 0), 1)) * engine.duration
    }
    #endif

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
            onDismiss: closePanel
        )
        .equatable()
    }

    /// A one-pixel, launch-gated accessibility probe for the physical-device
    /// UI suite. It observes the same view state the viewer sees; it does not
    /// call player actions or replace the Siri Remote interaction path.
    private var regressionAccessibilityValue: String {
        let selectedAudio = engine.audioTracks.first(where: \.isSelected)?.engineID ?? 0
        let selectedSubtitle = engine.subtitleTracks.first(where: \.isSelected)?.engineID ?? 0
        let skippable = info.segments.first(where: { $0.kind.isSkippable })
        let skippableStart: Double = skippable?.start ?? -1
        let skippableEnd: Double = skippable?.end ?? -1
        let focusDescription: String = switch playerFocus {
        case .surface: "surface"
        case .tab(let tab): "tab-\(String(describing: tab))"
        case .track(let id): "track-\(id)"
        case nil: "none"
        }
        let memory = MemorySnapshot.current()
        let lifecycle = PlaybackLifecycleDiagnostics.snapshot()
        return [
            "item=\(playbackIdentity)",
            "surface=\(playerSurfaceIdentity)",
            "method=\(playbackMethod.rawValue)",
            "cache=\(isPlaybackCacheActive ? 1 : 0)",
            String(format: "buffered=%.3f", bufferedFraction ?? -1),
            String(format: "handoffMs=%.1f", handoffMilliseconds ?? -1),
            "nextUp=\(showsNextUp ? 1 : 0)",
            "ready=\(engine.duration > 0 ? 1 : 0)",
            String(format: "time=%.1f", engine.timePosition),
            String(format: "duration=%.1f", engine.duration),
            "paused=\(engine.isPaused ? 1 : 0)",
            "buffering=\(engine.isBuffering ? 1 : 0)",
            "stalls=\(engine.stallCount)",
            "audioRecoveries=\(engine.audioRendererRecoveryCount)",
            "mediaResetRecoveries=\(engine.mediaServicesResetRecoveryCount)",
            String(format: "memoryMB=%.1f", memory.footprintMB),
            "engines=\(lifecycle.liveEngines)",
            "controllers=\(lifecycle.liveControllers)",
            "demux=\(lifecycle.activeDemuxLoops)",
            "renderers=\(lifecycle.attachedRendererSets)",
            "unclean=\(lifecycle.uncleanEngineDestructions)",
            "scrubbing=\(isScrubbing ? 1 : 0)",
            String(format: "lastScrub=%.1f", lastCommittedScrubTarget),
            "panel=\(panelOpen ? 1 : 0)",
            "tab=\(String(describing: selectedTab))",
            "focus=\(focusDescription)",
            "audio=\(selectedAudio)",
            "audioPath=\(engine.audioOutputPathDiagnostic)",
            "audioCount=\(engine.audioTracks.count)",
            "subtitle=\(selectedSubtitle)",
            "subtitleCount=\(engine.subtitleTracks.count)",
            "subtitleVisible=\((engine.currentSubtitleText != nil || !engine.currentSubtitleImages.isEmpty) ? 1 : 0)",
            "chapters=\(info.chapters.count)",
            "trickplay=\(info.trickplay == nil ? 0 : 1)",
            "trickplayFrame=\(trickplay?.frame == nil ? 0 : 1)",
            "segments=\(info.segments.count)",
            String(format: "skippableStart=%.1f", skippableStart),
            String(format: "skippableEnd=%.1f", skippableEnd),
        ].joined(separator: " ")
    }

    private var progressFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(engine.timePosition / engine.duration, 0), 1))
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// Shared player chrome rendered by both live playback and the Debug-only
/// component gallery. Keeping one implementation means gallery approval is
/// approval of the view that actually ships.
struct PlayerSkipPrompt: View {
    let title: String
    let showsCountdown: Bool
    let fill: Double
    var accessibilityIdentifier = "player.skip"

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: "forward.end.alt.fill")
                .font(.caption.weight(.bold))
            Text(title)
                .font(.callout.weight(.semibold))
        }
        .accessibilityIdentifier(accessibilityIdentifier)
        .foregroundStyle(.black)
        .frame(width: SkipMetrics.width, height: SkipMetrics.height)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.55))
                if showsCountdown {
                    Capsule()
                        .fill(.white)
                        .frame(width: SkipMetrics.width * min(max(fill, 0), 1))
                        .animation(
                            .linear(duration: SkipMode.autoDelaySeconds),
                            value: fill
                        )
                }
            }
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

struct PlayerNextUpCard: View {
    let episode: NextUpEpisode
    let showsCountdown: Bool
    let fill: Double
    let hint: LocalizedStringKey
    var accessibilityIdentifier = "player.nextUp"

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("Up Next")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: Metrics.Space.m) {
                CachedAsyncImage(
                    url: episode.imageURL,
                    maxPixelSize: Int(NextUpMetrics.thumbnailWidth * 2)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(
                    width: NextUpMetrics.thumbnailWidth,
                    height: (NextUpMetrics.thumbnailWidth * 9 / 16).rounded()
                )
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

                VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                    if let subtitle = episode.subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if showsCountdown {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: NextUpMetrics.barHeight)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * min(max(fill, 0), 1))
                                .animation(
                                    .linear(duration: AutoplayMode.countdownSeconds),
                                    value: fill
                                )
                        }
                    }
                    .frame(height: NextUpMetrics.barHeight)
            }

            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Metrics.Space.l)
        .frame(width: NextUpMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .accessibilityIdentifier(accessibilityIdentifier)
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
            .padding(.bottom, style.bottomPadding)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct PlayerSeekIndicator: View {
    let forward: Bool
    var accessibilityIdentifier = "player.seekFeedback"

    var body: some View {
        HStack {
            if forward { Spacer() }
            Image(systemName: forward ? "goforward.10" : "gobackward.10")
                .font(Typography.glyph.weight(.semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
            if !forward { Spacer() }
        }
        .padding(.horizontal, Metrics.screenGutter * 2)
        .allowsHitTesting(false)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Skip-button geometry (HEL-63). Fixed width so the countdown fill can be
/// sized from it without a GeometryReader.
private enum SkipMetrics {
    #if os(tvOS)
    static let width: CGFloat = 260
    static let height: CGFloat = 56
    /// Clears the transport so the two never overlap.
    static let bottomInset: CGFloat = 240
    #else
    static let width: CGFloat = 170
    static let height: CGFloat = 40
    static let bottomInset: CGFloat = 130
    #endif
}

private enum NextUpMetrics {
    #if os(tvOS)
    static let width: CGFloat = 520
    static let thumbnailWidth: CGFloat = 150
    /// Clears the transport so the two never overlap, same as `SkipMetrics`.
    static let bottomInset: CGFloat = 240
    static let barHeight: CGFloat = 6
    #else
    static let width: CGFloat = 300
    static let thumbnailWidth: CGFloat = 88
    static let bottomInset: CGFloat = 130
    static let barHeight: CGFloat = 4
    #endif
    /// With no `Outro` segment there is nothing to say where the credits
    /// begin, so the card appears on a fixed run-out instead. Long enough
    /// to read and act on, short enough not to sit over the closing scene.
    static let fallbackLeadIn: Double = 15
}

/// Scrub-bar geometry. Lives outside `CustomPlayerView` because the view is
/// generic over its surface, and generics can't hold static storage. The
/// pill has a fixed width so the edge clamping is exact.
private enum ScrubMetrics {
    /// No input for this long and the acceleration run expires, so the next
    /// press is a 10 s step again rather than a 60 s one.
    static let runExpiry: Duration = .milliseconds(600)
    /// A further beat after that and the scrub lands itself. This is what
    /// keeps a single press a plain 10 s skip now that scrub opens during
    /// playback (HEL-55) — tune it on hardware, not in the simulator: too
    /// short and a preview can't be read, too long and a nudge feels stuck.
    static let selfCommit: Duration = .milliseconds(600)
    /// A chapter hop waits longer than a step before landing. Found on
    /// hardware (HEL-55, 2026-08-18): a hop is a *survey* gesture — you are
    /// reading where chapter 13 starts — where an arrow step is a nudge, and
    /// sharing the step's window turned browsing past the next chapter into
    /// a race against the timer.
    static let chapterSelfCommit: Duration = .milliseconds(2000)

    #if os(tvOS)
    static let knobWidth: CGFloat = 8
    static let knobOverhang: CGFloat = 12
    static let pillWidth: CGFloat = 150
    static let pillHeight: CGFloat = 52
    /// Matches the 320 px tiles Jellyfin generates by default, so the
    /// preview is shown at its native resolution rather than upscaled.
    static let previewWidth: CGFloat = 320
    #else
    static let knobWidth: CGFloat = 14
    static let knobOverhang: CGFloat = 6
    static let pillWidth: CGFloat = 88
    static let pillHeight: CGFloat = 34
    static let previewWidth: CGFloat = 160
    #endif
}
