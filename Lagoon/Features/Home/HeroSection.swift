import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What the hero needs of a title, independent of where the title came from.
///
/// Home builds these from Jellyfin items and Discover from Seerr results;
/// `route` is generic so each keeps its own navigation identity
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

/// Contained hero panel with native touch paging and tvOS remote commands.
/// Auto-advances every 7s while visible and idle; manual selection keeps the
/// whole banner's detail link and native tvOS focus treatment intact.
struct HeroSection<Route: Hashable>: View {
    let items: [HeroItem<Route>]
    let isActive: Bool
    let focus: FocusState<Bool>.Binding?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @ScaledMetric(relativeTo: .callout) private var textHeight = Metrics.heroHeight / 2

    #if os(iOS)
    private var usesExpandedLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }
    #endif

    private var panelHeight: CGFloat {
        #if os(tvOS)
        Metrics.heroHeight
        #else
        let baseHeight = usesExpandedLayout
            ? Metrics.expandedHeroHeight
            : Metrics.heroHeight
        return max(baseHeight, textHeight + Metrics.heroLogoHeight + Metrics.Space.xxl)
        #endif
    }

    private var textColumnWidth: CGFloat {
        #if os(tvOS)
        Metrics.heroTextWidth
        #else
        usesExpandedLayout ? Metrics.expandedHeroTextWidth : Metrics.heroTextWidth
        #endif
    }

    @State private var selection = HeroCarouselSelection()
    @State private var palette: ArtworkPalette?
    @State private var isVisible = false
    @State private var isScrolling = false
    @FocusState private var fallbackFocus: Bool

    init(
        items: [HeroItem<Route>],
        isActive: Bool,
        focus: FocusState<Bool>.Binding? = nil
    ) {
        self.items = items
        self.isActive = isActive
        self.focus = focus
    }

    private var current: HeroItem<Route>? {
        let id = selection.currentID(in: itemIDs)
        return items.first { $0.id == id }
    }

    private var itemIDs: [String] { items.map(\.id) }

    private var index: Int {
        itemIDs.firstIndex(of: current?.id ?? "") ?? 0
    }

    private var canCycle: Bool {
        isActive && isVisible && scenePhase == .active && items.count > 1
            && !reduceMotion && !voiceOverEnabled && !isScrolling
            && !(focus ?? $fallbackFocus).wrappedValue
    }

    private struct CycleID: Equatable {
        let items: [String]
        let selectedID: String?
        let canCycle: Bool
    }

    var body: some View {
        Group {
            if let current {
                GeometryReader { proxy in
                    heroBody(for: current, width: proxy.size.width)
                }
                .frame(height: panelHeight)
                .padding(.horizontal, Metrics.screenGutter)
                .onScrollVisibilityChange { isVisible = $0 }
                .onDisappear { isVisible = false }
                .task(id: CycleID(items: itemIDs, selectedID: current.id, canCycle: canCycle)) {
                    await cycle()
                }
                .task(id: current.backdropURL) {
                    await updatePalette()
                    await warmAdjacentArtwork()
                }
            }
        }
        // Run even for an empty result, so a later load cannot resurrect a
        // stale selection. Keeping the same ID preserves it across reorders.
        .onChange(of: itemIDs, initial: true) { _, ids in
            selection.reconcile(with: ids)
        }
    }

    private func heroBody(for current: HeroItem<Route>, width: CGFloat) -> some View {
        // Resolved here, in the body, so a theme change re-renders the glow
        // whether or not an artwork palette is sampled.
        let glowPalette = Theme.glow(for: palette)
        return ZStack {
            AmbientGlowView(palette: glowPalette)
                // Negative gutter: the glow is meant to bleed past the
                // hero panel rather than sit inside it.
                .padding(-Metrics.screenGutter)

            #if os(tvOS)
            // Keep one native card mounted while its label changes, so
            // directional paging never recreates the focused control.
            heroLink(for: current, width: width)
                .focused(focus ?? $fallbackFocus)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: move(by: -1)
                    case .right: move(by: 1)
                    default: break
                    }
                }
            #else
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        heroLink(for: item, width: width)
                            .accessibilityHidden(item.id != current.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: Binding(
                get: { selection.currentID(in: itemIDs) },
                set: { selection.select($0, in: itemIDs) }
            ))
            .scrollDisabled(items.count < 2)
            .onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.heroCornerRadius))
            .overlay(alignment: .bottom) {
                dots.padding(.bottom, Metrics.Space.l)
                    .allowsHitTesting(false)
            }
            #endif
        }
    }

    private func heroLink(for item: HeroItem<Route>, width: CGFloat) -> some View {
        NavigationLink(value: item.route) {
            panel(for: item, width: width)
        }
        .cardButtonStyle()
        .accessibilityLabel(item.title)
        .accessibilityValue(Text("Slide \((itemIDs.firstIndex(of: item.id) ?? 0) + 1) of \(items.count)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(by: 1)
            case .decrement: move(by: -1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("home.hero.\(item.id)")
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
                #if os(tvOS)
                .id(item.id)
                .transition(reduceMotion ? .identity : .opacity)
                #endif

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
                #if os(tvOS)
                .id(item.id)
                // The button stays outside this transitioning subtree so focus
                // survives slide changes; a plain crossfade double-exposes text.
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.3).delay(0.3)),
                    removal: .opacity.animation(.easeOut(duration: 0.2))
                ))
                #endif
            }
            // Card button labels receive an unbounded width. Keep the text
            // inside the panel, and cap its line length on iPad and tvOS.
            .frame(maxWidth: max(0, min(textColumnWidth, width - Metrics.heroTextInset * 2)), alignment: .leading)
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
        .clipShape(RoundedRectangle(cornerRadius: Metrics.heroCornerRadius))
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
            .init(color: Theme.background.opacity(0.85), location: 0),
            .init(color: Theme.background.opacity(0.55), location: 0.35),
            .init(color: .clear, location: 0.72),
        ]
        #else
        [
            .init(color: Theme.background.opacity(0.8), location: 0),
            .init(color: Theme.background.opacity(0.7), location: 0.5),
            .init(color: Theme.background.opacity(0.6), location: 1),
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

    private func move(by offset: Int) {
        guard items.count > 1 else { return }
        let next = selection.adjacentID(offset: offset, in: itemIDs)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.crossfade)) {
            selection.select(next, in: itemIDs)
        }
    }

    private func cycle() async {
        guard canCycle else { return }
        // Selection and interaction are part of this task's identity. A swipe
        // cancels the pending advance and gives the new slide a full interval.
        do {
            try await Task.sleep(for: .seconds(7))
        } catch {
            return
        }
        guard !Task.isCancelled, canCycle,
              let nextID = selection.adjacentID(offset: 1, in: itemIDs),
              let next = items.first(where: { $0.id == nextID }) else { return }
        if let url = next.backdropURL {
            _ = await ImageCache.shared.load(url, maxPixelSize: 1920)
            guard !Task.isCancelled else { return }
            _ = await ArtworkPaletteCache.shared.palette(for: url)
        }
        guard !Task.isCancelled, canCycle else { return }
        move(by: 1)
    }

    private func updatePalette() async {
        guard let url = current?.backdropURL else {
            palette = nil
            return
        }
        let nextPalette = await ArtworkPaletteCache.shared.palette(for: url)
        guard !Task.isCancelled, current?.backdropURL == url else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: Motion.crossfade)) {
            palette = nextPalette
        }
    }

    private func warmAdjacentArtwork() async {
        guard items.count > 1 else { return }
        for offset in [1, -1] {
            guard !Task.isCancelled else { return }
            let id = selection.adjacentID(offset: offset, in: itemIDs)
            guard let url = items.first(where: { $0.id == id })?.backdropURL else { continue }
            _ = await ImageCache.shared.load(url, maxPixelSize: 1920)
            guard !Task.isCancelled else { return }
            _ = await ArtworkPaletteCache.shared.palette(for: url)
        }
    }
}
