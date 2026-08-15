import SwiftUI

/// AsyncImage replacement backed by ImageCache. The synchronous cache probe
/// in init means already-cached artwork renders on first frame — no
/// placeholder flash when scrolling back through rails.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let maxPixelSize: Int
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(
        url: URL?,
        maxPixelSize: Int,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.content = content
        self.placeholder = placeholder
        if let url {
            _image = State(initialValue: ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize))
        }
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
                image = cached
                return
            }
            image = nil
            image = await ImageCache.shared.load(url, maxPixelSize: maxPixelSize)
        }
    }
}
