import LagoonEngine
import SwiftUI

/// Which skippable segment the playhead is inside. Shared by the overlay and
/// Select/Menu handling so they never disagree.
///
/// Intros and recaps always skip. An outro skips only when a scene follows
/// it; credits that run to the end hand off to Up Next instead.
nonisolated enum SkipSegmentPolicy {
    /// Less content than this after the credits is a run-out, not a scene.
    /// Matches Up Next's run-out, so the card never shares the corner with
    /// the pill.
    static let minimumSceneAfterCredits = NextUpPolicy.fallbackLeadIn

    static func activeSegment(
        in segments: [MediaSegment],
        at position: Double,
        handled: Set<String>,
        duration: Double
    ) -> MediaSegment? {
        segments.first {
            isSkippable($0, in: segments, duration: duration)
                && !handled.contains($0.id)
                && $0.contains(position)
        }
    }

    static func isSkippable(_ segment: MediaSegment, in segments: [MediaSegment], duration: Double) -> Bool {
        if segment.kind.isSkippable { return true }
        guard segment.kind == .outro, duration > 0 else { return false }
        return duration - creditsEnd(segment, in: segments) > minimumSceneAfterCredits
    }

    /// The outro Up Next starts at: one that runs to the end of the file.
    /// Nil until the duration is known.
    static func endingCredits(in segments: [MediaSegment], duration: Double) -> MediaSegment? {
        guard duration > 0 else { return nil }
        return segments.first { $0.kind == .outro && !isSkippable($0, in: segments, duration: duration) }
    }

    static func title(for segment: MediaSegment) -> String {
        segment.kind == .outro ? String(localized: "Skip Credits") : segment.kind.skipTitle
    }

    /// A next-episode preview straight after the credits is more credits, not
    /// a scene worth landing on.
    private static func creditsEnd(_ outro: MediaSegment, in segments: [MediaSegment]) -> Double {
        var end = outro.end
        for preview in segments.filter({ $0.kind == .preview }).sorted(by: { $0.start < $1.start })
        where preview.start >= outro.start && preview.start <= end + minimumSceneAfterCredits {
            end = max(end, preview.end)
        }
        return end
    }
}

/// The Skip Intro / Recap / Credits pill. Draws `PlaybackAutomation`'s
/// state, which runs off the engine's clock so a locked phone still skips.
/// Not focusable: on tvOS Select drives it from the video surface, because
/// taking focus would move `onMoveCommand` off the surface and kill scrubbing.
struct PlayerSkipOverlay: View {
    let automation: PlaybackAutomation
    let reduceMotion: Bool
    /// A tap on the pill, handled like Select on tvOS.
    let onSkip: (MediaSegment) -> Void

    var body: some View {
        let segment = automation.activeSegment
        let skipMode = automation.skipMode
        Group {
            if let segment, skipMode != .instant {
                PlayerSkipPrompt(
                    title: SkipSegmentPolicy.title(for: segment),
                    showsCountdown: skipMode == .autoDelay,
                    countdown: automation.skipTiming
                )
                .playerCornerPrompt(reduceMotion: reduceMotion)
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
        .playerCornerPromptShadow()
    }
}

/// Fixed width, so the countdown fill needs no GeometryReader.
private enum SkipMetrics {
    #if os(tvOS)
    static let width: CGFloat = 260
    static let height: CGFloat = 56
    #else
    static let width: CGFloat = 170
    static let height: CGFloat = 40
    #endif
}
