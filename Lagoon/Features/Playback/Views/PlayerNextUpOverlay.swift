import SwiftUI

/// When the Up Next card and its countdown are due. Pure, and separate from
/// the view, because the player, the card and the launch-gated regression
/// probe all have to agree about it.
nonisolated enum NextUpPolicy {
    /// When the card appears. With an outro that is where the credits start;
    /// without one it is a short fixed run-out, because guessing any earlier
    /// would put the card over the closing scene.
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

    /// When the fill starts, which is not always when the card does.
    ///
    /// With an outro there are credits to cut short, so the countdown runs
    /// from their first frame — the whole point of the feature. Without one
    /// the server has told us nothing about where the episode stops being
    /// the episode, so the fill is pinned to the last seconds of the file
    /// and autoplay can never eat content nobody called credits.
    static func countdownStart(
        cardStart: Double?,
        outroStart: Double?,
        duration: Double
    ) -> Double? {
        guard let cardStart else { return nil }
        if outroStart != nil { return cardStart }
        return max(cardStart, duration - AutoplayMode.countdownSeconds)
    }
}

/// The Up Next card (HEL-66), lifted out of `CustomPlayerView` (HEL-150).
/// It draws `PlaybackAutomation`'s answer: whether the card is due and how
/// far the countdown has run are decided off the engine's clock, so a
/// locked phone still rolls into the next episode (HEL-176). The parent
/// only hears about a committed hand-off through the automation.
/// Bottom-trailing, on the same shelf as the skip pill. The two can never
/// be up together — intro and recap live at the front of an episode, the
/// credits at the back — so they share the corner rather than competing
/// for it.
struct PlayerNextUpOverlay: View {
    let automation: PlaybackAutomation
    /// The episode queued behind this one. Nil for movies, at the end of a
    /// series, and until the lookup lands.
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
                // Touch has no Select to route, so the card takes the tap
                // itself — see the hit-testing note below.
                .onTapGesture { automation.playNext() }
                #endif
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: isCardVisible)
        // tvOS drives this from the surface's Select, and a focusable card
        // would move `onMoveCommand` off the surface and kill scrubbing
        // while it is up — the same trap the skip pill documents.
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
    /// With no `Outro` segment there is nothing to say where the credits
    /// begin, so the card appears on a fixed run-out instead. Long enough
    /// to read and act on, short enough not to sit over the closing scene.
    static let fallbackLeadIn: Double = 15
}
