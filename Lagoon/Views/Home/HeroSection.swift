import SwiftUI

/// What the hero needs of a title, independent of where the title came from.
///
/// Home builds these from Jellyfin items and Discover from Seerr results
/// (HEL-114); `route` is generic so each keeps its own navigation identity
/// rather than both being flattened into one erased value. Seerr has no logo
/// artwork anywhere in its API, so `logoURL` is nil there and the panel falls
/// back to the title in type — the same fallback `TitleArtView` already makes
/// for a Jellyfin item without a logo.
nonisolated struct HeroItem<Route: Hashable>: Identifiable {
    let id: String
    let title: String
    let overview: String?
    let backdropURL: URL?
    let logoURL: URL?
    let route: Route
}

/// Contained hero panel: material base, backdrop masked into it from the
/// trailing edge, ambient glow bleeding out behind. Auto-advances every 7s,
/// pre-warming the next backdrop and palette so the crossfade never lands
/// on an empty texture.
struct HeroSection<Route: Hashable>: View {
    let items: [HeroItem<Route>]
    let focus: FocusState<Bool>.Binding?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .callout) private var textHeight = Metrics.heroHeight / 2

    private var panelHeight: CGFloat {
        #if os(tvOS)
        Metrics.heroHeight
        #else
        max(Metrics.heroHeight, textHeight + Metrics.heroLogoHeight + Metrics.Space.xxl)
        #endif
    }

    @State private var index = 0
    @State private var palette: ArtworkPalette = .fallback
    @FocusState private var fallbackFocus: Bool

    init(
        items: [HeroItem<Route>],
        focus: FocusState<Bool>.Binding? = nil
    ) {
        self.items = items
        self.focus = focus
    }

    private var current: HeroItem<Route>? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        if let current {
            GeometryReader { proxy in
                heroBody(for: current, width: proxy.size.width)
            }
            .frame(height: panelHeight)
            .padding(.horizontal, Metrics.screenGutter)
            .task(id: "\(items.first?.id ?? "empty"):\(reduceMotion)") {
                await cycle()
            }
        }
    }

    private func heroBody(for current: HeroItem<Route>, width: CGFloat) -> some View {
        ZStack {
            AmbientGlowView(palette: palette)
                // Negative gutter: the glow is meant to bleed past the
                // hero panel rather than sit inside it.
                .padding(-Metrics.screenGutter)

            // The whole banner is the target (Jaagop): focus it, click it,
            // and you get the detail page for whatever is on screen. A
            // "See more" button inside it was a second thing to aim at for
            // the one thing the banner already means.
            NavigationLink(value: current.route) {
                panel(for: current, width: width)
            }
            .cardButtonStyle()
            .focused(focus ?? $fallbackFocus)
            .accessibilityLabel(current.title)
            .accessibilityIdentifier("home.hero.\(current.id)")
        }
    }

    private func panel(for item: HeroItem<Route>, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.background(.thinMaterial)

            // Identity per item, so a slide change is an insertion the
            // crossfade can animate. Without the `.id`, SwiftUI keeps one
            // image view and swaps its contents — nothing animatable happens
            // and the picture just cuts, which is what `Motion.crossfade`
            // below was silently failing to do (Jaagop).
            backdrop(for: item)
                .frame(width: width, height: panelHeight)
                .id(item.id)
                .transition(.opacity)

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    TitleArtImage(
                        url: item.logoURL,
                        title: item.title,
                        maxHeight: Metrics.heroLogoHeight
                    )
                    #if os(iOS)
                    .lineLimit(2)
                    #endif
                    if let overview = item.overview {
                        Text(overview)
                            .font(.callout)
                            #if os(tvOS)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            #else
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            #endif
                    }
                }
                .id(item.id)
                // The button stays outside this transitioning subtree so focus
                // survives slide changes; a plain crossfade double-exposes text.
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.3).delay(0.3)),
                    removal: .opacity.animation(.easeOut(duration: 0.2))
                ))
            }
            // Bounded by the width actually available, not by a constant.
            // The card button style proposes an *unbounded* width to its
            // label, so the panel grew past the screen and a `.infinity` text
            // column grew with it — which is why the synopsis kept running
            // off the right edge on a phone however the padding was arranged
            // (HEL-41). tvOS lands on its usual 640 because that's the
            // smaller of the two.
            .frame(maxWidth: max(0, min(Metrics.heroTextWidth, width - Metrics.heroTextInset * 2)), alignment: .leading)
            .padding(.leading, Metrics.heroTextInset)
            #if os(iOS)
            // Anchor the copy low in the shorter banner, leaving artwork
            // above and a dedicated strip below for the page indicator.
            .frame(maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, Metrics.Space.xxl)
            #endif
        }
        .frame(width: width, height: panelHeight)
        #if os(iOS)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .overlay(alignment: .bottom) {
            dots.padding(.bottom, Metrics.Space.l)
        }
        #else
        .overlay(alignment: .bottomLeading) {
            dots.padding(.leading, Metrics.Space.section).padding(.bottom, Metrics.Space.xl)
        }
        #endif
    }

    /// tvOS darkens only the left column the text occupies and leaves the
    /// rest of the still vivid. On a phone the text spans the full width, so
    /// the wash has to as well — it just never gets as heavy on the right.
    private static var washStops: [Gradient.Stop] {
        #if os(tvOS)
        [
            .init(color: .black.opacity(0.85), location: 0),
            .init(color: .black.opacity(0.55), location: 0.35),
            .init(color: .clear, location: 0.72),
        ]
        #else
        [
            .init(color: .black.opacity(0.8), location: 0),
            .init(color: .black.opacity(0.7), location: 0.5),
            .init(color: .black.opacity(0.6), location: 1),
        ]
        #endif
    }

    private func backdrop(for item: HeroItem<Route>) -> some View {
        CachedAsyncImage(
            url: item.backdropURL,
            maxPixelSize: 1920
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.clear
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // The artwork now runs the full width of the panel. What used to be
        // here was a *mask* fading its leading third into flat material, which
        // read as a grey wash over a third of the image (Jaagop). What's left
        // is the detail page's answer instead: darken only the column the
        // text occupies, and let the rest of the still be itself.
        .overlay(
            LinearGradient(
                stops: Self.washStops,
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    @ViewBuilder
    private var dots: some View {
        if items.count > 1 {
            HStack(spacing: Metrics.Space.s) {
                ForEach(items.indices, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? Color.white : Color.white.opacity(0.35))
                        .frame(width: dot == index ? 24 : 8, height: 8)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: Motion.fast), value: index)
            .accessibilityHidden(true)
        }
    }

    private func cycle() async {
        index = 0
        await updatePalette()
        // A carousel that moves without input is exactly the kind of
        // nonessential spatial motion Reduce Motion is intended to stop.
        // Keep the first recommendation available and fully interactive.
        guard !reduceMotion, items.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(7))
            if Task.isCancelled { return }
            let next = (index + 1) % items.count
            if let url = items[next].backdropURL {
                _ = await ImageCache.shared.load(url, maxPixelSize: 1920)
                _ = await ArtworkPaletteCache.shared.palette(for: url)
            }
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: Motion.crossfade)) {
                index = next
            }
            await updatePalette()
        }
    }

    private func updatePalette() async {
        guard let url = current?.backdropURL else {
            palette = .fallback
            return
        }
        palette = await ArtworkPaletteCache.shared.palette(for: url)
    }
}
