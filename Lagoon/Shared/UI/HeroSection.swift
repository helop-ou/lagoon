import SwiftUI

/// What the hero needs of a title, from Jellyfin (Home) or Seerr (Discover).
/// `route` is generic so each keeps its own navigation identity. Seerr has no
/// logos, age ratings or progress, so those stay nil there and the title is
/// set in type.
nonisolated struct HeroItem<Route: Hashable>: Identifiable {
    let id: String
    let title: String
    let overview: String?
    let backdropURL: URL?
    let logoURL: URL?
    let route: Route
    /// The info line under the title, joined with dots.
    var facts: [String] = []
    var ageRating: String?
    /// Out of ten.
    var starRating: Double?
    var progress: Double?
    var timeRemaining: String?
}

extension MediaItem {
    /// "S2 E5 · Episode title" for an episode, else the year, up to two
    /// genres and a film's runtime.
    var heroFacts: [String] {
        if type == .episode {
            return [episodeLabel, name].compactMap(\.self)
        }
        var facts = productionYear.map { [String($0)] } ?? []
        facts += (genres ?? []).prefix(2)
        if type != .series, let runtimeLabel {
            facts.append(runtimeLabel)
        }
        return facts
    }
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @ScaledMetric(relativeTo: .callout) private var textHeight = Metrics.heroHeight / 2

    #if os(iOS)
    private var usesExpandedLayout: Bool {
        DetailLayout.usesLeadingColumn(horizontalSizeClass, verticalSizeClass)
    }
    #endif

    /// The phone layout: smaller type, a wash only under the text and the
    /// page dots below the card, so the artwork carries the banner.
    private var isCompact: Bool {
        #if os(iOS)
        !usesExpandedLayout
        #else
        false
        #endif
    }

    private var showsDotsBelowCard: Bool { isCompact && items.count > 1 }

    private var logoBox: CGSize {
        #if os(iOS)
        if isCompact {
            return CGSize(width: Metrics.compactHeroLogoWidth, height: Metrics.compactHeroLogoHeight)
        }
        #endif
        return CGSize(width: Metrics.logoMaxWidth, height: Metrics.heroLogoHeight)
    }

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
        HeroAutoAdvance(
            isActive: isActive,
            isVisible: isVisible,
            isSceneActive: scenePhase == .active,
            itemCount: items.count,
            reduceMotion: reduceMotion,
            voiceOverEnabled: voiceOverEnabled,
            isScrolling: isScrolling,
            isFocused: (focus ?? $fallbackFocus).wrappedValue
        ).isAllowed
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
                .frame(height: panelHeight + (showsDotsBelowCard ? Metrics.Space.l + Metrics.heroDotSize : 0))
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
            VStack(spacing: Metrics.Space.l) {
                carousel(current: current, width: width)
                if showsDotsBelowCard {
                    dots
                }
            }
            #endif
        }
    }

    #if os(iOS)
    private func carousel(current: HeroItem<Route>, width: CGFloat) -> some View {
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
                if !showsDotsBelowCard {
                    dots.padding(.bottom, Metrics.Space.l)
                        .allowsHitTesting(false)
                }
            }
    }
    #endif

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
            // can animate. Without it the picture just cuts.
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
                        maxWidth: logoBox.width,
                        maxHeight: logoBox.height,
                        titleFont: isCompact ? .title2.bold() : .largeTitle.bold()
                    )
                    #if os(iOS)
                    .lineLimit(2)
                    #endif
                    HeroDetails(item: item, isCompact: isCompact)
                }
                // The lighter phone wash leaves bright artwork under the title.
                .shadow(
                    color: .black.opacity(isCompact ? Metrics.artworkTitleShadowOpacity : 0),
                    radius: Metrics.artworkTitleShadowRadius
                )
                #if os(tvOS)
                .id(item.id)
                // The button stays outside this transitioning subtree so focus
                // survives slide changes. A plain crossfade double-exposes text.
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: Motion.heroTextIn).delay(Motion.heroTextIn)),
                    removal: .opacity.animation(.easeOut(duration: Motion.fast))
                ))
                #endif
            }
            // Card button labels get unbounded width. Keep text in the panel.
            .frame(maxWidth: max(0, min(textColumnWidth, width - Metrics.heroTextInset * 2)), alignment: .leading)
            .padding(.leading, Metrics.heroTextInset)
            #if os(iOS)
            // Text sits low, above the page dots unless they sit below the card.
            .frame(maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, showsDotsBelowCard ? Metrics.Space.xl : Metrics.Space.xxl)
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

    /// tvOS darkens only the text column. The wide layout's text spans the
    /// width, so its wash does too. On a phone the text sits at the bottom,
    /// so only the bottom darkens.
    private var wash: LinearGradient {
        #if os(tvOS)
        LinearGradient(stops: [
            .init(color: Theme.background.opacity(0.85), location: 0),
            .init(color: Theme.background.opacity(0.55), location: 0.35),
            .init(color: .clear, location: 0.72),
        ], startPoint: .leading, endPoint: .trailing)
        #else
        if isCompact {
            LinearGradient(stops: [
                .init(color: .clear, location: 0.15),
                .init(color: Theme.background.opacity(0.6), location: 0.5),
                .init(color: Theme.background.opacity(0.9), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        } else {
            LinearGradient(stops: [
                .init(color: Theme.background.opacity(0.8), location: 0),
                .init(color: Theme.background.opacity(0.7), location: 0.5),
                .init(color: Theme.background.opacity(0.6), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
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
        .overlay(wash)
    }

    @ViewBuilder
    private var dots: some View {
        if items.count > 1 {
            HStack(spacing: Metrics.Space.s) {
                ForEach(items.indices, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? Theme.signal : Color.white.opacity(0.35))
                        .frame(width: dot == index ? Metrics.heroActiveDotWidth : Metrics.heroDotSize, height: Metrics.heroDotSize)
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

/// Under the title: the info line, on Apple TV the synopsis, the ratings,
/// and a started title's progress. Phones leave the synopsis to the detail
/// page.
private struct HeroDetails<Route: Hashable>: View {
    let item: HeroItem<Route>
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? Metrics.Space.s : Metrics.Space.m) {
            if !item.facts.isEmpty {
                Text(item.facts.joined(separator: " · "))
                    .lineLimit(1)
            }
            #if os(tvOS)
            if let overview = item.overview {
                Text(overview)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
            if item.ageRating != nil || item.starRating != nil {
                HStack(spacing: isCompact ? Metrics.Space.m : Metrics.Space.l) {
                    if let ageRating = item.ageRating {
                        OfficialRatingBadge(rating: ageRating)
                    }
                    if let starRating = item.starRating {
                        Text(CommunityRatingLabel.text(starRating))
                    }
                }
            }
            if let progress = item.progress {
                HStack(spacing: Metrics.Space.m) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: Metrics.heroProgressWidth * progress)
                        }
                        .frame(
                            width: Metrics.heroProgressWidth,
                            height: isCompact ? Metrics.progressBarHeight / 2 : Metrics.progressBarHeight
                        )
                    if let timeRemaining = item.timeRemaining {
                        Text(timeRemaining)
                    }
                }
            }
        }
        .font(isCompact ? .footnote : .callout)
    }
}
