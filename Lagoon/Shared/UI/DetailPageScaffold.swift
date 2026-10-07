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
        CachedAsyncImage(url: url, maxPixelSize: Metrics.detailBackdropDecodeSize) { image in
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
