import SwiftUI

/// Which skippable segment the playhead is inside. One implementation,
/// because the overlay draws from it and the player's Select/Menu handling
/// acts on it, and the two disagreeing would be a trap rather than a glitch.
nonisolated enum SkipSegmentPolicy {
    static func activeSegment(
        in segments: [MediaSegment],
        at position: Double,
        handled: Set<String>
    ) -> MediaSegment? {
        segments.first {
            $0.kind.isSkippable
                && !handled.contains($0.id)
                && $0.contains(position)
        }
    }
}

/// The Skip Intro / Skip Recap shelf (HEL-63), lifted out of
/// `CustomPlayerView` (HEL-150) so `engine.timePosition` is read in this body
/// instead of the player's.
///
/// The auto-skip fill and the task that arms it came with it: the fill is
/// this view's own state, and the parent only hears about a committed skip,
/// through `onSkip`. Bottom-trailing, clear of the transport — the shelf the
/// reference players use. Not focusable; on tvOS Select drives it from the
/// video surface, because taking focus would move `onMoveCommand` off the
/// surface and kill scrubbing while it is up.
struct PlayerSkipOverlay: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// Changing it re-arms the task, which is what clears a fill left running
    /// by the item that just ended.
    let playbackIdentity: String
    let segments: [MediaSegment]
    /// Segments already acted on or waved away, so a committed skip (or a
    /// "no thanks") doesn't re-arm the moment the playhead lands.
    let handledSegmentIDs: Set<String>
    /// The panel and an open scrub both own the screen and the remote, and a
    /// button that quietly rewrites what Select does underneath them would be
    /// a trap.
    let isSuppressed: Bool
    let skipMode: SkipMode
    let reduceMotion: Bool
    let onSkip: (MediaSegment) -> Void

    /// 0…1, drives the auto-skip fill. Value-driven, because `withAnimation`
    /// does not survive the MenuPressGate hosting boundary.
    @State private var autoSkipFill: Double = 0

    /// Re-arms the countdown once per segment — and once per item, so
    /// autoplay cannot inherit the outgoing episode's fill.
    private struct Arming: Equatable {
        let identity: String
        let segmentID: String?
    }

    private var activeSegment: MediaSegment? {
        // Reading `engine.timePosition` is what subscribes this view to the
        // position tick, so an item the server marked no skippable segment on
        // — every movie without an intro — never takes the subscription at
        // all. The answer is nil either way.
        guard !isSuppressed, segments.contains(where: \.kind.isSkippable) else { return nil }
        return SkipSegmentPolicy.activeSegment(
            in: segments,
            at: engine.timePosition,
            handled: handledSegmentIDs
        )
    }

    private var transientScaleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }

    var body: some View {
        let segment = activeSegment
        Group {
            if let segment, skipMode != .instant {
                PlayerSkipPrompt(
                    title: segment.kind.skipTitle,
                    showsCountdown: skipMode == .autoDelay,
                    fill: autoSkipFill
                )
                .transition(transientScaleTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, Metrics.screenGutter)
                .padding(.bottom, SkipMetrics.bottomInset)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: segment?.id)
        #if os(tvOS)
        .allowsHitTesting(false)
        #else
        .onTapGesture {
            if let segment, skipMode != .instant {
                onSkip(segment)
            }
        }
        .accessibilityAddTraits(.isButton)
        #endif
        // Arms whenever the playhead crosses into a skippable segment. Keyed
        // on the segment id, so it fires once per segment rather than on
        // every position tick.
        .task(id: Arming(identity: playbackIdentity, segmentID: segment?.id)) {
            guard let segment else {
                autoSkipFill = 0
                return
            }
            switch skipMode {
            case .instant:
                onSkip(segment)
            case .autoDelay:
                autoSkipFill = 1
                try? await Task.sleep(for: .seconds(SkipMode.autoDelaySeconds))
                // Menu may have waved it away, or a scrub may have carried
                // the playhead out, while the fill was running.
                guard !Task.isCancelled, activeSegment?.id == segment.id else { return }
                onSkip(segment)
            case .button:
                break
            }
        }
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
