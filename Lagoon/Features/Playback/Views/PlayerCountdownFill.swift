import LagoonEngine
import SwiftUI

/// Only the fill redraws as time passes. The automation owns the deadline
/// and action; hiding or recreating this view cannot restart either one.
struct PlayerCountdownFill: View {
    let countdown: PlaybackCountdown?
    /// A stationary sample for the component gallery, or an idle countdown.
    var fill: Double = 0

    var body: some View {
        // The reader stays *outside* the timeline. A `TimelineView` does not
        // always hand its content a definite width, and a `GeometryReader`
        // measuring an unspecified proposal reports zero: with the two nested
        // the other way round the Up Next bar drew no fill at all, because its
        // capsule is framed by height alone and takes its width from the card.
        // The skip pill hid this — its fill sits in the background of a fixed
        // frame, so the proposal was always definite there.
        GeometryReader { proxy in
            TimelineView(.animation(paused: countdown == nil)) { _ in
                Capsule()
                    .fill(.white)
                    .frame(
                        width: proxy.size.width * progress,
                        height: proxy.size.height
                    )
            }
        }
    }

    private var progress: Double {
        countdown?.progress(at: .now) ?? min(max(fill, 0), 1)
    }
}
