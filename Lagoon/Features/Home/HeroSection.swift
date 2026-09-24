import SwiftUI
#if os(iOS)
import UIKit
#endif

/// What the hero needs of a title, from Jellyfin (Home) or Seerr (Discover).
/// `route` is generic so each keeps its own navigation identity. Seerr has no
/// logos, so `logoURL` is nil there and the title is set in type.
nonisolated struct HeroItem<Route: Hashable>: Identifiable {
    let id: String
    let title: String
    let overview: String?
    let backdropURL: URL?
    let logoURL: URL?
    let route: Route
}

/// Hero panel with touch paging on iOS and remote paging on tvOS.
/// Auto-advances every 7s while visible, idle and unfocused.
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
        // Runs even when empty, so a later load cannot restore a stale
        // selection. The same id survives reorders.
        .onChange(of: itemIDs, initial: true) { _, ids in
            selection.reconcile(with: ids)
        }
    }

    private func heroBody(for current: HeroItem<Route>, width: CGFloat) -> some View {
        // Resolved in the body so a theme change re-renders the glow.
        let glowPalette = Theme.glow(for: palette)
        return ZStack {
            AmbientGlowView(palette: glowPalette)
                // The glow bleeds past the panel.
                .padding(-Metrics.screenGutter)

            #if os(tvOS)
            // One card stays mounted while its label changes, so paging
            // never recreates the focused control.
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

            // `.id` per item makes a slide change an insertion the crossfade
            // can animate; without it the picture just cuts.
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
            // Card button labels get unbounded width; keep text in the panel.
            .frame(maxWidth: max(0, min(textColumnWidth, width - Metrics.heroTextInset * 2)), alignment: .leading)
            .padding(.leading, Metrics.heroTextInset)
            #if os(iOS)
            // Text sits low, above a strip for the page dots.
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

    /// tvOS darkens only the text column; on a phone the text spans the full
    /// width, so the wash does too.
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
            maxPixelSize: Metrics.detailBackdropDecodeSize
        ) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.clear
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
        // A swipe changes the task id, so the new slide gets a full interval.
        do {
            try await Task.sleep(for: .seconds(7))
        } catch {
            return
        }
        guard !Task.isCancelled, canCycle,
              let nextID = selection.adjacentID(offset: 1, in: itemIDs),
              let next = items.first(where: { $0.id == nextID }) else { return }
        if let url = next.backdropURL {
            _ = await ImageCache.shared.load(url, maxPixelSize: Metrics.detailBackdropDecodeSize)
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
            _ = await ImageCache.shared.load(url, maxPixelSize: Metrics.detailBackdropDecodeSize)
            guard !Task.isCancelled else { return }
            _ = await ArtworkPaletteCache.shared.palette(for: url)
        }
    }
}
