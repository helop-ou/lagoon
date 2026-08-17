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
    let info: PlayerItemInfo
    let onDismiss: () -> Void
    /// Lets the host react to the panel opening (the debug HUD hides so
    /// it can't sit on top of the track card).
    var onPanelToggle: ((Bool) -> Void)? = nil
    @ViewBuilder let surface: () -> Surface

    private enum PanelTab: CaseIterable, Hashable {
        case info
        case video
        case audio
        case subtitles

        var title: String {
            switch self {
            case .info: String(localized: "Info")
            case .video: String(localized: "Video")
            case .audio: String(localized: "Audio")
            case .subtitles: String(localized: "Subtitles")
            }
        }
    }

    private struct SeekFeedback: Equatable {
        let forward: Bool
        let token: Int
    }

    @State private var controlsVisible = true
    @State private var interactionToken = 0
    @State private var panelOpen = false
    @State private var selectedTab: PanelTab = .info
    @State private var seekFeedback: SeekFeedback?
    @State private var showsBuffering = false
    /// The virtual playhead's position while scrubbing; nil when the
    /// transport is live (HEL-39 slice 2).
    @State private var scrubTarget: Double?
    /// How many scrub steps this run of uninterrupted input has taken —
    /// what the step size accelerates on. Expires with `scrubStepToken`.
    @State private var scrubRunLength = 0
    @State private var scrubStepToken = 0
    @FocusState private var focusedTab: PanelTab?

    var body: some View {
        #if os(tvOS)
        // Menu never reaches SwiftUI inside a fullScreenCover on tvOS 26;
        // the gate intercepts the press itself (see MenuPressGate).
        MenuPressGate {
            if isScrubbing {
                cancelScrub()
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

            // Every animation in here must be value-driven (.animation +
            // value:), never withAnimation: the transaction doesn't
            // survive the MenuPressGate hosting boundary, so withAnimation
            // changes land instantly (found by Jaagop — the panel popped
            // instead of sliding).
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

            Group {
                if panelOpen {
                    // The remote gesture is a swipe down, so the panel
                    // slides down with it (and back up on close).
                    panel
                        .transition(.move(edge: .top))
                }
            }
            .animation(.spring(duration: Motion.standard, bounce: 0.1), value: panelOpen)
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
        .onChange(of: focusedTab) { _, tab in
            if let tab {
                withAnimation(.easeInOut(duration: Motion.fast)) { selectedTab = tab }
            }
        }
        .task(id: interactionToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !panelOpen, !engine.isPaused else { return }
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
        // A pause in the input ends the acceleration run, so the next
        // press starts back at a 10 s step.
        .task(id: scrubStepToken) {
            guard scrubRunLength > 0 else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            scrubRunLength = 0
        }
    }

    private func seekIndicator(_ feedback: SeekFeedback) -> some View {
        HStack {
            if feedback.forward { Spacer() }
            Image(systemName: feedback.forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 6)
            if !feedback.forward { Spacer() }
        }
        .padding(.horizontal, Metrics.screenGutter * 2)
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
        .allowsHitTesting(false)
    }

    // MARK: - Surface & remote commands

    private var videoSurface: some View {
        surface()
            .ignoresSafeArea()
        #if os(tvOS)
            // Always focusable: if the surface could resign focus, any
            // instant with nothing focused would route Menu straight to the
            // fullScreenCover's default dismissal (and melt the focus
            // system with it — seen as a full app freeze). With the panel
            // open, arrows just nudge focus into the panel instead.
            .focusable()
            .onMoveCommand { direction in
                if panelOpen {
                    focusedTab = selectedTab
                    return
                }
                switch direction {
                case .left where canScrub:
                    stepScrub(direction: -1)
                case .right where canScrub:
                    stepScrub(direction: 1)
                case .left:
                    engine.seek(by: -10)
                    showSeekFeedback(forward: false)
                case .right:
                    engine.seek(by: 10)
                    showSeekFeedback(forward: true)
                case .down:
                    // Up/down are dead while scrubbing: opening the panel
                    // would strand a virtual playhead behind it.
                    if !isScrubbing { openPanel() }
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

    private func showSeekFeedback(forward: Bool) {
        seekFeedback = SeekFeedback(forward: forward, token: (seekFeedback?.token ?? 0) + 1)
    }

    // MARK: - Scrub mode (HEL-39 slice 2)

    private var isScrubbing: Bool { scrubTarget != nil }

    private var transportVisible: Bool {
        (controlsVisible || engine.isPaused) && !panelOpen
    }

    /// The pause-then-walk grammar needs a known duration to walk along;
    /// without one the arrows stay ±10 s seeks.
    private var canScrub: Bool {
        engine.isPaused && engine.duration > 0
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
        scrubStepToken += 1
    }

    /// Lands the virtual playhead. `resume` is the tvOS grammar (Select/Play
    /// scrubs *and* plays on); touch drags keep the current play state.
    private func commitScrub(to target: Double, resume: Bool) {
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
    }

    /// Where the playhead knob sits: the virtual position while scrubbing,
    /// the engine's otherwise.
    private var knobFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        let seconds = scrubTarget ?? engine.timePosition
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
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
                        Text(text)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.bottom, Metrics.screenGutter)
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
        panelOpen = true
        onPanelToggle?(true)
        // defaultFocus is only honored when a fresh scene appears — for a
        // mid-screen reveal tvOS leaves focus where it was, stranding the
        // panel. Claim focus immediately (an unfocused instant would send
        // Menu straight to the cover's default dismissal) and again once
        // the reveal has settled, in case the first assignment was too
        // early to take.
        focusedTab = selectedTab
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard panelOpen, focusedTab == nil else { return }
            focusedTab = selectedTab
        }
    }

    private func closePanel() {
        focusedTab = nil
        panelOpen = false
        onPanelToggle?(false)
        pokeControls()
    }

    // MARK: - Transport

    private var transportOverlay: some View {
        VStack {
            #if os(tvOS)
            VStack(spacing: 2) {
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
            HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
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

    /// The bar: a live-position fill, the playhead knob (which detaches
    /// into the virtual playhead while scrubbing), and the time pill.
    private var scrubber: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: max(width * fillFraction, Metrics.scrubberHeight))
                    // Glides between the engine's 0.1 s position updates
                    // instead of ticking (HEL-39); big deltas (seeks)
                    // become a quick slide to the target.
                    .animation(scrubMotion, value: fillFraction)
                knob(in: width)
            }
            .overlay(alignment: .topLeading) { timePill(in: width) }
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

    @ViewBuilder
    private func timePill(in width: CGFloat) -> some View {
        Group {
            if let target = scrubTarget {
                Text(Self.timestamp(target))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: ScrubMetrics.pillWidth, height: ScrubMetrics.pillHeight)
                    .background(.black.opacity(0.7), in: Capsule())
                    .offset(
                        x: min(max(width * knobFraction - ScrubMetrics.pillWidth / 2, 0), max(width - ScrubMetrics.pillWidth, 0)),
                        y: -(ScrubMetrics.pillHeight + 14)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                    .animation(scrubMotion, value: knobFraction)
            }
        }
        .animation(.easeOut(duration: Motion.fast), value: isScrubbing)
        .allowsHitTesting(false)
    }

    /// Scrub steps snap over; while live the knob must glide on exactly the
    /// fill's curve, or the two drift apart between position updates.
    private var scrubMotion: Animation {
        isScrubbing ? .easeOut(duration: Motion.fast) : .linear(duration: 0.25)
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

    private static var subtitleOffID: String { "subtitle-off" }

    private var panel: some View {
        VStack(spacing: 24) {
            tabBar

            tabCard
                .padding(.horizontal, Metrics.screenGutter)

            Spacer()
        }
        .padding(.top, Metrics.railTopPadding)
        .defaultFocus($focusedTab, selectedTab)
        #if os(iOS)
        .background(
            // Dim + tap-out on iOS; tvOS closes via Menu.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { closePanel() }
        )
        #endif
    }

    // Native buttons only: the system's focused lozenge IS the Infuse
    // white-pill look — never draw custom focus chrome around it. The
    // active tab keeps bold text once focus moves down into the card.
    private var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: Motion.fast)) { selectedTab = tab }
                } label: {
                    Text(tab.title)
                        .fontWeight(selectedTab == tab ? .bold : .regular)
                }
                .focused($focusedTab, equals: tab)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tabCard: some View {
        Group {
            switch selectedTab {
            case .info: infoCard
            case .video: videoCard
            case .audio: audioCard
            case .subtitles:
                trackCard(
                    rows: [(Self.subtitleOffID, String(localized: "Off"), !engine.subtitleTracks.contains(where: \.isSelected))]
                        + engine.subtitleTracks.map { ($0.id, $0.displayName, $0.isSelected) }
                ) { rowID in
                    if rowID == Self.subtitleOffID {
                        engine.selectSubtitleTrack(id: nil)
                    } else if let track = engine.subtitleTracks.first(where: { $0.id == rowID }) {
                        engine.selectSubtitleTrack(id: track.engineID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .foregroundStyle(.white)
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 24) {
            CachedAsyncImage(url: info.posterURL, maxPixelSize: 400) { image in
                image
                    .resizable()
                    .aspectRatio(2 / 3, contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 130, height: 195)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

            VStack(alignment: .leading, spacing: 10) {
                Text(combinedTitle)
                    .font(.headline)
                if let overview = info.overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !info.facts.isEmpty {
                    Text(info.facts.joined(separator: "    "))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var combinedTitle: String {
        if let subtitle = info.subtitle {
            return "\(info.title) – \(subtitle)"
        }
        return info.title
    }

    // Tracks column plus the Infuse-style OPTIONS column (audio delay,
    // HEL-48 M6).
    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            trackCard(rows: engine.audioTracks.map { ($0.id, $0.displayName, $0.isSelected) }) { rowID in
                if let track = engine.audioTracks.first(where: { $0.id == rowID }) {
                    engine.selectAudioTrack(id: track.engineID)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("Options")
                HStack(spacing: 14) {
                    Text("Audio Delay")
                        .font(.callout)
                    Spacer()
                    Button {
                        engine.setAudioDelay(engine.audioDelay - 0.1)
                    } label: {
                        Image(systemName: "minus")
                    }
                    Text(String(format: "%+.1f s", engine.audioDelay))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(engine.audioDelay == 0 ? .secondary : .primary)
                    Button {
                        engine.setAudioDelay(engine.audioDelay + 0.1)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Track")
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                Text(info.videoSummary ?? String(localized: "Unknown video track"))
                    .font(.callout)
            }
        }
    }

    private func trackCard(
        rows: [(id: String, name: String, selected: Bool)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Tracks")
            // The card hugs short lists; only long ones scroll.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.id) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .opacity(row.selected ? 1 : 0)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(rows.count) * 64 + 16, 340))
        }
    }

    private func cardHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
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

/// Scrub-bar geometry. Lives outside `CustomPlayerView` because the view is
/// generic over its surface, and generics can't hold static storage. The
/// pill has a fixed width so the edge clamping is exact.
private enum ScrubMetrics {
    #if os(tvOS)
    static let knobWidth: CGFloat = 8
    static let knobOverhang: CGFloat = 12
    static let pillWidth: CGFloat = 150
    static let pillHeight: CGFloat = 52
    #else
    static let knobWidth: CGFloat = 14
    static let knobOverhang: CGFloat = 6
    static let pillWidth: CGFloat = 88
    static let pillHeight: CGFloat = 34
    #endif
}
