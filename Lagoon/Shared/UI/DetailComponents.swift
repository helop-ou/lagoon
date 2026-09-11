import SwiftUI

/// Full-bleed backdrop behind a detail page (HEL-46). Only lightly dimmed —
/// the artwork is meant to be the first thing you see, and the scrim that
/// makes text readable travels with the content block instead, so it lands
/// exactly where the words are.
struct DetailBackdropView: View {
    let url: URL?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

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
        .overlay(readabilityWash)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var readabilityWash: some View {
        #if os(tvOS)
        // The 10-foot layout only occupies the leading half, so keep the
        // rest of the still vivid.
        ZStack {
            Color.black.opacity(0.12)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.9), location: 0),
                    .init(color: .black.opacity(0.7), location: 0.3),
                    .init(color: .clear, location: 0.68),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        #else
        // A phone's content spans the whole screen. A leading-only wash left
        // half the metadata over bare artwork and the lower sections over a
        // bright still. Keep the top recognisably photographic, then settle
        // into a near-black reading surface before the rails begin.
        ZStack {
            Color.black.opacity(contrast == .increased || reduceTransparency ? 0.9 : 0.55)
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.08), location: 0),
                    .init(color: .black.opacity(0.65), location: 0.28),
                    .init(color: .black.opacity(0.82), location: 0.55),
                    .init(color: .black.opacity(0.96), location: 0.76),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        #endif
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
/// The backdrop does **not** darken as you scroll. That was tried and cut
/// (Jaagop, 2026-08-17: "not a big fan of the screen going black"): moving
/// focus into a rail jumps further in one press than the ramp covered, so it
/// read as a slam to black rather than a settle. The artwork simply stays as
/// it is, and the rails below rely on their own artwork for contrast.
struct DetailPageScaffold<Content: View>: View {
    let backdropURL: URL?
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DetailBackdropView(url: backdropURL)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Metrics.detailSectionSpacing) {
                        content
                    }
                    .padding(.bottom, Metrics.detailBottomPadding)
                    // A horizontal rail reports its content's ideal width
                    // while it is loading. Without a concrete viewport, the
                    // enclosing vertical ScrollView accepted that width and
                    // centered a phone-sized page inside a ~1,300pt layout,
                    // putting the detail actions off-screen (HEL-41). The
                    // rails still scroll on their own axis; only the page is
                    // pinned to the screen it belongs to.
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .contentMargins(.top, Metrics.detailHeroSpace, for: .scrollContent)
                .scrollClipDisabled()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Title, metadata, capability badges, actions and synopsis — the block that
/// sits at the bottom of a detail page's first screen.
///
/// No poster: the backdrop is the artwork here, which replaced an earlier
/// poster-left composition. Everything is left-aligned on the screen gutter
/// so title, badges, buttons and synopsis share one edge.
struct DetailHeader<Buttons: View>: View {
    let item: MediaItem
    /// On a series page, the episode a Play press would start. Its label and
    /// synopsis take over from the show's, because what you're deciding about
    /// is the next episode, not the premise of the series (Infuse does the
    /// same). The title art stays the show's — that's the page's identity.
    var upNext: MediaItem?
    @ViewBuilder let buttons: Buttons

    var body: some View {
        DetailMetadataHeader(
            subtitle: upNext.flatMap { item in
                item.episodeLabel.map {
                    [$0, item.name].compactMap(\.self).joined(separator: "  ·  ")
                }
            },
            factTokens: factTokens,
            qualityTokens: qualityTokens,
            officialRating: item.officialRating,
            genres: item.genres ?? [],
            communityRating: item.communityRating,
            overview: upNext?.overview ?? item.overview
        ) {
            TitleArtView(item: item)
        } buttons: {
            buttons
        }
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

/// The common visual language for both Jellyfin and Seerr media details.
/// The services supply different title artwork and actions, while all of the
/// information hierarchy and platform-specific layout remains one component.
struct DetailMetadataHeader<Title: View, Buttons: View>: View {
    let subtitle: String?
    let factTokens: [String]
    let qualityTokens: [String]
    let officialRating: String?
    let genres: [String]
    let communityRating: Double?
    let overview: String?
    @ViewBuilder let title: Title
    @ViewBuilder let buttons: Buttons

    init(
        subtitle: String? = nil,
        factTokens: [String],
        qualityTokens: [String] = [],
        officialRating: String? = nil,
        genres: [String] = [],
        communityRating: Double? = nil,
        overview: String?,
        @ViewBuilder title: () -> Title,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.subtitle = subtitle
        self.factTokens = factTokens
        self.qualityTokens = qualityTokens
        self.officialRating = officialRating
        self.genres = genres
        self.communityRating = communityRating
        self.overview = overview
        self.title = title()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.detailHeaderSpacing) {
            #if os(tvOS)
            title
            #else
            // The phone has one full-width information column, rather than
            // tvOS's leading column beside the artwork.
            title
                .frame(maxWidth: .infinity, alignment: .center)
            #endif

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.title3.weight(.semibold))
                    #if os(tvOS)
                    .lineLimit(1)
                    #else
                    .fixedSize(horizontal: false, vertical: true)
                    #endif
            }

            facts
            supportingFacts

            if let overview, !overview.isEmpty {
                DetailOverview(text: overview)
            }

            buttons
                .padding(.top, Metrics.Space.xs)
        }
        #if os(iOS)
        // Let SwiftUI size the glass labels, circles and hit areas together.
        // This also covers the synopsis button in the header.
        .controlSize(.large)
        #endif
        .padding(.horizontal, Metrics.screenGutter)
    }

    @ViewBuilder
    private var facts: some View {
        #if os(tvOS)
        // One spaced line at 10 feet: runtime, year, certification, then
        // playback capabilities.
        HStack(spacing: Metrics.Space.l) {
            primaryFactViews
            qualityFactViews
        }
        .font(.callout)
        #else
        // Runtime/year/rating and playback capabilities are different kinds
        // of information. Separate rows let every token stay intact instead
        // of producing "1 h 56" / "min" and "TrueHD" / "7.1" fragments.
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !factTokens.isEmpty || officialRating != nil {
                MetadataFlowLayout {
                    primaryFactViews
                }
            }
            if !qualityTokens.isEmpty {
                MetadataFlowLayout {
                    qualityFactViews
                }
            }
        }
        .font(.callout)
        #endif
    }

    @ViewBuilder
    private var primaryFactViews: some View {
        ForEach(factTokens, id: \.self) { token in
            Text(token)
                #if os(tvOS)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                #else
                .fixedSize(horizontal: false, vertical: true)
                #endif
        }
        if let official = officialRating {
            Text(official)
                #if os(tvOS)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                #else
                .fixedSize(horizontal: false, vertical: true)
                #endif
                .padding(.horizontal, Metrics.Space.s)
                .padding(.vertical, Metrics.Space.hair)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                )
        }
    }

    @ViewBuilder
    private var qualityFactViews: some View {
        ForEach(qualityTokens, id: \.self) { token in
            Text(token)
                #if os(tvOS)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                #else
                .fixedSize(horizontal: false, vertical: true)
                #endif
        }
    }

    @ViewBuilder
    private var supportingFacts: some View {
        #if os(tvOS)
        if !genres.isEmpty {
            genreText(genres)
        }
        if let rating = communityRating {
            communityRatingText(rating)
        }
        #else
        if !genres.isEmpty || communityRating != nil {
            MetadataFlowLayout(spacing: Metrics.Space.l) {
                if !genres.isEmpty {
                    genreText(genres)
                }
                if let rating = communityRating {
                    communityRatingText(rating)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        #endif
    }

    private func genreText(_ genres: [String]) -> some View {
        Text(genres.prefix(3).joined(separator: ", "))
            .font(.callout)
            #if os(tvOS)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            #else
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            #endif
    }

    private func communityRatingText(_ rating: Double) -> some View {
        Text(String(format: "★ %.1f", rating))
            .font(.callout)
            #if os(tvOS)
            .foregroundStyle(.secondary)
            #else
            .foregroundStyle(.primary)
            #endif
    }
}

/// Keep the compact TV overview; touch can expand the same text without
/// leaving the detail page. Changing the episode resets the expansion.
private struct DetailOverview: View {
    let text: String
    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(text)
                .font(.callout)
                #if os(tvOS)
                .foregroundStyle(.secondary)
                #else
                .foregroundStyle(.primary)
                #endif
                .lineLimit(isExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 1000, alignment: .leading)
                #if os(iOS)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                .background {
                    Text(text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
                #endif
            #if os(iOS)
            if isExpanded || fullHeight > visibleHeight + 1 {
                Button(isExpanded ? "Show Less" : "Read Synopsis") {
                    isExpanded.toggle()
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("detail.overview.expand")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            }
            #endif
        }
        .onChange(of: text) { _, _ in isExpanded = false }
    }
}

/// The title, as its own artwork when the server has a logo for it and as
/// type when it doesn't. Logos are transparent PNGs at wildly varying
/// aspect ratios, so this is a box they fit inside rather than a fixed
/// frame — the height is the constraint that keeps a wide wordmark and a
/// stacked one looking like the same design.
struct TitleArtView: View {
    let item: MediaItem
    /// The hero wants a smaller box than a detail page does.
    var maxHeight: CGFloat = Metrics.logoMaxHeight

    @Environment(SessionStore.self) private var session

    var body: some View {
        TitleArtImage(
            url: session.client.imageURL(for: item, kind: .logo, maxWidth: Int(Metrics.logoMaxWidth * 2)),
            title: item.name ?? "",
            maxHeight: maxHeight
        )
    }
}

/// A title's logo where there is one, and the title set in type where there
/// is not. Split out of `TitleArtView` so the hero can use it for sources
/// that resolve their own artwork — Seerr serves no logo images at all, so
/// Discover's hero always takes the type path (HEL-114).
struct TitleArtImage: View {
    let url: URL?
    let title: String
    var maxHeight: CGFloat = Metrics.logoMaxHeight

    var body: some View {
        artwork
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url {
            CachedAsyncImage(url: url, maxPixelSize: Int(Metrics.logoMaxWidth * 2)) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                // Type, not a grey box: a placeholder that reserves the
                // logo's full height would leave a hole on every load.
                titleText
            }
            .frame(maxWidth: Metrics.logoMaxWidth, maxHeight: maxHeight, alignment: .leading)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.largeTitle.bold())
            #if os(tvOS)
            .lineLimit(2)
            #endif
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
                .padding(.top, Metrics.Space.l)
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
                    .padding(.top, Metrics.Space.l)
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
        VStack(spacing: Metrics.Space.s) {
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
            .accessibilityHidden(true)

            VStack(spacing: Metrics.Space.hair) {
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
            .frame(width: Metrics.castCaptionWidth)
        }
        .accessibilityElement(children: .combine)
    }
}
