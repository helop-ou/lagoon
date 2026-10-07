import SwiftUI

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
            .frame(maxWidth: Metrics.detailOverviewWidth, alignment: .leading)
            .accessibilityIdentifier("detail.overview")
    }
}
