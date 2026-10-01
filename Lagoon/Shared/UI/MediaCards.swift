import SwiftUI

// Focus: no custom scaling. Cards use the system `.card` lift and add only
// an artwork-sampled halo.

/// The 2:3 poster shape shared by every poster card: artwork, clip, focus
/// and caption. `badge` draws over the artwork and positions itself (see
/// `ItemProgressBar` and `StatusCapsule`); a corner mark is the caller's
/// `.downloadedBadge`.
struct PosterCardShell<Route: Hashable, Badge: View>: View {
    let route: Route
    let imageURL: URL?
    let maxPixelSize: Int
    let title: String
    /// Shown in the placeholder while artwork loads; defaults to `title`.
    let placeholderTitle: String?
    let subtitle: String?
    let accessibilityLabel: String
    let accessibilityValue: String?
    let accessibilityIdentifier: String
    let badge: () -> Badge

    let layout = PosterLayout()

    init(
        route: Route,
        imageURL: URL?,
        maxPixelSize: Int,
        title: String,
        placeholderTitle: String? = nil,
        subtitle: String?,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        accessibilityIdentifier: String,
        @ViewBuilder badge: @escaping () -> Badge = { EmptyView() }
    ) {
        self.route = route
        self.imageURL = imageURL
        self.maxPixelSize = maxPixelSize
        self.title = title
        self.placeholderTitle = placeholderTitle
        self.subtitle = subtitle
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.accessibilityIdentifier = accessibilityIdentifier
        self.badge = badge
    }

    var body: some View {
        // The gap must clear the focus lift: `.card` grows the poster ~20pt
        // past its bottom edge.
        VStack(alignment: .leading, spacing: layout.spacing) {
            NavigationLink(value: route) {
                ZStack {
                    CachedAsyncImage(
                        url: imageURL,
                        maxPixelSize: maxPixelSize
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholder
                    }
                    .frame(width: layout.width, height: layout.height)
                    .clipped()

                    badge()
                }
                .frame(width: layout.width, height: layout.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .artworkFocusHue(url: imageURL, cornerRadius: Metrics.cardArtRadius)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValueIfPresent(accessibilityValue)
            .accessibilityIdentifier(accessibilityIdentifier)

            caption
        }
        .frame(width: layout.width)
    }

    private var placeholder: some View {
        ZStack {
            Color.artworkPlaceholder
            Text(placeholderTitle ?? title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(Metrics.Space.m)
        }
    }

    /// Fixed height keeps grid rows aligned.
    private var caption: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(layout.captionLines)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(width: layout.width, alignment: .leading)
        .frame(minHeight: layout.captionHeight, alignment: .topLeading)
    }
}

private extension View {
    /// SwiftUI's `accessibilityValue` always sets a value; this skips it
    /// when there is none, instead of announcing an empty one.
    @ViewBuilder
    func accessibilityValueIfPresent(_ value: String?) -> some View {
        if let value {
            accessibilityValue(value)
        } else {
            self
        }
    }
}

/// 2:3 poster card that navigates to the item's detail page.
///
/// Name and year sit **under** the artwork, never over the poster.
struct PosterCard: View {
    let item: MediaItem
    @Environment(\.jellyfinClient) private var client
    @Environment(\.itemDownloads) private var downloads
    let layout = PosterLayout()

    var body: some View {
        PosterCardShell(
            route: ContentNavigationRoute.item(item),
            imageURL: posterURL,
            maxPixelSize: layout.imageSize,
            title: item.name ?? "",
            subtitle: item.productionYear.map(String.init),
            accessibilityLabel: (item.name ?? "Item")
                .appendingDownloadedSuffix(if: downloads?.isDownloaded(item.id) == true),
            accessibilityIdentifier: "media.poster.\(item.id)"
        ) {
            progressBar
        }
        .downloadedBadge(itemID: item.id)
    }

    private var posterURL: URL? {
        client?.imageURL(
            for: item,
            kind: .primary,
            maxWidth: layout.imageWidth
        )
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
    @Environment(\.jellyfinClient) private var client
    @Environment(\.itemDownloads) private var downloads
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
        item.railTitle.appendingDownloadedSuffix(if: downloads?.isDownloaded(item.id) == true)
    }

    private var thumbURL: URL? {
        client?.imageURL(
            for: item,
            kind: .thumb,
            maxWidth: ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale)
        )
    }

    private var artwork: some View {
        LandscapeArtwork(
            imageURL: thumbURL,
            maxPixelSize: ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale),
            showsMetadata: showsMetadata || thumbURL == nil,
            progress: item.playbackProgress
        ) {
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
        }
        .downloadedBadge(itemID: item.id)
    }
}

/// 16:9 artwork with a clip, an optional bottom-gradient metadata wash and a
/// playback-progress bar. Shared by landscape rail cards and episode tiles;
/// `metadata` draws the caller's own title block inside the wash, and a
/// corner mark is the caller's `.downloadedBadge`.
struct LandscapeArtwork<Metadata: View>: View {
    let imageURL: URL?
    let maxPixelSize: Int
    var width: CGFloat = Metrics.landscapeWidth
    var height: CGFloat = Metrics.landscapeHeight
    let showsMetadata: Bool
    let progress: Double?
    @ViewBuilder var metadata: () -> Metadata

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(
                url: imageURL,
                maxPixelSize: maxPixelSize
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.artworkPlaceholder
            }
            .frame(width: width, height: height)
            .clipped()

            if showsMetadata {
                LinearGradient(
                    colors: [.black.opacity(Metrics.landscapeMetadataGradientOpacity), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: height * 0.55)
                .frame(maxWidth: .infinity, alignment: .bottom)

                metadata()
                    .padding(.horizontal, Metrics.Space.m)
                    .padding(
                        .bottom,
                        progress == nil
                            ? Metrics.landscapeMetadataPadding
                            : Metrics.landscapeMetadataPaddingWithProgress
                    )
            }

            if let progress {
                ItemProgressBar(progress: progress)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
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

extension View {
    /// The "downloaded" badge in a card's top-trailing corner, iOS only.
    /// `leading` draws beside it in the same corner group on both platforms
    /// (e.g. `WatchedMark`, which is not download-gated).
    @ViewBuilder
    func downloadedBadge<Leading: View>(
        itemID: String,
        inset: CGFloat = Metrics.Space.xs,
        @ViewBuilder leading: () -> Leading = { EmptyView() }
    ) -> some View {
        modifier(DownloadedBadge(itemID: itemID, inset: inset, leading: leading()))
    }
}

private struct DownloadedBadge<Leading: View>: ViewModifier {
    let itemID: String
    let inset: CGFloat
    let leading: Leading
    @Environment(\.itemDownloads) private var downloads

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            HStack(spacing: Metrics.Space.xs) {
                leading
                #if os(iOS)
                if downloads?.isDownloaded(itemID) == true {
                    DownloadedMark()
                }
                #endif
            }
            .padding(inset)
        }
    }
}

extension String {
    /// Appends ", downloaded" for a downloaded item, for a card's
    /// accessibility label.
    func appendingDownloadedSuffix(if isDownloaded: Bool) -> String {
        isDownloaded ? "\(self), \(String(localized: "downloaded"))" : self
    }
}

/// A landscape shelf card's title, drawn over a dimming wash. Shared by
/// `GenreCard` and `SeerrGenreCard`, so the two never drift in font, wrap
/// rules or placement. The artwork beneath takes `genreArtworkTreatment()`.
struct GenreCardLabel: View {
    let name: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.opacity(Metrics.genreArtworkDim)
            LinearGradient(colors: titleWash, startPoint: .top, endPoint: .bottom)

            Text(name)
                .font(.title3.bold())
                #if os(tvOS)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                .lineLimit(1)
                #endif
                .shadow(
                    color: .black.opacity(Metrics.artworkTitleShadowOpacity),
                    radius: Metrics.artworkTitleShadowRadius
                )
                .padding(Metrics.Space.xl)
        }
    }

    private var titleWash: [Color] {
        #if os(tvOS)
        // The name is centred; the bottom still darkens toward the rail.
        [.clear, .black.opacity(0.2), .black.opacity(0.5)]
        #else
        [.clear, .black.opacity(0.6)]
        #endif
    }
}

extension View {
    /// Softens a genre card's artwork so the name over it reads, however
    /// colourful the poster or whatever title is painted into it.
    func genreArtworkTreatment() -> some View {
        saturation(Metrics.genreArtworkSaturation)
            .blur(radius: Metrics.genreArtworkBlur, opaque: true)
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
        return EpisodeLabel.text(season: parentIndexNumber, episode: indexNumber, episodeEnd: indexNumberEnd)
    }

    var runtimeLabel: String? {
        guard let runTimeTicks else { return nil }
        return Self.runtimeLabel(minutes: Int(Ticks.seconds(runTimeTicks) / 60))
    }

    /// "45 min", "1 h 30 min"; nil for a runtime of zero or less.
    static func runtimeLabel(minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        if minutes >= 60 {
            return "\(minutes / 60) h \(minutes % 60) min"
        }
        return "\(minutes) min"
    }
}

/// "S1 E3", "S1 E1–2" for a double episode, "Special 2" for season 0.
///
/// Jellyfin keeps a special's season number at 0 even when it lists it
/// inside the season it aired in, so the label holds wherever it appears.
nonisolated enum EpisodeLabel {
    static func text(season: Int?, episode: Int?, episodeEnd: Int?) -> String? {
        let numbers = episode.map { episode in
            episodeEnd.map { $0 > episode ? "\(episode)–\($0)" : "\(episode)" } ?? "\(episode)"
        }
        switch (season, numbers) {
        case (0, let numbers?): return String(localized: "Special \(numbers)")
        case (0, nil): return String(localized: "Special")
        case let (season?, numbers?): return "S\(season) E\(numbers)"
        case let (nil, numbers?): return "E\(numbers)"
        default: return nil
        }
    }
}
