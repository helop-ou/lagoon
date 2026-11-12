#if os(iOS)
import LagoonEngine
import SwiftUI

/// The iOS centre cluster: play/pause with a ±10 s skip either side, and the
/// previous and next titles outside those when a queue has them.
///
/// Holds the engine weakly via `@PlayerEngineRef`, never strongly, so a stale
/// copy after a handoff cannot leak the drained engine. Reading `isPaused`
/// here is fine. Tick-rate state such as `timePosition` is not.
struct PlayerTouchTransportCluster: View {
    @PlayerEngineRef var engine: any PlayerEngine
    /// `true` for the forward button, `false` for back.
    var onSkip: (Bool) -> Void
    var onTogglePlayPause: () -> Void
    var episodes: PlayerEpisodeButtons? = nil
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}

    var body: some View {
        HStack(spacing: isCompact ? Metrics.Space.s : Metrics.Space.xl) {
            if let episodes {
                episodeButton(forward: false, isAvailable: episodes.hasPrevious)
            }
            skipButton(forward: false)
            playPauseButton
            skipButton(forward: true)
            if let episodes {
                episodeButton(forward: true, isAvailable: episodes.hasNext)
            }
        }
    }

    /// Five buttons fit a phone held upright only with the skips and gaps
    /// tightened.
    private var isCompact: Bool { episodes != nil }

    /// A missing side keeps its slot, so play/pause stays in the centre.
    private func episodeButton(forward: Bool, isAvailable: Bool) -> some View {
        Button {
            forward ? onNext() : onPrevious()
        } label: {
            Label(
                forward ? "Next" : "Previous",
                systemImage: forward ? "forward.end.fill" : "backward.end.fill"
            )
            .labelStyle(.iconOnly)
            .font(.title3.weight(.semibold))
            .padding(Metrics.Space.s)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .contentShape(Circle())
        .opacity(isAvailable ? 1 : 0)
        .disabled(!isAvailable)
        .accessibilityHidden(!isAvailable)
        .accessibilityIdentifier(forward ? "player.next" : "player.previous")
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
            // Inside the label, so it grows the glass circle (~60pt).
            .padding(isCompact ? Metrics.Space.s : Metrics.Space.l)
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
            // ~88pt circle, the primary target.
            .padding(Metrics.Space.xl)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
        .contentShape(Circle())
        // The regression suite looks for this identifier.
        .accessibilityIdentifier("player.playPause")
    }
}

/// Double-tap seek feedback: a repeat on the same side while the glyph is
/// up adds a step (10, 20, 30 s). A direction change resets it.
nonisolated enum TouchSeekPolicy {
    static let step: Double = 10

    static func accumulated(previous: Int?, sameDirection: Bool) -> Int {
        sameDirection ? (previous ?? 0) + Int(step) : Int(step)
    }
}
#endif
