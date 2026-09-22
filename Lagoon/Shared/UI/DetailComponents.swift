import SwiftUI

/// Full-bleed backdrop behind a detail page, only lightly dimmed. The
/// readability scrim travels with the content block instead.
struct DetailBackdropView: View {
    let url: URL?
    /// Portrait artwork for the compact touch layout, where it replaces the
    /// backdrop as the hero. Regular-width iPad windows keep the backdrop.
    var posterURL: URL? = nil
    /// Set by the scaffold so the content inset and the fade agree.
    var posterHeight: CGFloat = 0
    /// `.top` in portrait: the bottom is lost under the fade anyway.
    /// `.center` in landscape: the whole poster over a blurred copy of itself.
    var posterAnchor: Alignment = .top
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        ZStack {
            Theme.background
            #if os(iOS)
            if usesPosterHero {
                // Pinned to the top of the centred ZStack.
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
            Theme.background
        }
        .animation(.easeInOut(duration: Motion.crossfade), value: url)
    }

    #if os(iOS)
    /// The scaffold passes zero whenever the backdrop should draw.
    private var usesPosterHero: Bool {
        posterURL != nil && posterHeight > 0
    }

    /// The landscape key art in both orientations. The poster only stands
    /// in for a title without a backdrop.
    private var heroURL: URL? { url ?? posterURL }
    private var heroIsPoster: Bool { url == nil }

    private var posterHero: some View {
        GeometryReader { proxy in
            ZStack {
                if heroIsPoster && posterAnchor == .center {
                    // Both layers get the hero's own frame, so the fill's
                    // overflow never becomes the fit's proposal.
                    CachedAsyncImage(url: heroURL, maxPixelSize: Metrics.detailPosterAmbientDecodeSize) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.background
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .blur(radius: Metrics.detailPosterAmbientBlur)
                    .overlay(Theme.background.opacity(0.35))
                    CachedAsyncImage(url: heroURL, maxPixelSize: Metrics.detailPosterDecodeSize) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    // Fill edge to edge. The decode budget follows the image:
                    // the backdrop is requested wider than the poster.
                    CachedAsyncImage(
                        url: heroURL,
                        maxPixelSize: heroIsPoster ? Metrics.detailPosterDecodeSize : Metrics.detailBackdropDecodeSize
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.background
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

    /// Clear at the top, a reading surface where the scaffold puts the
    /// content, and solid where the poster ends.
    private var posterFade: some View {
        let heavy = contrast == .increased || reduceTransparency
        let contentStart = posterAnchor == .top
            ? 1 - Metrics.detailPosterContentOverlap
            : Metrics.detailLandscapeRowShare
        return LinearGradient(
            stops: [
                .init(color: Theme.background.opacity(heavy ? 0.35 : 0), location: 0),
                .init(color: Theme.background.opacity(heavy ? 0.5 : 0.08), location: contentStart * 0.66),
                .init(color: Theme.background.opacity(heavy ? 0.9 : 0.72), location: contentStart),
                .init(color: Theme.background.opacity(heavy ? 1 : 0.94), location: 0.9),
                .init(color: Theme.background, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    #endif

    @ViewBuilder
    private var readabilityWash: some View {
        #if os(tvOS)
        // The layout uses only the leading half; keep the rest vivid.
        ZStack {
            Theme.background.opacity(0.12)
            LinearGradient(
                stops: [
                    .init(color: Theme.background.opacity(0.9), location: 0),
                    .init(color: Theme.background.opacity(0.7), location: 0.3),
                    .init(color: .clear, location: 0.68),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        #else
        let heavy = contrast == .increased || reduceTransparency
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) {
            // Laid out like the TV: a leading fade, plus a bottom fade for
            // the rails that scroll over it.
            ZStack {
                Theme.background.opacity(heavy ? 0.85 : 0.18)
                LinearGradient(
                    stops: [
                        .init(color: Theme.background.opacity(0.85), location: 0),
                        .init(color: Theme.background.opacity(0.55), location: 0.4),
                        .init(color: .clear, location: 0.75),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .clear, location: 0.45),
                        .init(color: Theme.background.opacity(0.85), location: 0.78),
                        .init(color: Theme.background, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        } else {
            // A compact page without a poster hero (Seerr, collections):
            // photographic at the top, near-black before the rails.
            ZStack {
                Theme.background.opacity(heavy ? 0.9 : 0.3)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Theme.background.opacity(0.35), location: 0.3),
                        .init(color: Theme.background.opacity(0.8), location: 0.55),
                        .init(color: Theme.background.opacity(0.95), location: 0.76),
                        .init(color: Theme.background, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        #endif
    }
}

/// The shell both detail pages sit in: full-bleed backdrop with content inset
/// below it.
///
/// The hero space is a **scroll content margin, not a spacer view**. A spacer
/// is non-focusable content above the first button, so Up from Play goes
/// nowhere and the tab bar is unreachable.
///
/// The backdrop does **not** darken on scroll: one focus jump into a rail
/// covers the whole ramp and reads as a slam to black.
struct DetailPageScaffold<Content: View>: View {
    let backdropURL: URL?
    /// Portrait artwork for the compact touch hero; nil keeps the backdrop.
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
                    // A loading rail reports its content's ideal width; without
                    // a fixed width the page grows to it and pushes the
                    // actions off-screen.
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

    /// Portrait: a share of the height (a 2:3 poster capped so the title
    /// stays on-screen). Landscape: the whole window under the safe areas.
    /// Zero for the wide iPad layout, which draws the backdrop.
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

    /// Where the content begins. The poster ignores the safe area and the
    /// scroll view does not, so subtract the safe top.
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
extension VerticalAlignment {
    /// The Resume pill's centre, so the circles sit level with the pill and
    /// not with the pill-and-caption block.
    private enum DetailPillCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    static let detailPillCenter = VerticalAlignment(DetailPillCenter.self)
}

/// A glass circle for the phone's secondary detail actions. Not
/// `.buttonStyle(.glass)`: on iOS 26 its press highlight is a capsule, not
/// the circle.
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

/// `DetailCircleButton` for a menu.
struct DetailCircleMenu<Content: View, Label: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            content
        } label: {
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
    /// Hides the tab bar on touch detail pages; it returns on Back.
    func detailPageChrome() -> some View {
        #if os(iOS)
        toolbarVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Wide (regular-width iPad, laid out like the TV) or compact touch layout.
enum DetailLayout {
    static func usesLeadingColumn(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    /// A landscape phone: title, actions and Play share one row.
    static func usesLandscapeRow(
        _ horizontalSizeClass: UserInterfaceSizeClass?,
        _ verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        !usesLeadingColumn(horizontalSizeClass) && verticalSizeClass == .compact
    }

    static func titleAlignment(
        _ horizontalSizeClass: UserInterfaceSizeClass?,
        _ verticalSizeClass: UserInterfaceSizeClass?
    ) -> HorizontalAlignment {
        usesLeadingColumn(horizontalSizeClass) || usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
            ? .leading
            : .center
    }
}
#endif

/// A detail page's actions, shared by film, series and Seerr pages.
///
/// - tvOS and regular-width iPad: one row, primary first so it takes first
///   focus, accessory beneath.
/// - Landscape phone: secondary, accessory, then primary on one line,
///   aligned on `detailPillCenter`.
/// - Portrait phone: primary alone and wide, the rest in a row beneath.
///
/// The accessory is the series page's season picker.
struct DetailActionLayout<Primary: View, Secondary: View, Accessory: View>: View {
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let accessory: Accessory

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    init(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.primary = primary()
        self.secondary = secondary()
        self.accessory = accessory()
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            HStack(spacing: Metrics.detailActionSpacing) {
                primary
                secondary
            }
            accessory
        }
        #else
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) {
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                AdaptiveActionStack(spacing: Metrics.detailActionSpacing) {
                    primary
                    secondary
                }
                accessory
            }
        } else if DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass) {
            // A plain row: when tight, the title art gives way instead of
            // the accessory wrapping.
            HStack(alignment: .detailPillCenter, spacing: Metrics.detailActionSpacing) {
                secondary
                accessory
                    .fixedSize()
                primary
            }
        } else {
            VStack(spacing: Metrics.Space.m) {
                primary
                AdaptiveActionStack(spacing: Metrics.detailActionSpacing) {
                    secondary
                    accessory
                }
            }
        }
        #endif
    }
}

extension View {
    /// The label of a detail page's hero action (Play, Resume, Request...).
    func detailPrimaryLabel() -> some View {
        modifier(DetailPrimaryLabelModifier())
    }

    func detailPrimaryButton() -> some View {
        #if os(iOS)
        buttonStyle(.glass)
            .controlSize(.extraLarge)
        #else
        buttonStyle(.glass)
        #endif
    }
}

private struct DetailPrimaryLabelModifier: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Uncapped in the wide iPad row.
    private var maxWidth: CGFloat? {
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) { return nil }
        return DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
            ? Metrics.detailLandscapePlayButtonMaxWidth
            : Metrics.detailPlayButtonMaxWidth
    }
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .font(.title3.weight(.semibold))
            // A squeezed Label stacks its icon over its text.
            .fixedSize()
            .frame(maxWidth: maxWidth)
            .padding(.vertical, Metrics.Space.xs)
        #else
        content
        #endif
    }
}

/// Title, metadata, badges, actions and synopsis at the bottom of a detail
/// page's first screen.
struct DetailHeader<Buttons: View>: View {
    let item: MediaItem
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    /// On a series page, the episode Play would start. Its label and synopsis
    /// replace the show's; the title art stays the show's.
    var upNext: MediaItem?
    /// Keep the synopsis's height fixed while `upNext` changes.
    var reservesOverviewLines = false
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
            overview: upNext?.overview ?? item.overview,
            overviewReservesLines: reservesOverviewLines
        ) {
            #if os(iOS)
            TitleArtView(
                item: item,
                alignment: DetailLayout.titleAlignment(horizontalSizeClass, verticalSizeClass)
            )
            #else
            TitleArtView(item: item)
            #endif
        } buttons: {
            buttons
        }
    }

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

    /// Empty until the single-item fetch lands; only it carries MediaSources.
    private var qualityTokens: [String] {
        item.mediaSources?.first?.qualityTokens ?? []
    }
}

/// The detail header shared by Jellyfin and Seerr pages.
struct DetailMetadataHeader<Title: View, Buttons: View>: View {
    let subtitle: String?
    let factTokens: [String]
    let qualityTokens: [String]
    let officialRating: String?
    let genres: [String]
    let communityRating: Double?
    let overview: String?
    let overviewReservesLines: Bool
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
        overviewReservesLines: Bool = false,
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
        self.overviewReservesLines = overviewReservesLines
        self.title = title()
        self.buttons = buttons()
    }

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var usesLandscapeRow: Bool {
        DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
    }

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
            // Touch: title, facts and actions over the artwork, then the
            // full synopsis below (no expand button).
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
        // Sizes the glass labels, circles and hit areas together.
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
            DetailOverview(text: overview, reservesLines: overviewReservesLines)
        } else if overviewReservesLines {
            #if os(tvOS)
            // An episode with no synopsis keeps the block's height, or the
            // page would jump on that one card.
            DetailOverview(text: "", reservesLines: true)
            #endif
        }
    }

    @ViewBuilder
    private var facts: some View {
        #if os(tvOS)
        HStack(spacing: Metrics.Space.l) {
            primaryFactViews
            qualityFactViews
        }
        .font(.callout)
        #else
        // Separate flow rows keep each token whole ("1 h 56 min", "TrueHD 7.1").
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

/// The synopsis: three lines on tvOS, the whole text on touch.
///
/// `reservesLines` keeps three lines of height on tvOS, so a series page's
/// synopsis, which follows the focused episode, does not shift the episode
/// rail below it.
private struct DetailOverview: View {
    let text: String
    var reservesLines = false

    var body: some View {
        Text(text)
            .font(.callout)
            #if os(tvOS)
            .foregroundStyle(.secondary)
            .lineLimit(3, reservesSpace: reservesLines)
            #else
            .foregroundStyle(.primary)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1000, alignment: .leading)
            .accessibilityIdentifier("detail.overview")
    }
}

/// The title as its logo when the server has one, otherwise as type.
struct TitleArtView: View {
    let item: MediaItem
    var maxHeight: CGFloat = Metrics.logoMaxHeight
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

/// `TitleArtView` for sources that resolve their own artwork URL, such as
/// Seerr (which has no logos, so it always shows type).
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
                // Type, not a box: reserving the logo's height leaves a hole.
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

/// One person in the cast strip, from Jellyfin or from Seerr's TMDB credits.
struct CastCredit: Identifiable, Hashable {
    let id: String
    let name: String
    /// The character for actors, the job for crew.
    let credit: String?
    let imageURL: URL?
}

/// Cast strip. Deliberately **not** focusable and not scrolling on tvOS:
/// there is no person screen to open. Focus moving past it scrolls it into
/// view.
struct CastStrip: View {
    private let people: [Person]
    private let credits: [CastCredit]?

    @Environment(SessionStore.self) private var session

    init(people: [Person]) {
        self.people = people
        self.credits = nil
    }

    /// A cast already resolved, for titles not in the library.
    init(credits: [CastCredit]) {
        self.people = []
        self.credits = credits
    }

    /// Drops people with no headshot. Server order is kept.
    private var cast: [CastCredit] {
        if let credits {
            return credits.filter { $0.imageURL != nil }
        }
        return people
            .filter { $0.primaryImageTag != nil }
            .map { person in
                CastCredit(
                    id: person.id,
                    name: person.name ?? "",
                    credit: credit(for: person),
                    imageURL: session.client.personImageURL(for: person, maxWidth: Int(Metrics.castPortraitSize * 2))
                )
            }
    }

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cast and Crew")
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)

                #if os(tvOS)
                // Fixed row: eight fit across the screen.
                HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                    ForEach(cast.prefix(Metrics.castCount)) { member in
                        castMember(member)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.top, Metrics.Space.l)
                #else
                // Touch scrolls without focus, so show everyone.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(cast) { member in
                            castMember(member)
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

    private func castMember(_ member: CastCredit) -> some View {
        VStack(spacing: Metrics.Space.s) {
            CachedAsyncImage(
                url: member.imageURL,
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
                Text(member.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let credit = member.credit {
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
