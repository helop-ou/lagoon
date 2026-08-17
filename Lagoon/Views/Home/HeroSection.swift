import SwiftUI

/// Contained hero panel: material base, backdrop masked into it from the
/// trailing edge, ambient glow bleeding out behind. Auto-advances every 7s,
/// pre-warming the next backdrop and palette so the crossfade never lands
/// on an empty texture.
struct HeroSection: View {
    let items: [MediaItem]
    @Environment(SessionStore.self) private var session

    @State private var index = 0
    @State private var palette: ArtworkPalette = .fallback

    private var current: MediaItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        if let current {
            ZStack {
                AmbientGlowView(palette: palette)
                    // Negative gutter: the glow is meant to bleed past the
                    // hero panel rather than sit inside it.
                    .padding(-Metrics.screenGutter)
                panel(for: current)
            }
            .frame(height: Metrics.heroHeight)
            .padding(.horizontal, Metrics.screenGutter)
            .task(id: items.first?.id) {
                await cycle()
            }
        }
    }

    private func panel(for item: MediaItem) -> some View {
        ZStack(alignment: .leading) {
            Color.clear.background(.thinMaterial)

            backdrop(for: item)

            VStack(alignment: .leading, spacing: Metrics.Space.xl) {
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    TitleArtView(item: item, maxHeight: Metrics.heroLogoHeight)
                    if let overview = item.overview {
                        Text(overview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                }
                .id(item.id)
                // The button stays outside this transitioning subtree so focus
                // survives slide changes; a plain crossfade double-exposes text.
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeIn(duration: 0.3).delay(0.3)),
                    removal: .opacity.animation(.easeOut(duration: 0.2))
                ))

                NavigationLink(value: item) {
                    Label("See more", systemImage: "info.circle")
                }
                .buttonStyle(.glass)
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.leading, Metrics.Space.section)
        }
        .frame(height: Metrics.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .overlay(alignment: .bottomLeading) {
            dots.padding(.leading, Metrics.Space.section).padding(.bottom, Metrics.Space.xl)
        }
    }

    private func backdrop(for item: MediaItem) -> some View {
        CachedAsyncImage(
            url: backdropURL(for: item),
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
                stops: [
                    .init(color: .black.opacity(0.85), location: 0),
                    .init(color: .black.opacity(0.55), location: 0.35),
                    .init(color: .clear, location: 0.72),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .animation(.easeInOut(duration: Motion.crossfade), value: item.id)
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
            .animation(.easeInOut(duration: Motion.fast), value: index)
            .accessibilityHidden(true)
        }
    }

    private func backdropURL(for item: MediaItem) -> URL? {
        session.client.imageURL(for: item, kind: .backdrop, maxWidth: 1920)
    }

    private func cycle() async {
        index = 0
        await updatePalette()
        guard items.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(7))
            if Task.isCancelled { return }
            let next = (index + 1) % items.count
            if let url = backdropURL(for: items[next]) {
                _ = await ImageCache.shared.load(url, maxPixelSize: 1920)
                _ = await ArtworkPaletteCache.shared.palette(for: url)
            }
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: Motion.slow)) {
                index = next
            }
            await updatePalette()
        }
    }

    private func updatePalette() async {
        guard let item = current, let url = backdropURL(for: item) else {
            palette = .fallback
            return
        }
        palette = await ArtworkPaletteCache.shared.palette(for: url)
    }
}
