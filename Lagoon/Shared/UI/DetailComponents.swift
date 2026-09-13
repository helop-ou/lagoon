import SwiftUI

/// Full-bleed backdrop behind a detail page (HEL-46). Only lightly dimmed —
/// the artwork is meant to be the first thing you see, and the scrim that
/// makes text readable travels with the content block instead, so it lands
/// exactly where the words are.
struct DetailBackdropView: View {
    let url: URL?
    /// Portrait artwork for the compact touch layout (HEL-169). On a phone
    /// or a compact iPad window the poster is the hero: it fills the width
    /// at the top and fades into the reading surface, and the landscape
    /// backdrop is not drawn at all. Regular-width iPad windows keep the
    /// backdrop, whose shape suits a wide window the way a poster does not.
    var posterURL: URL? = nil
    /// The height the poster hero occupies, decided by the scaffold so the
    /// content inset and the fade agree on where the words begin.
    var posterHeight: CGFloat = 0
    /// Which part of the poster the hero shows. Its top in a portrait
    /// window, so the artwork's own composition survives and only the
    /// bottom, where the fade sits anyway, is lost. Centre means a
    /// landscape window, where the whole poster is shown at the window's
    /// height over a blurred copy of itself filling the sides, as Infuse
    /// does, rather than a band cropped out of its middle.
    var posterAnchor: Alignment = .top
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        ZStack {
            Color.black
            #if os(iOS)
            if usesPosterHero {
                // Anchored to the top of a centred stack, so the backdrop
                // composition below keeps the centring it always had.
                VStack(spacing: 0) {
                    posterHero
                    Spacer(minLength: 0)
                }
            } else {
                backdrop
            }
            #else
            backdrop
            #endif
        }
        .overlay {
            #if os(iOS)
            if !usesPosterHero { readabilityWash }
            #else
            readabilityWash
            #endif
        }
        .ignoresSafeArea()
    }

    private var backdrop: some View {
        CachedAsyncImage(url: url, maxPixelSize: 1920) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.black
        }
        .animation(.easeInOut(duration: Motion.crossfade), value: url)
    }

    #if os(iOS)
    /// The scaffold decides: it hands over a height only for the compact,
    /// portrait composition, and zero whenever the backdrop should draw.
    private var usesPosterHero: Bool {
        posterURL != nil && posterHeight > 0
    }

    /// One image for both orientations, as Infuse frames it: the landscape
    /// key art, centred and cropped at the sides in portrait, shown whole
    /// in landscape. The portrait poster only stands in for a title that
    /// has no backdrop.
    private var heroURL: URL? { url ?? posterURL }
    private var heroIsPoster: Bool { url == nil }

    private var posterHero: some View {
        GeometryReader { proxy in
            ZStack {
                if heroIsPoster && posterAnchor == .center {
                    // A poster in a landscape window: the sides take a soft,
                    // dimmed copy of it and the poster stands whole in the
                    // middle. Both layers get the hero's own frame, so the
                    // fill's overflow never becomes the fit's proposal.
                    CachedAsyncImage(url: heroURL, maxPixelSize: Metrics.detailPosterAmbientDecodeSize) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.black
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .blur(radius: Metrics.detailPosterAmbientBlur)
                    .overlay(Color.black.opacity(0.35))
                    CachedAsyncImage(url: heroURL, maxPixelSize: Metrics.detailPosterDecodeSize) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    // The key art fills the hero edge to edge, centred: its
                    // middle in portrait, cropped at the sides, and in
                    // landscape the whole width with a little trimmed from the
                    // top and bottom, since a phone's window is wider than
                    // 16:9. A poster fallback keeps its top in portrait so its
                    // composition survives. The decode budget follows the
                    // image: the backdrop is requested wider than the poster.
                    CachedAsyncImage(
                        url: heroURL,
                        maxPixelSize: heroIsPoster ? Metrics.detailPosterDecodeSize : Metrics.detailBackdropDecodeSize
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.black
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: heroIsPoster ? posterAnchor : .center)
                    .clipped()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: posterHeight)
        .clipped()
        .overlay(posterFade)
        .animation(.easeInOut(duration: Motion.crossfade), value: heroURL)
    }

    /// Photographic at the top, a reading surface by the time the title
    /// arrives, black where the poster ends so the page continues seamlessly.
    /// The reading surface begins where the scaffold puts the content: the
    /// overlap point in portrait, the row's share in landscape.
    private var posterFade: some View {
        let heavy = contrast == .increased || reduceTransparency
        let contentStart = posterAnchor == .top
            ? 1 - Metrics.detailPosterContentOverlap
            : Metrics.detailLandscapeRowShare
        return LinearGradient(
            stops: [
                .init(color: .black.opacity(heavy ? 0.35 : 0), location: 0),
                .init(color: .black.opacity(heavy ? 0.5 : 0.08), location: contentStart * 0.66),
                .init(color: .black.opacity(heavy ? 0.9 : 0.72), location: contentStart),
                .init(color: .black.opacity(heavy ? 1 : 0.94), location: 0.9),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    #endif

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
        let heavy = contrast == .increased || reduceTransparency
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) {
            // A regular-width iPad window is laid out like the TV: the
            // information column on the leading half, so the wash is the
            // TV's leading fade and the trailing half stays vivid, with a
            // bottom fade for the rails that scroll up over it (HEL-169).
            ZStack {
                Color.black.opacity(heavy ? 0.85 : 0.18)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.85), location: 0),
                        .init(color: .black.opacity(0.55), location: 0.4),
                        .init(color: .clear, location: 0.75),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.85), location: 0.78),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            // A compact page without a poster hero (Seerr, collections):
            // the content spans the whole screen. Keep the top recognisably
            // photographic, then settle into a near-black reading surface
            // before the rails begin.
            ZStack {
                Color.black.opacity(heavy ? 0.9 : 0.3)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.35), location: 0.3),
                        .init(color: .black.opacity(0.8), location: 0.55),
                        .init(color: .black.opacity(0.95), location: 0.76),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
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
    /// Portrait artwork for the compact touch hero (HEL-169); nil keeps the
    /// backdrop composition on every platform.
    var posterURL: URL? = nil
    @ViewBuilder let content: Content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height
            let posterHeight = posterHeroHeight(in: proxy.size, safeArea: proxy.safeAreaInsets)
            ZStack {
                DetailBackdropView(
                    url: backdropURL,
                    posterURL: posterURL,
                    posterHeight: posterHeight,
                    posterAnchor: isLandscape ? .center : .top
                )

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
                .contentMargins(
                    .top,
                    heroSpace(posterHeight: posterHeight, isLandscape: isLandscape, safeTop: proxy.safeAreaInsets.top),
                    for: .scrollContent
                )
                .scrollClipDisabled()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// A 2:3 poster at the window's width, capped at a share of the height
    /// so the title is never pushed off-screen. In a landscape phone window
    /// the cap is all that applies and the hero is a band across the
    /// poster's middle, one image for both orientations the way Infuse does
    /// it. Zero for the wide iPad composition, which draws the backdrop.
    /// Portrait: a 2:3 poster at the window's width, capped at a share of
    /// the height so the title is never pushed off-screen. Landscape: the
    /// whole window, edge to edge under the safe areas, showing the
    /// poster's middle band, one image for both orientations the way
    /// Infuse does it. Zero for the wide iPad composition, which draws the
    /// backdrop.
    private func posterHeroHeight(in size: CGSize, safeArea: EdgeInsets) -> CGFloat {
        #if os(iOS)
        guard posterURL != nil, !DetailLayout.usesLeadingColumn(horizontalSizeClass) else { return 0 }
        if size.width > size.height {
            return (size.height + safeArea.top + safeArea.bottom).rounded()
        }
        if backdropURL != nil {
            return (size.height * Metrics.detailBackdropHeroShare).rounded()
        }
        return min((size.width * 3 / 2).rounded(), (size.height * Metrics.detailPosterHeroMaxShare).rounded())
        #else
        return 0
        #endif
    }

    /// Where the content begins. Over a poster hero the block rises into
    /// the poster's fade; the poster ignores the safe area and the scroll
    /// view does not, so the inset is taken from the same origin.
    private func heroSpace(posterHeight: CGFloat, isLandscape: Bool, safeTop: CGFloat) -> CGFloat {
        #if os(iOS)
        guard posterHeight > 0 else {
            return DetailLayout.usesLeadingColumn(horizontalSizeClass)
                ? Metrics.expandedDetailHeroSpace
                : Metrics.detailHeroSpace
        }
        let share = isLandscape ? Metrics.detailLandscapeRowShare : 1 - Metrics.detailPosterContentOverlap
        return max(0, (posterHeight * share).rounded() - safeTop)
        #else
        return Metrics.detailHeroSpace
        #endif
    }
}

#if os(iOS)
/// A glass circle for the phone's row of secondary detail actions (HEL-169).
/// Built on the interactive glass effect rather than `.buttonStyle(.glass)`
/// with a circular border shape: that style draws its pressed highlight as
/// a capsule sized to the label, not to the circle, so a press showed a
/// lozenge through the circle on iOS 26.0 and 26.5. The interactive effect
/// brightens and lifts the circle itself.
struct DetailCircleButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(width: Metrics.detailCircleActionSize, height: Metrics.detailCircleActionSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}
#endif

extension View {
    /// A detail page on iPhone and iPad is the immersive one: artwork edge to
    /// edge, one decision to make. The floating tab bar has no place over it
    /// and is hidden for the page's lifetime, the way Photos hides it over a
    /// photo (HEL-169). Back is the way out; the bar returns with the list
    /// it belongs to. tvOS has no tab bar to hide inside a pushed page.
    func detailPageChrome() -> some View {
        #if os(iOS)
        toolbarVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }
}

#if os(iOS)
/// The one question every touch detail component asks: is this the wide
/// composition (a regular-width iPad window, laid out like the TV) or the
/// compact one (a phone, or an iPad window narrow enough to read like one)?
enum DetailLayout {
    static func usesLeadingColumn(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    /// A landscape phone: the poster is the whole hero and the title,
    /// actions and Play share one row along its lower part (HEL-169).
    static func usesLandscapeRow(
        _ horizontalSizeClass: UserInterfaceSizeClass?,
        _ verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        !usesLeadingColumn(horizontalSizeClass) && verticalSizeClass == .compact
    }
}
#endif

/// Title, metadata, capability badges, actions and synopsis — the block that
/// sits at the bottom of a detail page's first screen.
///
/// No poster: the backdrop is the artwork here, which replaced an earlier
/// poster-left composition. Everything is left-aligned on the screen gutter
/// so title, badges, buttons and synopsis share one edge.
struct DetailHeader<Buttons: View>: View {
    let item: MediaItem
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
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
            #if os(iOS)
            TitleArtView(
                item: item,
                alignment: DetailLayout.usesLeadingColumn(horizontalSizeClass)
                    || DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
                    ? .leading
                    : .center
            )
            #else
            TitleArtView(item: item)
            #endif
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// A landscape phone: title art and the actions share one row over the
    /// poster's lower part, and everything else follows below the fold.
    private var usesLandscapeRow: Bool {
        DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
    }

    /// A regular-width iPad window gets the TV's composition: a leading
    /// information column beside the artwork. A phone keeps one full-width
    /// column with the title and facts centred over the poster hero.
    private var usesLeadingColumn: Bool {
        DetailLayout.usesLeadingColumn(horizontalSizeClass)
    }

    private var compactAlignment: Alignment {
        usesLeadingColumn || usesLandscapeRow ? .leading : .center
    }

    private var flowAlignment: HorizontalAlignment {
        usesLeadingColumn || usesLandscapeRow ? .leading : .center
    }
    #endif

    private var stackAlignment: HorizontalAlignment {
        #if os(tvOS)
        .leading
        #else
        flowAlignment
        #endif
    }

    var body: some View {
        VStack(alignment: stackAlignment, spacing: Metrics.detailHeaderSpacing) {
            #if os(tvOS)
            title
            subtitleView
            facts
            supportingFacts
            overviewView
            buttons
                .padding(.top, Metrics.Space.xs)
            #else
            // Touch order (HEL-169): the decision first. Title, facts and
            // the actions form one block over the artwork, and the synopsis
            // follows in full below it; a synopsis you have to expand was
            // the one thing every viewer tapped and nobody wanted to. The
            // stack's own alignment centres the block on a phone, so an
            // absent row costs nothing and every client of this header,
            // Seerr and collections included, gets the same composition.
            if usesLandscapeRow {
                HStack(alignment: .center, spacing: Metrics.Space.xl) {
                    title
                    Spacer(minLength: Metrics.Space.l)
                    buttons
                }
                subtitleView
                facts
                supportingFacts
            } else {
                title
                    .frame(maxWidth: .infinity, alignment: compactAlignment)
                subtitleView
                    .multilineTextAlignment(usesLeadingColumn ? .leading : .center)
                facts
                supportingFacts
                buttons
                    .frame(maxWidth: .infinity, alignment: compactAlignment)
                    .padding(.top, Metrics.Space.s)
            }
            overviewView
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Metrics.Space.s)
            #endif
        }
        #if os(iOS)
        // Let SwiftUI size the glass labels, circles and hit areas together.
        // This also covers the synopsis button in the header.
        .controlSize(.large)
        .frame(
            maxWidth: usesLeadingColumn ? Metrics.expandedDetailColumnWidth : .infinity,
            alignment: .leading
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        #endif
        .padding(.horizontal, Metrics.screenGutter)
    }

    @ViewBuilder
    private var subtitleView: some View {
        if let subtitle, !subtitle.isEmpty {
            Text(subtitle)
                .font(.title3.weight(.semibold))
                #if os(tvOS)
                .lineLimit(1)
                #else
                .fixedSize(horizontal: false, vertical: true)
                #endif
        }
    }

    @ViewBuilder
    private var overviewView: some View {
        if let overview, !overview.isEmpty {
            DetailOverview(text: overview)
        }
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
                MetadataFlowLayout(alignment: flowAlignment) {
                    primaryFactViews
                }
            }
            if !qualityTokens.isEmpty {
                MetadataFlowLayout(alignment: flowAlignment) {
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
            MetadataFlowLayout(spacing: Metrics.Space.l, alignment: flowAlignment) {
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

/// The synopsis. Three lines at 10 feet, where the page is a glance and the
/// rest of the block has to fit beside the artwork; the whole text on touch,
/// where the page scrolls and an expand button only stood between the viewer
/// and the paragraph they had already started reading (HEL-169).
private struct DetailOverview: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            #if os(tvOS)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            #else
            .foregroundStyle(.primary)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1000, alignment: .leading)
            .accessibilityIdentifier("detail.overview")
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
    /// Where the art sits in its box, and how a wrapped title is set:
    /// centred under the phone's poster hero, leading everywhere else.
    var alignment: HorizontalAlignment = .leading

    @Environment(SessionStore.self) private var session

    var body: some View {
        TitleArtImage(
            url: session.client.imageURL(for: item, kind: .logo, maxWidth: Int(Metrics.logoMaxWidth * 2)),
            title: item.name ?? "",
            maxHeight: maxHeight,
            alignment: alignment
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
    var alignment: HorizontalAlignment = .leading

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
            .frame(maxWidth: Metrics.logoMaxWidth, maxHeight: maxHeight, alignment: Alignment(horizontal: alignment, vertical: .center))
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
            .multilineTextAlignment(alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
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
