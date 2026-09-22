import LagoonEngine
import SwiftUI

/// Only the fill redraws as time passes. The automation owns the deadline
/// and action; hiding or recreating this view cannot restart either one.
struct PlayerCountdownFill: View {
    let countdown: PlaybackCountdown?
    /// A stationary sample for the component gallery, or an idle countdown.
    var fill: Double = 0

    var body: some View {
        // The reader stays outside the timeline. Inside, it can get an
        // unspecified width, measure zero, and draw no fill.
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
