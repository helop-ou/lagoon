import SwiftUI

struct PlayerSeekIndicator: View {
    let forward: Bool
    /// Stacked iOS double-tap total; tvOS stays at 10.
    var seconds: Int = 10
    var accessibilityIdentifier = "player.seekFeedback"

    var body: some View {
        VStack(spacing: Metrics.Space.xs) {
            HStack {
                if forward { Spacer() }
                Image(systemName: forward ? "goforward.10" : "gobackward.10")
                    .font(Typography.glyph.weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 6)
                if !forward { Spacer() }
            }
            if seconds > 10 {
                HStack {
                    if forward { Spacer() }
                    Text("\(seconds) s")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                    if !forward { Spacer() }
                }
            }
        }
        .padding(.horizontal, Metrics.screenGutter * 2)
        .allowsHitTesting(false)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
