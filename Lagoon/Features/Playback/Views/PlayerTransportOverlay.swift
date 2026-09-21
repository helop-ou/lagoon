import SwiftUI

/// The bottom transport, lifted out of `CustomPlayerView`.
///
/// Nothing in *this* body moves at tick rate: the title block, the speed
/// readout, the pause glyph and the gradient all read state that changes when
/// the viewer does something. The two things that do follow the playhead —
/// the rail and the timestamps — are separate child views below, so a
/// position tick repaints them and leaves the rest of the transport, and the
/// player above it, alone.
struct PlayerTransportOverlay: View {
    @PlayerEngineRef var engine: any PlayerEngine
    let info: PlayerItemInfo
    /// Whether the transport is actually on screen. `CustomPlayerView` keeps
    /// this view mounted at `.opacity(0)` so the fade can animate, so the
    /// tick-following leaves below need their own signal to stop following
    /// the playhead while nobody can see it.
    let isVisible: Bool
    /// The virtual playhead's position while scrubbing; nil when the
    /// transport is live(slice 2).
    let scrubTarget: Double?
    /// Swaps the remaining time for the clock time the item will finish at.
    let showsEndTime: Bool
    /// The subtitle error already supplies guidance in this space, and Down
    /// is also unavailable while scrubbing.
    let showsPanelHint: Bool
    let bufferedFraction: Double?
    let bufferedRanges: [PlaybackBufferedRange]
    let trickplay: TrickplayLoader?
    var onScrubPreview: (Double) -> Void = { _ in }
    var onCommitScrub: (Double, Bool) -> Void = { _, _ in }
    var onCancelScrub: () -> Void = {}
    var onPoke: () -> Void = {}

    private var isScrubbing: Bool { scrubTarget != nil }

    var body: some View {
        VStack {
            #if os(tvOS)
            if showsPanelHint {
                VStack(spacing: Metrics.Space.hair) {
                    Text("Swipe down for Info")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.compact.down")
                        .font(.title3.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, Metrics.railTopPadding)
            }
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
                    if engine.rate != 1 {
                        Text(PlaybackRatePolicy.title(engine.rate))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("player.playbackRate.value")
                    }
                    if engine.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                // Scrubbing hands this space to the trickplay frame.
                .opacity(isScrubbing ? 0 : 1)
                .animation(.easeInOut(duration: Motion.fast), value: isScrubbing)
                .allowsHitTesting(false)

                PlayerScrubber(
                    engine: engine,
                    isVisible: isVisible,
                    chapters: info.chapters,
                    trickplaySource: info.trickplay,
                    scrubTarget: scrubTarget,
                    bufferedFraction: bufferedFraction,
                    bufferedRanges: bufferedRanges,
                    trickplay: trickplay,
                    onScrubPreview: onScrubPreview,
                    onCommitScrub: onCommitScrub,
                    onCancelScrub: onCancelScrub,
                    onPoke: onPoke
                )

                PlayerTimelineLabels(
                    engine: engine,
                    isVisible: isVisible,
                    scrubTarget: scrubTarget,
                    showsEndTime: showsEndTime
                )
            }
            .padding(Metrics.screenGutter)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.22), location: 0.34),
                        .init(color: .black.opacity(0.76), location: 1),
                    ],
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
}

/// Infuse/AVKit-style flat rail: played and buffered ranges stay inside
/// the line, while a slim vertical marker appears only during scrubbing.
///
/// One of the two views in the player that legitimately follows the playhead
/// at tick rate, which is exactly why it is its own view.
struct PlayerScrubber: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// See `PlayerTransportOverlay.isVisible`.
    let isVisible: Bool
    let chapters: [PlayerChapter]
    let trickplaySource: TrickplaySource?
    let scrubTarget: Double?
    let bufferedFraction: Double?
    let bufferedRanges: [PlaybackBufferedRange]
    let trickplay: TrickplayLoader?
    var onScrubPreview: (Double) -> Void = { _ in }
    var onCommitScrub: (Double, Bool) -> Void = { _, _ in }
    var onCancelScrub: () -> Void = {}
    var onPoke: () -> Void = {}

    /// The last position shown while the transport was visible. Rendered
    /// in place of `engine.timePosition` while hidden so the un-taken
    /// `isVisible` branch below never reads it — Observation only
    /// registers reads that actually happen, so that is what drops the
    /// hidden transport's subscription to the tick.
    @State private var lastShownSeconds: Double = 0

    private var isScrubbing: Bool { scrubTarget != nil }

    /// The position this view renders. Only the `isVisible` branch touches
    /// the engine; the hidden branch reads state that never changes on its
    /// own, so nothing here ticks while the transport is faded out.
    private var seconds: Double {
        isVisible ? (scrubTarget ?? engine.timePosition) : lastShownSeconds
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                if !bufferedRanges.isEmpty {
                    ForEach(bufferedRanges, id: \.self) { range in
                        let lower = CGFloat(min(max(range.lowerFraction, 0), 1))
                        let upper = CGFloat(min(max(range.upperFraction, 0), 1))
                        Capsule()
                            .fill(.white.opacity(0.42))
                            .frame(width: max(width * (upper - lower), 1))
                            .offset(x: width * lower)
                    }
                    .animation(liveMotion, value: bufferedRanges)
                } else if let bufferedFraction, bufferedFraction > 0 {
                    Capsule()
                        .fill(.white.opacity(0.42))
                        .frame(width: width * CGFloat(min(max(bufferedFraction, 0), 1)))
                        .animation(liveMotion, value: bufferedFraction)
                }
                UnevenRoundedRectangle(
                    topLeadingRadius: Metrics.scrubberHeight / 2,
                    bottomLeadingRadius: Metrics.scrubberHeight / 2
                )
                    .fill(.white)
                    .frame(width: max(width * fillFraction, Metrics.scrubberHeight))
                    // Glides between the engine's 0.1 s position updates
                    // instead of ticking; big deltas (seeks)
                    // become a quick slide to the target.
                    .animation(fillMotion, value: fillFraction)
                chapterTicks(in: width)
            }
            // The marker is deliberately an overlay. As a ZStack child its
            // 28 pt height enlarged the supposedly 6 pt rail and pushed it
            // into the timestamp row even while the marker was invisible.
            .frame(width: width, height: Metrics.scrubberHeight)
            .overlay(alignment: .leading) { playheadMarker(in: width) }
            .overlay(alignment: .bottomLeading) { scrubPreview(in: width) }
            #if os(iOS)
            // The visible rail is deliberately quiet; its touch target is not.
            .contentShape(Rectangle().inset(by: -18))
            .gesture(scrubDrag(in: width))
            #endif
        }
        .frame(height: Metrics.scrubberHeight)
        // Tracks the live position into `lastShownSeconds` while visible,
        // so the instant the transport hides again it freezes on the frame
        // the viewer last saw rather than snapping to 0.
        .onChange(of: seconds) { _, newValue in
            if isVisible { lastShownSeconds = newValue }
        }
        #if os(iOS)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(PlaybackTimestamp.text(seconds)) of \(PlaybackTimestamp.text(engine.duration))")
        .accessibilityAdjustableAction { direction in
            guard engine.duration.isFinite, engine.duration > 0 else { return }
            let delta: Double
            switch direction {
            case .increment: delta = 10
            case .decrement: delta = -10
            @unknown default: return
            }
            onCommitScrub(min(max(engine.timePosition + delta, 0), engine.duration), false)
            onPoke()
        }
        .accessibilityIdentifier("player.seek")
        #endif
    }

    @ViewBuilder
    private func playheadMarker(in width: CGFloat) -> some View {
        Capsule()
            .fill(.white)
            .shadow(color: .black.opacity(0.45), radius: 3)
            .frame(width: ScrubMetrics.markerWidth, height: ScrubMetrics.markerHeight)
            .offset(
                x: min(
                    max(width * knobFraction - ScrubMetrics.markerWidth / 2, 0),
                    max(width - ScrubMetrics.markerWidth, 0)
                )
            )
            .opacity(isScrubbing ? 1 : 0)
            .animation(scrubMotion, value: knobFraction)
            .animation(.easeOut(duration: Motion.fast), value: isScrubbing)
    }

    /// Chapter boundaries, drawn over the fill so they read on both halves
    /// of the bar. Nothing at 0:00 — a tick under the playhead is noise.
    @ViewBuilder
    private func chapterTicks(in width: CGFloat) -> some View {
        if engine.duration > 0 {
            ForEach(chapters.filter { $0.start > 1 && $0.start < engine.duration }) { chapter in
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: width * CGFloat(chapter.start / engine.duration))
            }
        }
    }

    /// Trickplay remains above the rail. The timestamp itself belongs below
    /// the marker, rendered by `PlayerTimelineLabels`, just like AVKit and
    /// Infuse.
    @ViewBuilder
    private func scrubPreview(in width: CGFloat) -> some View {
        Group {
            if scrubTarget != nil, previewSize != nil || scrubChapter?.name != nil {
                VStack(spacing: Metrics.Space.s) {
                    trickplayFrame
                    if let name = scrubChapter?.name {
                        Text(name)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .shadow(color: .black, radius: 3)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: chipWidth)
                .offset(
                    x: min(max(width * knobFraction - chipWidth / 2, 0), max(width - chipWidth, 0)),
                    y: -(Metrics.scrubberHeight + Metrics.Space.m)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                .animation(scrubMotion, value: knobFraction)
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

    /// The chapter the scrub playhead is sitting in, for the chip's caption.
    private var scrubChapter: PlayerChapter? {
        guard let target = scrubTarget else { return nil }
        return chapters.last { $0.start <= target }
    }

    /// Preview size at the chip's width, in the tiles' own aspect ratio (not
    /// every library is 16:9).
    private var previewSize: CGSize? {
        guard trickplay?.isUnavailable != true,
              let source = trickplaySource, source.tileSize.width > 0, source.tileSize.height > 0 else { return nil }
        let width = ScrubMetrics.previewWidth
        return CGSize(width: width, height: (width * source.tileSize.height / source.tileSize.width).rounded())
    }

    private var chipWidth: CGFloat {
        max(previewSize?.width ?? 0, ScrubMetrics.previewWidth)
    }

    /// Where the playhead knob sits: the virtual position while scrubbing,
    /// the engine's otherwise. Both read `seconds`, never the engine
    /// directly, so they freeze along with it while hidden.
    private var knobFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    private var progressFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    /// The played rail follows the preview target while scrubbing. Cancel
    /// still returns to the live engine position, but the visual stays joined
    /// to its marker in the native transport style.
    private var fillFraction: CGFloat {
        isScrubbing ? knobFraction : progressFraction
    }

    /// The live playhead's curve, matched to the engine's position-update
    /// cadence so the bar glides instead of ticking.
    private var liveMotion: Animation { .linear(duration: 0.25) }

    /// Scrub steps snap over; while live the knob must glide on exactly the
    /// fill's curve, or the two drift apart between position updates.
    private var scrubMotion: Animation {
        isScrubbing ? .easeOut(duration: Motion.fast) : liveMotion
    }

    /// Keep the played edge and vertical marker on the same curve; otherwise
    /// they visibly separate during quick remote presses.
    private var fillMotion: Animation {
        isScrubbing ? scrubMotion : liveMotion
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
                onScrubPreview(seconds)
            }
            .onEnded { value in
                guard let seconds = scrubSeconds(at: value.location.x, in: width) else {
                    onCancelScrub()
                    return
                }
                onCommitScrub(seconds, false)
            }
    }

    private func scrubSeconds(at x: CGFloat, in width: CGFloat) -> Double? {
        guard width > 0, engine.duration > 0 else { return nil }
        return Double(min(max(x / width, 0), 1)) * engine.duration
    }
    #endif
}

/// The elapsed/target label follows the end of the played rail. The
/// remaining time stays pinned to the trailing edge unless the two would
/// overlap near the end of an item.
///
/// The player's second legitimate tick-rate leaf.
struct PlayerTimelineLabels: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// See `PlayerTransportOverlay.isVisible`.
    let isVisible: Bool
    let scrubTarget: Double?
    let showsEndTime: Bool

    /// See `PlayerScrubber.lastShownSeconds` — same freeze, same reason.
    @State private var lastShownSeconds: Double = 0

    private var isScrubbing: Bool { scrubTarget != nil }

    /// Only the `isVisible` branch touches the engine.
    private var seconds: Double {
        isVisible ? (scrubTarget ?? engine.timePosition) : lastShownSeconds
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = isScrubbing ? knobFraction : progressFraction
            let labelWidth = ScrubMetrics.timeLabelWidth
            let center = min(
                max(width * fraction, labelWidth / 2),
                max(width - labelWidth / 2, labelWidth / 2)
            )
            let remainingStartsAt = width - labelWidth
            let elapsedEndsAt = center + labelWidth / 2

            ZStack(alignment: .topLeading) {
                Text(PlaybackTimestamp.text(seconds))
                    .font(
                        isScrubbing
                            ? .callout.monospacedDigit().weight(.semibold)
                            : .callout.monospacedDigit().weight(.medium)
                    )
                    .frame(width: labelWidth)
                    .offset(x: center - labelWidth / 2)
                    .animation(scrubMotion, value: fraction)
                    .accessibilityIdentifier(isScrubbing ? "player.scrub.chip" : "player.elapsed")

                if !isScrubbing {
                    trailingTimeLabel
                        .font(.callout.monospacedDigit().weight(.medium))
                        .frame(width: labelWidth, alignment: .trailing)
                        .offset(x: max(width - labelWidth, 0))
                        .opacity(elapsedEndsAt + Metrics.Space.s < remainingStartsAt ? 1 : 0)
                }
            }
            .foregroundStyle(.white.opacity(isScrubbing ? 1 : 0.82))
        }
        .frame(height: ScrubMetrics.timeLabelHeight)
        .animation(.easeInOut(duration: Motion.fast), value: isScrubbing)
        .onChange(of: seconds) { _, newValue in
            if isVisible { lastShownSeconds = newValue }
        }
        .allowsHitTesting(false)
    }

    /// Either the time left, or the clock time the item finishes at. The
    /// projection is redrawn once a second on its own schedule rather than
    /// with the playhead, because the whole point is that it keeps moving
    /// while playback is paused and the playhead is not.
    @ViewBuilder
    private var trailingTimeLabel: some View {
        let remaining = max(engine.duration - seconds, 0)
        if showsEndTime {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let finish = PlaybackFinish.date(
                    from: context.date,
                    remaining: remaining,
                    rate: engine.rate
                ) {
                    Text(PlaybackFinish.label(finish))
                        .accessibilityIdentifier("player.endsAt")
                        .accessibilityLabel("Ends at \(PlaybackFinish.label(finish))")
                } else {
                    // No usable duration, as on a live stream: there is no
                    // finish to project, so the time left stands.
                    Text("-" + PlaybackTimestamp.text(remaining))
                        .accessibilityIdentifier("player.remaining")
                }
            }
        } else {
            Text("-" + PlaybackTimestamp.text(remaining))
                .accessibilityIdentifier("player.remaining")
        }
    }

    private var knobFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    private var progressFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    private var scrubMotion: Animation {
        isScrubbing ? .easeOut(duration: Motion.fast) : .linear(duration: 0.25)
    }
}

/// How the transport writes a media position.
nonisolated enum PlaybackTimestamp {
    static func text(_ seconds: Double) -> String {
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
/// time label has a fixed width so the edge clamping is exact.
enum ScrubMetrics {
    /// No input for this long and the acceleration run expires, so the next
    /// press is a 10 s step again rather than a 60 s one.
    static let runExpiry: Duration = .milliseconds(600)
    /// A further beat after that and the scrub lands itself. This is what
    /// keeps a single press a plain 10 s skip now that scrub opens during
    /// playback — tune it on hardware, not in the simulator: too
    /// short and a preview can't be read, too long and a nudge feels stuck.
    static let selfCommit: Duration = .milliseconds(600)
    /// A chapter hop waits longer than a step before landing. Found on
    /// hardware: a hop is a *survey* gesture — you are
    /// reading where chapter 13 starts — where an arrow step is a nudge, and
    /// sharing the step's window turned browsing past the next chapter into
    /// a race against the timer.
    static let chapterSelfCommit: Duration = .milliseconds(2000)

    #if os(tvOS)
    static let markerWidth: CGFloat = 3
    static let markerHeight: CGFloat = 22
    static let timeLabelWidth: CGFloat = 150
    static let timeLabelHeight: CGFloat = 36
    /// Smaller than the source tile on purpose: a 320 pt frame dominates a
    /// ten-foot UI even though the underlying Jellyfin image is 320 px.
    static let previewWidth: CGFloat = 240
    #else
    static let markerWidth: CGFloat = 3
    static let markerHeight: CGFloat = 20
    static let timeLabelWidth: CGFloat = 96
    static let timeLabelHeight: CGFloat = 30
    static let previewWidth: CGFloat = 160
    #endif
}
