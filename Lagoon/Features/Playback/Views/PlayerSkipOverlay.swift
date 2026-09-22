import LagoonEngine
import SwiftUI

/// Which skippable segment the playhead is inside. Shared by the overlay and
/// Select/Menu handling so they never disagree.
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

/// The Skip Intro / Recap pill. Draws `PlaybackAutomation`'s state, which
/// runs off the engine's clock so a locked phone still skips.
/// Not focusable: on tvOS Select drives it from the video surface, because
/// taking focus would move `onMoveCommand` off the surface and kill scrubbing.
struct PlayerSkipOverlay: View {
    let automation: PlaybackAutomation
    let reduceMotion: Bool
    /// A tap on the pill, handled like Select on tvOS.
    let onSkip: (MediaSegment) -> Void

    private var transientScaleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }

    var body: some View {
        let segment = automation.activeSegment
        let skipMode = automation.skipMode
        Group {
            if let segment, skipMode != .instant {
                PlayerSkipPrompt(
                    title: segment.kind.skipTitle,
                    showsCountdown: skipMode == .autoDelay,
                    countdown: automation.skipTiming
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
    }
}

/// Shared with the Debug component gallery, so the gallery shows what ships.
struct PlayerSkipPrompt: View {
    let title: String
    let showsCountdown: Bool
    var fill: Double = 0
    var countdown: PlaybackCountdown?
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
                    PlayerCountdownFill(countdown: countdown, fill: fill)
                }
            }
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

/// Fixed width, so the countdown fill needs no GeometryReader.
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
