import SwiftUI

/// Full-bleed backdrop behind a detail page (HEL-46). Only lightly dimmed —
/// the artwork is meant to be the first thing you see, and the scrim that
/// makes text readable travels with the content block instead, so it lands
/// exactly where the words are.
struct DetailBackdropView: View {
    let url: URL?
    /// Rises as content scrolls over the artwork — see `DetailPageScaffold`.
    var dim: Double = 0.12

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
        .overlay(Color.black.opacity(dim))
        // Leading wash: the info block is left-aligned, so that half needs a
        // dark bed while the other half stays vivid. This is what lets the
        // reference keep its artwork bright — a uniform scrim strong enough
        // for text over a busy still flattens the whole image.
        .overlay(
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.7), location: 0.3),
                    .init(color: .clear, location: 0.68),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .ignoresSafeArea()
    }
}

/// The shell both detail pages sit in: full-bleed backdrop, content inset
/// below it, and the backdrop darkening as that content rises over it.
///
/// The hero space is a **scroll content margin, not a spacer view**. As a
/// spacer it was non-focusable content sitting above the first button, which
/// left the focus engine no way back out — Up from Play did nothing, the
/// scroll never returned to the top, and the tab bar stayed off-screen and
/// unreachable (Jaagop, 2026-08-17). As an inset, the first button *is* the
/// first content item, so Up leaves the page the way tvOS expects.
///
/// The dimming replaces the fixed scrim panel the first pass used: the
/// reference keeps its artwork vivid and has no dark panel at all, which
/// only works if the artwork gets out of the way once you scroll past it.
struct DetailPageScaffold<Content: View>: View {
    let backdropURL: URL?
    @ViewBuilder let content: Content

    @State private var scrolled: CGFloat = 0

    var body: some View {
        ZStack {
            DetailBackdropView(url: backdropURL, dim: dim)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 44) {
                    content
                }
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.top, Metrics.detailHeroSpace, for: .scrollContent)
            .scrollClipDisabled()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrolled = offset
            }
        }
    }

    private var dim: Double {
        let progress = min(max(scrolled / Metrics.detailHeroSpace, 0), 1)
        return 0.12 + progress * 0.68
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
        VStack(alignment: .leading, spacing: 16) {
            TitleArtView(item: item)

            // One spaced line, per the reference: runtime, year, a boxed
            // certification, then plain capability tokens. No capsules —
            // the outlined chips this replaced read as much louder than the
            // facts deserve.
            HStack(spacing: 18) {
                ForEach(factTokens, id: \.self) { token in
                    Text(token)
                }
                if let official = item.officialRating {
                    Text(official)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                        )
                }
                ForEach(qualityTokens, id: \.self) { token in
                    Text(token)
                }
            }
            .font(.callout)

            if let genres = item.genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let rating = item.communityRating {
                Text(String(format: "★ %.1f", rating))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let overview = item.overview {
                Text(overview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: 1000, alignment: .leading)
            }

            buttons
                .padding(.top, 6)
        }
        .padding(.horizontal, Metrics.screenGutter)
    }

    /// Runtime first, then year — the reference's order.
    private var factTokens: [String] {
        var parts: [String] = []
        if let episodeLabel = item.episodeLabel {
            parts.append(episodeLabel)
        }
        if let runtime = item.runtimeLabel {
            parts.append(runtime)
        }
        if let year = item.productionYear {
            parts.append(String(year))
        }
        if let status = item.status, item.type == .series {
            parts.append(status)
        }
        return parts
    }

    /// Only the single-item fetch carries MediaSources, so this is empty
    /// until the detail page's own request lands — the tokens simply appear.
    private var qualityTokens: [String] {
        item.mediaSources?.first?.qualityTokens ?? []
    }
}

/// The title, as its own artwork when the server has a logo for it and as
/// type when it doesn't. Logos are transparent PNGs at wildly varying
/// aspect ratios, so this is a box they fit inside rather than a fixed
/// frame — the height is the constraint that keeps a wide wordmark and a
/// stacked one looking like the same design.
struct TitleArtView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session

    var body: some View {
        if let url = session.client.imageURL(for: item, kind: .logo, maxWidth: Int(Metrics.logoMaxWidth * 2)) {
            CachedAsyncImage(url: url, maxPixelSize: Int(Metrics.logoMaxWidth * 2)) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                // Type, not a grey box: a placeholder that reserves the
                // logo's full height would leave a hole on every load.
                titleText
            }
            .frame(maxWidth: Metrics.logoMaxWidth, maxHeight: Metrics.logoMaxHeight, alignment: .leading)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(item.name ?? "")
            .font(.largeTitle.bold())
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Cast strip. Deliberately **not** focusable and not scrolling: there's no
/// person screen to navigate to, and a rail you can focus but not act on is
/// worse than a short honest one. It sits between the buttons and the
/// related rail, so moving focus down scrolls it into view.
struct CastStrip: View {
    let people: [Person]

    @Environment(SessionStore.self) private var session

    /// Actors first, then crew — the server returns them roughly in that
    /// order already, so this only drops the ones with no headshot, which
    /// would otherwise be a row of grey circles.
    private var cast: [Person] {
        people.filter { $0.primaryImageTag != nil }
    }

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cast and Crew")
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

    private func credit(for person: Person) -> String? {
        if let role = person.role, !role.isEmpty { return role }
        return person.type
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
                // Character for actors; the credit itself for crew, so a
                // director doesn't sit there with a blank line under them.
                if let credit = credit(for: person) {
                    Text(credit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Metrics.castPortraitSize + 50)
        }
    }
}
