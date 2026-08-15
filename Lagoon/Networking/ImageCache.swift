import Foundation
import ImageIO
import UIKit

/// Downsampling image loader with an in-memory cache.
///
/// Decodes off-main via CGImageSource with a thumbnail max pixel size, so a
/// 4K backdrop never reaches the render thread at full resolution, and
/// force-decodes (`ShouldCacheImmediately`) so scrolling never stalls on
/// JPEG decompression. Concurrent loads of the same key are coalesced.
final class ImageCache {
    static let shared = ImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    private var inFlight: [NSString: Task<UIImage?, Never>] = [:]

    private init() {}

    private func key(_ url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)::w\(maxPixelSize)" as NSString
    }

    /// Synchronous probe so views can skip the placeholder for cached images.
    func image(for url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: key(url, maxPixelSize: maxPixelSize))
    }

    func load(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = key(url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return await Self.decode(data, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: Int) async -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
