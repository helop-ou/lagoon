import SwiftUI

/// AsyncImage replacement backed by ImageCache. The synchronous cache probe
/// in init renders cached artwork on the first frame, with no placeholder
/// flash.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let maxPixelSize: Int
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    private struct Request: Hashable {
        let url: URL?
        let maxPixelSize: Int
    }

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
        .task(id: Request(url: url, maxPixelSize: maxPixelSize)) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImageCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
                image = cached
                return
            }
            image = nil
            let loaded = await ImageCache.shared.load(url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
