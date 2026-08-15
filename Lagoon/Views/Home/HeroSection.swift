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
                    .padding(-80)
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
                .frame(maxWidth: .infinity, alignment: .trailing)

            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.name ?? "")
                        .font(.title.bold())
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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
            .padding(.leading, 56)
        }
        .frame(height: Metrics.heroHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .overlay(alignment: .bottomLeading) {
            dots.padding(.leading, 56).padding(.bottom, 24)
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
        .frame(width: Metrics.heroHeight * 16 / 9 * 1.3, height: Metrics.heroHeight)
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.35),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .animation(.easeInOut(duration: Motion.crossfade), value: item.id)
    }

    @ViewBuilder
    private var dots: some View {
        if items.count > 1 {
            HStack(spacing: 10) {
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
