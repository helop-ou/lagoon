import SwiftUI

// Focus strategy: no custom scaling anywhere — cards rely on the system
// `.card` lift/parallax, and that is now the *only* thing focus does here.

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

    var body: some View {
        // The gap has to clear the focus lift, not just look right at rest:
        // `.card` scales the poster about a tenth, so a 390pt one grows ~20pt
        // past its resting bottom edge and lands on the title (Jaagop).
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            NavigationLink(value: ContentNavigationRoute.item(item)) {
                ZStack(alignment: .bottom) {
                    CachedAsyncImage(
                        url: session.client.imageURL(for: item, kind: .primary, maxWidth: Int(Metrics.posterWidth * 1.5)),
                        maxPixelSize: Int(Metrics.posterHeight)
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholderLabel
                    }
                    .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                    .clipped()

                    progressBar
                }
                .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .accessibilityLabel(item.name ?? "Item")
            .accessibilityIdentifier("media.poster.\(item.id)")

            caption
        }
        .frame(width: Metrics.posterWidth)
    }

    /// Fixed height so a one-line title and a two-line one still leave every
    /// row of a grid aligned.
    private var caption: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
            Text(item.name ?? "")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let year = item.productionYear {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Metrics.posterWidth, height: Metrics.posterCaptionHeight, alignment: .topLeading)
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
        .accessibilityLabel(item.railTitle)
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(
                url: session.client.imageURL(for: item, kind: .thumb, maxWidth: Int(Metrics.landscapeWidth * 1.5)),
                maxPixelSize: Int(Metrics.landscapeWidth * 1.5)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipped()

            if showsMetadata {
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
struct ItemProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.6))
                Rectangle()
                    .fill(Color.lagoonTeal)
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
