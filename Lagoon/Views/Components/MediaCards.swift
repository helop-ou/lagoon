import SwiftUI

// Focus strategy: no custom scaling anywhere — cards rely on the system
// `.card` lift/parallax. Focus only drives the title reveal.

/// 2:3 poster card that navigates to the item's detail page.
struct PosterCard: View {
    let item: MediaItem
    @Environment(SessionStore.self) private var session
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationLink(value: item) {
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

                titleScrim
                progressBar
            }
            .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
        }
        .focused($isFocused)
        .cardButtonStyle()
        .accessibilityLabel(item.name ?? "Item")
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

    private var titleScrim: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.4), .clear],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: Metrics.posterHeight * 0.4)

            Text(item.name ?? "")
                .font(.callout.bold())
                .lineLimit(2)
                .padding(Metrics.Space.m)
        }
        .opacity(titleVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: titleVisible)
    }

    private var titleVisible: Bool {
        #if os(tvOS)
        isFocused
        #else
        true
        #endif
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress = item.playbackProgress {
            ItemProgressBar(progress: progress)
        }
    }
}

/// 16:9 card for continue-watching and next-up rails; starts playback directly.
struct LandscapeCard: View {
    let item: MediaItem
    let action: () -> Void
    @Environment(SessionStore.self) private var session

    var body: some View {
        Button(action: action) {
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

                if let progress = item.playbackProgress {
                    ItemProgressBar(progress: progress)
                }
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
        }
        .cardButtonStyle()
        .accessibilityLabel(item.railTitle)
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
