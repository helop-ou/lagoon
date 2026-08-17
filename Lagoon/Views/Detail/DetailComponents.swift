import SwiftUI

/// Full-bleed backdrop behind a detail page (HEL-46). Only lightly dimmed —
/// the artwork is meant to be the first thing you see, and the scrim that
/// makes text readable travels with the content block instead, so it lands
/// exactly where the words are.
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
        .overlay(Color.black.opacity(0.25))
        .ignoresSafeArea()
    }
}

/// The band where the backdrop hands over to the content. It sits *above*
/// the info block rather than behind it: a fade that overlaps the title
/// leaves the title on whatever the artwork happens to be, which is a
/// coin toss on bright backdrops (Gilmore Girls' white-brick still was the
/// case that proved it).
struct DetailScrimFade: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.6), .black.opacity(Self.floor)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Metrics.detailScrimFade)
    }

    static let floor: Double = 0.93
}

/// What the content itself sits on, once the fade has done its work.
struct DetailContentScrim: View {
    var body: some View {
        Color.black.opacity(DetailScrimFade.floor)
            .ignoresSafeArea(edges: .bottom)
    }
}

/// Title, metadata, capability badges, actions and synopsis — the block that
/// sits at the bottom of a detail page's first screen.
///
/// No poster: the backdrop is the artwork here (the poster-left composition
/// this replaced came from the reference app). Everything is left-aligned on the
/// screen gutter so title, badges, buttons and synopsis share one edge.
struct DetailHeader<Buttons: View>: View {
    let item: MediaItem
    @ViewBuilder let buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.name ?? "")
                .font(.largeTitle.bold())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let tagline = item.taglines?.first, !tagline.isEmpty {
                Text(tagline)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: "  ·  "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !badges.isEmpty {
                HStack(spacing: 10) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .overlay(
                                Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
            }

            buttons

            if let overview = item.overview {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .frame(maxWidth: 1000, alignment: .leading)
            }
        }
        .padding(.horizontal, Metrics.screenGutter)
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
        if let genres = item.genres, !genres.isEmpty {
            parts.append(genres.prefix(3).joined(separator: ", "))
        }
        return parts
    }

    /// Only the single-item fetch carries MediaSources, so this is empty
    /// until the detail page's own request lands — the row simply appears.
    private var badges: [String] {
        item.mediaSources?.first?.qualityBadges ?? []
    }
}

/// Cast strip. Deliberately **not** focusable and not scrolling: there's no
/// person screen to navigate to, and a rail you can focus but not act on is
/// worse than a short honest one. It sits between the buttons and the
/// related rail, so moving focus down scrolls it into view.
struct CastStrip: View {
    let people: [Person]

    @Environment(SessionStore.self) private var session

    private var cast: [Person] {
        people.filter { $0.type == "Actor" && $0.primaryImageTag != nil }
    }

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cast")
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)

                #if os(tvOS)
                // Fixed row: eight fit across a 16:9 screen, and a rail you
                // can focus but not act on is worse than a short honest one.
                HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                    ForEach(cast.prefix(Metrics.castCount)) { person in
                        castMember(person)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.top, 20)
                #else
                // Touch scrolls without needing focus, so the phone shows
                // the whole cast rather than the four that would fit — and
                // four at this width would overflow the screen anyway.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(cast) { person in
                            castMember(person)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, 20)
                }
                #endif
            }
        }
    }

    private func castMember(_ person: Person) -> some View {
        VStack(spacing: 10) {
            CachedAsyncImage(
                url: session.client.personImageURL(for: person, maxWidth: Int(Metrics.castPortraitSize * 2)),
                maxPixelSize: Int(Metrics.castPortraitSize * 2)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "person.fill")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Metrics.castPortraitSize, height: Metrics.castPortraitSize)
            .clipShape(Circle())

            VStack(spacing: 2) {
                // Two lines for the name: at eight across there is width to
                // spare, and "Elijah Isaiah…" reads worse than a wrap.
                Text(person.name ?? "")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Metrics.castPortraitSize + 50)
        }
    }
}
