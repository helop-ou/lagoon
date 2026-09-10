import SwiftUI

// Focus strategy: no custom scaling anywhere — cards rely on the system
// `.card` lift/parallax for the movement, and add one thing of their own: an
// ambient halo sampled from the card's artwork (HEL-139). Nothing here scales,
// replaces or competes with the system treatment.

/// 2:3 poster card that navigates to the item's detail page.
///
/// The title sits **under** the artwork, not over it (Jaagop, 2026-08-17):
/// a scrim and a headline across the bottom third covers the part of a poster
/// its designer cared most about, and a poster is already a title card. Below
/// it, the name and the year — the two things a poster doesn't reliably tell
/// you — in the Infuse arrangement.
struct PosterCard: View {
    let item: MediaItem
    @Environment(SessionStore.self) private var session
    let layout = PosterLayout()

    var body: some View {
        // The gap has to clear the focus lift, not just look right at rest:
        // `.card` scales the poster about a tenth, so a 390pt one grows ~20pt
        // past its resting bottom edge and lands on the title (Jaagop).
        VStack(alignment: .leading, spacing: layout.spacing) {
            NavigationLink(value: ContentNavigationRoute.item(item)) {
                ZStack(alignment: .bottom) {
                    CachedAsyncImage(
                        url: posterURL,
                        maxPixelSize: layout.imageSize
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholderLabel
                    }
                    .frame(width: layout.width, height: layout.height)
                    .clipped()

                    progressBar
                }
                .frame(width: layout.width, height: layout.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .artworkFocusHue(url: posterURL, cornerRadius: Metrics.cardArtRadius)
            .accessibilityLabel(item.name ?? "Item")
            .accessibilityIdentifier("media.poster.\(item.id)")

            caption
        }
        .frame(width: layout.width)
    }

    private var posterURL: URL? {
        session.client.imageURL(
            for: item,
            kind: .primary,
            maxWidth: layout.imageWidth
        )
    }

    /// Fixed height so a one-line title and a two-line one still leave every
    /// row of a grid aligned.
    private var caption: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
            Text(item.name ?? "")
                .font(.caption.weight(.medium))
                .lineLimit(layout.captionLines)
            if let year = item.productionYear {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: layout.width, alignment: .leading)
        .frame(minHeight: layout.captionHeight, alignment: .topLeading)
    }

    private var placeholderLabel: some View {
        ZStack {
            Color.white.opacity(0.07)
            Text(item.name ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(Metrics.Space.m)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress = item.playbackProgress {
            ItemProgressBar(progress: progress)
        }
    }
}

/// 16:9 card for landscape rails. Resume-oriented rails provide a direct-play
/// action and can opt into metadata; discovery rails navigate to item details
/// and keep the artwork free of the underlying asset's title.
struct LandscapeCard: View {
    let item: MediaItem
    var showsMetadata = false
    var action: (() -> Void)? = nil
    @Environment(SessionStore.self) private var session
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    artwork
                }
                .accessibilityIdentifier("media.landscape.\(item.id)")
            } else {
                NavigationLink(value: ContentNavigationRoute.item(item)) {
                    artwork
                }
                .accessibilityIdentifier("media.landscape.\(item.id)")
            }
        }
        .cardButtonStyle()
        .artworkFocusHue(url: thumbURL, cornerRadius: Metrics.cardArtRadius)
        .accessibilityLabel(item.railTitle)
    }

    private var thumbURL: URL? {
        session.client.imageURL(
            for: item,
            kind: .thumb,
            maxWidth: ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale)
        )
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(
                url: thumbURL,
                maxPixelSize: ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipped()

            // A card with no artwork at all still needs to say what it is;
            // without the label it is an anonymous grey tile (HEL-157).
            if showsMetadata || thumbURL == nil {
                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top)
                    .frame(height: Metrics.landscapeHeight * 0.55)
                    .frame(maxWidth: .infinity, alignment: .bottom)

                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(item.railTitle)
                        .font(.footnote.bold())
                        .lineLimit(1)
                    if let subtitle = item.railSubtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Metrics.Space.m)
                .padding(.bottom, item.playbackProgress == nil ? 12 : 22)
            }

            if let progress = item.playbackProgress {
                ItemProgressBar(progress: progress)
            }
        }
        .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
    }
}

/// 6pt playback progress bar pinned to a card's bottom edge.
#if os(tvOS)
/// An ambient halo behind a focused card, drawn from that card's own artwork
/// by the same sampler the hero glow uses.
///
/// Strictly additive: the system `.card` lift, parallax and specular remain
/// the whole of the focus treatment, and nothing here scales or replaces them.
/// The halo only tints the space the lift already opens up, which is why the
/// rails carry a little more padding than the lift alone needs.
private struct ArtworkFocusHue: ViewModifier {
    let url: URL?
    let cornerRadius: CGFloat

    @FocusState private var isFocused: Bool
    @State private var palette: ArtworkPalette?

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .background { halo }
            // Holding a direction walks a rail faster than artwork can be
            // sampled, so nothing is fetched until focus settles. Changing
            // focus cancels the wait rather than queueing another sample.
            .task(id: "\(url?.absoluteString ?? "")|\(isFocused)") {
                guard isFocused, let url else { return }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let sampled = await ArtworkPaletteCache.shared.palette(for: url)
                guard !Task.isCancelled else { return }
                // The halo does not exist until this lands, so its arrival is
                // an insertion rather than a change of opacity. Without an
                // animated transaction here there is nothing for the opacity
                // animation below to interpolate and the hue snaps in at full
                // strength; it only faded when re-focusing a card whose
                // palette had already been sampled.
                withAnimation(.easeOut(duration: Motion.standard)) {
                    palette = sampled
                }
            }
    }

    @ViewBuilder
    private var halo: some View {
        if let palette {
            RoundedRectangle(cornerRadius: cornerRadius + Metrics.Space.s)
                .fill(
                    LinearGradient(
                        colors: palette.colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: Metrics.focusHaloBlur)
                // Grown by padding rather than a scale, so nothing in the card
                // hierarchy carries a focus-driven transform.
                .padding(-Metrics.Space.xl)
                .opacity(isFocused ? Metrics.focusHaloOpacity : 0)
                .animation(.easeOut(duration: Motion.standard), value: isFocused)
                // Carries the insertion above; the opacity animation only
                // covers focus moving on a card that already has its palette.
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}
#endif

extension View {
    /// Adds the artwork-derived focus halo on tvOS, and nothing anywhere else.
    @ViewBuilder
    func artworkFocusHue(url: URL?, cornerRadius: CGFloat) -> some View {
        #if os(tvOS)
        modifier(ArtworkFocusHue(url: url, cornerRadius: cornerRadius))
        #else
        self
        #endif
    }
}

struct ItemProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.6))
                Rectangle()
                    .fill(Color.lagoonAqua)
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: Metrics.progressBarHeight)
        .clipShape(Capsule())
        .padding(.horizontal, Metrics.Space.m)
        .padding(.bottom, Metrics.Space.s)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

extension MediaItem {
    /// Fractional watch progress, or nil when there's nothing worth drawing —
    /// including the ≥95% tail where a bar reads as "watched" clutter.
    var playbackProgress: Double? {
        guard let percentage = userData?.playedPercentage, percentage > 0, percentage < 95 else { return nil }
        return percentage / 100
    }

    /// Rail label: episodes show their series, everything else its own name.
    var railTitle: String {
        if type == .episode, let seriesName { return seriesName }
        return name ?? ""
    }

    var railSubtitle: String? {
        guard type == .episode else { return nil }
        var parts: [String] = []
        if let episodeLabel { parts.append(episodeLabel) }
        if let name { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var episodeLabel: String? {
        guard type == .episode else { return nil }
        switch (parentIndexNumber, indexNumber) {
        case let (season?, episode?): return "S\(season) E\(episode)"
        case let (nil, episode?): return "E\(episode)"
        default: return nil
        }
    }

    var runtimeLabel: String? {
        guard let runTimeTicks else { return nil }
        let minutes = Int(Ticks.seconds(runTimeTicks) / 60)
        guard minutes > 0 else { return nil }
        if minutes >= 60 {
            return "\(minutes / 60) h \(minutes % 60) min"
        }
        return "\(minutes) min"
    }
}
