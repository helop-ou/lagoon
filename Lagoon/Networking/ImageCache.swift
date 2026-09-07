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

    private struct Load {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>]
    }
    private var inFlight: [NSString: Load] = [:]
    private let downloader: BoundedDownload

    init(downloader: BoundedDownload = .shared) { self.downloader = downloader }

    private func key(_ url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)::w\(maxPixelSize)" as NSString
    }

    /// Synchronous probe so views can skip the placeholder for cached images.
    func image(for url: URL, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: key(url, maxPixelSize: maxPixelSize))
    }

    func load(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = key(url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let waiter = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if inFlight[key] != nil {
                    inFlight[key]?.waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                let task = Task { [weak self, downloader] in
                    let data = try? await downloader.data(from: url, limit: DownloadLimit.artwork, content: .image)
                    let image: UIImage?
                    if let data, !Task.isCancelled {
                        image = await Task.detached(priority: .utility) {
                            ArtworkDecoder.image(from: data, maxPixelSize: maxPixelSize)
                        }.value
                    } else { image = nil }
                    self?.finish(key: key, id: id, image: Task.isCancelled ? nil : image)
                }
                inFlight[key] = Load(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key: key, waiter: waiter) }
        }
    }

    private func cancel(key: NSString, waiter: UUID) {
        guard let continuation = inFlight[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if inFlight[key]?.waiters.isEmpty == true {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func finish(key: NSString, id: UUID, image: UIImage?) {
        guard let load = inFlight[key], load.id == id else { return }
        inFlight.removeValue(forKey: key)
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        for waiter in load.waiters.values { waiter.resume(returning: image) }
    }
}

nonisolated enum ArtworkDecoder {
    static func image(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard !data.isEmpty, data.count <= DownloadLimit.artwork, maxPixelSize > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
