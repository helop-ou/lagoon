import LagoonEngine
import SwiftUI

/// When the Up Next card and its countdown are due. Pure, so the player,
/// the card and the regression probe agree.
nonisolated enum NextUpPolicy {
    /// At the outro, or else a short fixed run-out, so the card never
    /// covers the closing scene.
    static func cardStart(
        hasEpisode: Bool,
        autoplayMode: AutoplayMode,
        duration: Double,
        outroStart: Double?
    ) -> Double? {
        guard hasEpisode, autoplayMode != .off, duration > 0 else { return nil }
        if let outroStart { return outroStart }
        return duration - NextUpMetrics.fallbackLeadIn
    }

    /// With an outro the countdown runs from the credits' first frame.
    /// Without one it is pinned to the file's last seconds, so autoplay
    /// never cuts into content.
    static func countdownStart(
        cardStart: Double?,
        outroStart: Double?,
        duration: Double
    ) -> Double? {
        guard let cardStart else { return nil }
        if outroStart != nil { return cardStart }
        return max(cardStart, duration - AutoplayMode.countdownSeconds)
    }

    /// Where the card returns after "not yet": the file's last seconds, so
    /// its countdown runs out as the episode does.
    static func finalCountdownStart(duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        return max(duration - AutoplayMode.countdownSeconds, 0)
    }
}

/// Draws `PlaybackAutomation`'s state, which runs off the engine's clock so
/// a locked phone still rolls into the next episode. Shares the corner with
/// the skip pill; the two are never up together.
struct PlayerNextUpOverlay: View {
    let automation: PlaybackAutomation
    /// Nil for movies, at a series end, and until the lookup lands.
    let episode: NextUpEpisode?
    let reduceMotion: Bool
    let hint: LocalizedStringKey

    private var transientScaleTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9))
    }

    var body: some View {
        let isCardVisible = automation.showsNextUp
        Group {
            if isCardVisible, let episode {
                PlayerNextUpCard(
                    episode: episode,
                    showsCountdown: automation.autoplayMode == .autoDelay,
                    countdown: automation.nextUpTiming,
                    hint: hint
                )
                .transition(transientScaleTransition)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, Metrics.screenGutter)
                .padding(.bottom, NextUpMetrics.bottomInset)
                #if !os(tvOS)
                // Touch has no Select, so the card takes the tap itself.
                .onTapGesture { automation.playNext() }
                #endif
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: isCardVisible)
        // tvOS drives this from the surface's Select. A focusable card
        // would take `onMoveCommand` off the surface and kill scrubbing.
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }
}

struct PlayerNextUpCard: View {
    let episode: NextUpEpisode
    let showsCountdown: Bool
    var fill: Double = 0
    var countdown: PlaybackCountdown?
    let hint: LocalizedStringKey
    var accessibilityIdentifier = "player.nextUp"

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("Up Next")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            HStack(spacing: Metrics.Space.m) {
                CachedAsyncImage(
                    url: episode.imageURL,
                    maxPixelSize: Int(NextUpMetrics.thumbnailWidth * 2)
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(
                    width: NextUpMetrics.thumbnailWidth,
                    height: (NextUpMetrics.thumbnailWidth * 9 / 16).rounded()
                )
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

                VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                    if let subtitle = episode.subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            if showsCountdown {
                Capsule()
                    .fill(.white.opacity(0.25))
                    .frame(height: NextUpMetrics.barHeight)
                    .overlay(alignment: .leading) {
                        PlayerCountdownFill(countdown: countdown, fill: fill)
                    }
                    .frame(height: NextUpMetrics.barHeight)
            }

            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Metrics.Space.l)
        .frame(width: NextUpMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private nonisolated enum NextUpMetrics {
    #if os(tvOS)
    static let width: CGFloat = 520
    static let thumbnailWidth: CGFloat = 150
    /// Clears the transport so the two never overlap, same as `SkipMetrics`.
    static let bottomInset: CGFloat = 240
    static let barHeight: CGFloat = 6
    #else
    static let width: CGFloat = 300
    static let thumbnailWidth: CGFloat = 88
    static let bottomInset: CGFloat = 130
    static let barHeight: CGFloat = 4
    #endif
    /// Run-out in seconds when there is no `Outro` segment.
    static let fallbackLeadIn: Double = 15
}
