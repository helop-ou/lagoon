import SwiftUI

// Focus: no custom scaling. Cards use the system `.card` lift and add only
// an artwork-sampled halo.

/// 2:3 poster card that navigates to the item's detail page.
///
/// Name and year sit **under** the artwork, never over the poster.
struct PosterCard: View {
    let item: MediaItem
    @Environment(SessionStore.self) private var session
    let layout = PosterLayout()

    var body: some View {
        // The gap must clear the focus lift: `.card` grows the poster ~20pt
        // past its bottom edge.
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
                #if os(iOS)
                .overlay(alignment: .topTrailing) { downloadedBadge }
                #endif
            }
            .cardButtonStyle()
            .artworkFocusHue(url: posterURL, cornerRadius: Metrics.cardArtRadius)
            .accessibilityLabel(posterAccessibilityLabel)
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

    #if os(iOS)
    @ViewBuilder
    private var downloadedBadge: some View {
        if DownloadStore.shared.isDownloaded(item.id) {
            DownloadedMark()
                .padding(Metrics.Space.xs)
        }
    }
    #endif

    private var posterAccessibilityLabel: String {
        let name = item.name ?? "Item"
        #if os(iOS)
        return DownloadStore.shared.isDownloaded(item.id) ? "\(name), downloaded" : name
        #else
        return name
        #endif
    }

    /// Fixed height keeps grid rows aligned.
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

/// 16:9 card for landscape rails. Resume rails play directly; others open
/// the detail page.
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
        .accessibilityLabel(landscapeAccessibilityLabel)
    }

    private var landscapeAccessibilityLabel: String {
        #if os(iOS)
        DownloadStore.shared.isDownloaded(item.id) ? "\(item.railTitle), downloaded" : item.railTitle
        #else
        item.railTitle
        #endif
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

            // No artwork: show the name.
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
        #if os(iOS)
        .overlay(alignment: .topTrailing) {
            if DownloadStore.shared.isDownloaded(item.id) {
                DownloadedMark()
                    .padding(Metrics.Space.xs)
            }
        }
        #endif
    }
}

/// 6pt playback progress bar pinned to a card's bottom edge.
#if os(tvOS)
/// An ambient halo behind a focused card, sampled from its artwork.
///
/// Strictly additive to the system `.card` focus; nothing here scales. Rails
/// carry extra padding for it on top of the lift.
private struct ArtworkFocusHue: ViewModifier {
    let url: URL?
    let cornerRadius: CGFloat

    @FocusState private var isFocused: Bool
    @State private var palette: ArtworkPalette?

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .background { halo }
            // Wait for focus to settle; a held direction outruns sampling.
            .task(id: "\(url?.absoluteString ?? "")|\(isFocused)") {
                guard isFocused, let url else { return }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                let sampled = await ArtworkPaletteCache.shared.palette(for: url)
                guard !Task.isCancelled else { return }
                // The halo's arrival is an insertion, so it needs its own
                // animated transaction or it snaps in at full strength.
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
                        colors: Theme.glow(for: palette).colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blur(radius: Metrics.focusHaloBlur)
                // Padding, not scale: no focus-driven transforms.
                .padding(-Metrics.Space.xl)
                .opacity(isFocused ? Metrics.focusHaloOpacity : 0)
                .animation(.easeOut(duration: Motion.standard), value: isFocused)
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
                    .fill(Theme.accent)
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

#if os(iOS)
/// Badge for a downloaded title: `DownloadControl`'s glyph on a dark disc.
struct DownloadedMark: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: Metrics.cardMarkSize * 0.6))
            .cardMark()
    }
}
#endif

/// Badge for a played episode: a checkmark on `DownloadedMark`'s disc. No
/// colour, like every watched state in the app.
struct WatchedMark: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: Metrics.cardMarkSize * 0.5, weight: .bold))
            .cardMark()
    }
}

private extension View {
    /// Silent: the card's accessibility label carries the meaning.
    func cardMark() -> some View {
        foregroundStyle(.white)
            .frame(width: Metrics.cardMarkSize, height: Metrics.cardMarkSize)
            .background(Circle().fill(.black.opacity(0.6)))
            .accessibilityHidden(true)
    }
}

extension MediaItem {
    /// Fractional watch progress; nil when zero or at 95% and above.
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
