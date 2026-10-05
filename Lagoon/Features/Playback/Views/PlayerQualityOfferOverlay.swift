import SwiftUI

/// The lower-quality offer after repeated stalls. Shares the corner with the
/// skip pill and the Up Next card and yields to both. Not focusable on tvOS,
/// for the same reason as they are: Select and Back reach it from the
/// surface, which keeps `onMoveCommand` for scrubbing.
struct PlayerQualityOfferOverlay: View {
    let offer: PlaybackQualityOffer
    /// The panel is open, a scrub is in progress, or another prompt is up.
    let isSuppressed: Bool
    let reduceMotion: Bool

    var body: some View {
        let isVisible = offer.isVisible && !isSuppressed
        Group {
            if isVisible {
                PlayerQualityOfferCard(
                    onAccept: { offer.accept() },
                    onDismiss: { offer.dismiss() }
                )
                .playerCornerPrompt(reduceMotion: reduceMotion)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: isVisible)
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }
}

struct PlayerQualityOfferCard: View {
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("Playback Keeps Pausing")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Text("Switch to a lower quality to keep watching without interruptions.")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            #if os(tvOS)
            Text("Select to switch · Back to keep this quality")
                .font(.caption2)
                .foregroundStyle(.secondary)
            #else
            HStack(spacing: Metrics.Space.s) {
                Button("Lower Quality", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("player.qualityOffer.accept")
                Button("Keep", action: onDismiss)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("player.qualityOffer.dismiss")
            }
            .controlSize(.small)
            #endif
        }
        .padding(Metrics.Space.l)
        .frame(width: QualityOfferMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .playerCornerPromptShadow()
        .accessibilityIdentifier("player.qualityOffer")
    }
}

private nonisolated enum QualityOfferMetrics {
    #if os(tvOS)
    static let width: CGFloat = 520
    #else
    static let width: CGFloat = 300
    #endif
}
