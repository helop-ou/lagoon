import SwiftUI

/// Blurred low-res stand-in with the full backdrop crossfading on top,
/// dimmed and washed from the leading edge for text readability.
struct DetailBackdropView: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            CachedAsyncImage(url: url, maxPixelSize: 1920) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.black
            }
            .animation(.easeInOut(duration: Motion.crossfade), value: url)
        }
        .overlay(Color.black.opacity(0.35))
        .overlay(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.7), location: 0),
                    .init(color: .clear, location: 0.6),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .ignoresSafeArea()
    }
}

/// Poster + info column header shared by the detail screens.
struct DetailHeader<Buttons: View>: View {
    let item: MediaItem
    let posterURL: URL?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        HStack(alignment: .center, spacing: 52) {
            CachedAsyncImage(url: posterURL, maxPixelSize: 540) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Metrics.posterWidth * 1.38, height: Metrics.posterHeight * 1.38)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 8)

            VStack(alignment: .leading, spacing: 18) {
                Text(item.name ?? "")
                    .font(.largeTitle.bold())
                    .lineLimit(2)

                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: "  ·  "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let genres = item.genres, !genres.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(genres.prefix(4), id: \.self) { genre in
                            Text(genre)
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.fill.tertiary, in: Capsule())
                        }
                    }
                }

                buttons

                if let overview = item.overview {
                    Text(overview)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }

            Spacer()
        }
        .padding(.top, Metrics.screenGutter)
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.bottom, 40)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let episodeLabel = item.episodeLabel {
            parts.append(episodeLabel)
        }
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if let runtime = item.runtimeLabel {
            parts.append(runtime)
        }
        if let status = item.status, item.type == .series {
            parts.append(status)
        }
        if let official = item.officialRating {
            parts.append(official)
        }
        if let rating = item.communityRating {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts
    }
}
