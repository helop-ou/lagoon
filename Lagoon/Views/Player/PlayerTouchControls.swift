#if os(iOS)
import SwiftUI

/// The iOS touch grammar's centre cluster (HEL-153): a large play/pause with
/// a ±10 s skip either side, the same three-button row every phone player
/// puts under the thumb. tvOS keeps its own remote grammar in
/// `CustomPlayerView` untouched — this view exists only on iOS.
///
/// Holds the engine the same way every other player view does: weak, via
/// `@PlayerEngineRef`, so a stale copy of this cluster kept alive by a
/// SwiftUI gesture context after an episode handoff reads
/// `DetachedPlayerEngine` instead of leaking the drained one (HEL-152). The
/// closures below read `engine.isPaused` from the body, which is fine — it
/// changes on viewer action, not at tick rate (HEL-150 only rules out
/// `timePosition`, the subtitle cue properties, and other per-tick state).
struct PlayerTouchTransportCluster: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// `true` for the forward button, `false` for back.
    var onSkip: (Bool) -> Void
    var onTogglePlayPause: () -> Void

    var body: some View {
        HStack(spacing: Metrics.Space.xl) {
            skipButton(forward: false)
            playPauseButton
            skipButton(forward: true)
        }
    }

    private func skipButton(forward: Bool) -> some View {
        Button {
            onSkip(forward)
        } label: {
            Label(
                forward ? "Forward 10 seconds" : "Back 10 seconds",
                systemImage: forward ? "goforward.10" : "gobackward.10"
            )
            .labelStyle(.iconOnly)
            .font(.title.weight(.semibold))
            // Padding lives inside the label, not outside the button, so it
            // grows the glass shape the style draws rather than just adding
            // dead space around an unchanged one — roughly a 60pt circle.
            .padding(Metrics.Space.l)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .contentShape(Circle())
        .accessibilityIdentifier(forward ? "player.skipForward" : "player.skipBack")
    }

    private var playPauseButton: some View {
        Button {
            onTogglePlayPause()
        } label: {
            Label(
                engine.isPaused ? "Play" : "Pause",
                systemImage: engine.isPaused ? "play.fill" : "pause.fill"
            )
            .labelStyle(.iconOnly)
            .font(Typography.glyph)
            // Roughly an 88pt circle — generous enough to be the obvious
            // primary target beside the two 60pt skip buttons either side.
            .padding(Metrics.Space.xl)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .contentShape(Circle())
        // Moved here from the toolbar (HEL-153): the centre cluster is now
        // the one play/pause control on iOS, so it keeps the identifier the
        // regression suite already looks for.
        .accessibilityIdentifier("player.playPause")
    }
}

/// Pure policy behind the iOS double-tap seek's stacking feedback (HEL-153):
/// a further double-tap on the same side, while the glyph from the last one
/// is still up, adds another step instead of resetting it, so three quick
/// double-taps forward reads "30 s" rather than restarting at 10 s each time.
/// `nonisolated` so a unit test can call it directly, with no view or engine
/// in the way.
nonisolated enum TouchSeekPolicy {
    static let step: Double = 10

    static func accumulated(previous: Int?, sameDirection: Bool) -> Int {
        sameDirection ? (previous ?? 0) + Int(step) : Int(step)
    }
}
#endif
