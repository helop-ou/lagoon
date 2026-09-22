import LagoonEngine
import SwiftUI

/// The bottom transport. No tick-rate reads in this body: only the rail and
/// the timestamps follow the playhead, each in its own child view.
struct PlayerTransportOverlay: View {
    @PlayerEngineRef var engine: any PlayerEngine
    let info: PlayerItemInfo
    /// The view stays mounted at zero opacity; this tells the tick-rate
    /// leaves to stop following the playhead while hidden.
    let isVisible: Bool
    /// The virtual playhead while scrubbing; nil otherwise.
    let scrubTarget: Double?
    /// Swaps the remaining time for the clock time the item will finish at.
    let showsEndTime: Bool
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
                // Taps here belong to the surface; only the iOS bar takes
                // touch.
                .allowsHitTesting(false)
            )
        }
        .foregroundStyle(.white)
    }
}

/// Flat rail with played and buffered ranges; a marker shows while
/// scrubbing. One of the two tick-rate leaves, so keep it a separate view.
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

    /// Shown while hidden, so the engine's position is never read and
    /// Observation drops the tick subscription.
    @State private var lastShownSeconds: Double = 0

    private var isScrubbing: Bool { scrubTarget != nil }

    /// Only the `isVisible` branch may read the engine.
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
                    // Glides between the engine's 0.1 s position updates.
                    .animation(fillMotion, value: fillFraction)
                chapterTicks(in: width)
            }
            // The marker is an overlay: as a ZStack child its height grew
            // the rail into the timestamp row.
            .frame(width: width, height: Metrics.scrubberHeight)
            .overlay(alignment: .leading) { playheadMarker(in: width) }
            .overlay(alignment: .bottomLeading) { scrubPreview(in: width) }
            #if os(iOS)
            .contentShape(Rectangle().inset(by: -18))
            .gesture(scrubDrag(in: width))
            #endif
        }
        .frame(height: Metrics.scrubberHeight)
        // So hiding freezes on the last position rather than 0.
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

    /// Drawn over the fill so they read on both halves. None at 0:00.
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

    /// Trickplay above the rail; the timestamp is in `PlayerTimelineLabels`.
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

    /// Reserves the frame while the sheet downloads so the chip doesn't
    /// resize.
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

    private var scrubChapter: PlayerChapter? {
        guard let target = scrubTarget else { return nil }
        return chapters.last { $0.start <= target }
    }

    /// In the tiles' own aspect ratio; not every library is 16:9.
    private var previewSize: CGSize? {
        guard trickplay?.isUnavailable != true,
              let source = trickplaySource, source.tileSize.width > 0, source.tileSize.height > 0 else { return nil }
        let width = ScrubMetrics.previewWidth
        return CGSize(width: width, height: (width * source.tileSize.height / source.tileSize.width).rounded())
    }

    private var chipWidth: CGFloat {
        max(previewSize?.width ?? 0, ScrubMetrics.previewWidth)
    }

    /// Reads `seconds`, never the engine, so it freezes while hidden.
    private var knobFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    private var progressFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / engine.duration, 0), 1))
    }

    private var fillFraction: CGFloat {
        isScrubbing ? knobFraction : progressFraction
    }

    /// Matched to the engine's position-update cadence.
    private var liveMotion: Animation { .linear(duration: 0.25) }

    /// Knob and fill must share a curve, or they drift apart.
    private var scrubMotion: Animation {
        isScrubbing ? .easeOut(duration: Motion.fast) : liveMotion
    }

    private var fillMotion: Animation {
        isScrubbing ? scrubMotion : liveMotion
    }

    #if os(iOS)
    /// Only the release seeks: each intermediate seek would flush the
    /// engine's queues. Never changes the play state.
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

/// Elapsed time follows the rail; remaining time is pinned trailing and
/// hides on overlap. The second tick-rate leaf.
struct PlayerTimelineLabels: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// See `PlayerTransportOverlay.isVisible`.
    let isVisible: Bool
    let scrubTarget: Double?
    let showsEndTime: Bool

    /// See `PlayerScrubber.lastShownSeconds`.
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

    /// The end time redraws each second, not with the playhead, because it
    /// keeps moving while paused.
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

/// Outside `CustomPlayerView` because a generic type can't hold static
/// storage. Fixed label width keeps edge clamping exact.
enum ScrubMetrics {
    /// Quiet time before the acceleration run resets to 10 s steps.
    static let runExpiry: Duration = .milliseconds(600)
    /// Then the scrub commits itself. Tune on hardware, not the simulator.
    static let selfCommit: Duration = .milliseconds(600)
    /// Longer than a step: a viewer hopping chapters is reading, not nudging.
    static let chapterSelfCommit: Duration = .milliseconds(2000)

    #if os(tvOS)
    static let markerWidth: CGFloat = 3
    static let markerHeight: CGFloat = 22
    static let timeLabelWidth: CGFloat = 150
    static let timeLabelHeight: CGFloat = 36
    /// Smaller than the 320 px tile on purpose; 320 pt dominates the TV.
    static let previewWidth: CGFloat = 240
    #else
    static let markerWidth: CGFloat = 3
    static let markerHeight: CGFloat = 20
    static let timeLabelWidth: CGFloat = 96
    static let timeLabelHeight: CGFloat = 30
    static let previewWidth: CGFloat = 160
    #endif
}
