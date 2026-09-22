import Foundation
import LagoonEngine
import ImageIO
import UIKit

/// Downsampling image loader with an in-memory cache.
///
/// Decodes off-main to `maxPixelSize` and force-decodes, so scrolling never
/// stalls on JPEG work. Concurrent loads of a key are coalesced.
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
    private var inFlight: [String: Load] = [:]
    private let downloader: BoundedDownload

    init(downloader: BoundedDownload = .shared) { self.downloader = downloader }

    /// `String`, not `NSString`: the off-main cancellation handler carries it.
    private func key(_ url: URL, maxPixelSize: Int) -> String {
        "\(url.absoluteString)::w\(maxPixelSize)"
    }

    /// Synchronous memory-cache probe, so views skip the placeholder. Disk
    /// artwork goes through `load` for its off-main decode.
    func image(for url: URL, maxPixelSize: Int) -> UIImage? {
        let key = key(url, maxPixelSize: maxPixelSize)
        return cache.object(forKey: key as NSString)
    }

    #if os(iOS)
    /// A downloaded title's artwork from disk, decoded off-main like a
    /// network fetch.
    private func localImage(for url: URL, maxPixelSize: Int) async -> UIImage? {
        guard let fileURL = DownloadStore.localArtworkURL(matching: url) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return ArtworkDecoder.image(from: data, maxPixelSize: maxPixelSize)
        }.value
    }
    #endif

    func load(_ url: URL, maxPixelSize: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = key(url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        #if os(iOS)
        if let local = await localImage(for: url, maxPixelSize: maxPixelSize) {
            let cost = Int(local.size.width * local.size.height * local.scale * local.scale * 4)
            cache.setObject(local, forKey: key as NSString, cost: cost)
            return local
        }
        #endif
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

    private func cancel(key: String, waiter: UUID) {
        guard let continuation = inFlight[key]?.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        if inFlight[key]?.waiters.isEmpty == true {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func finish(key: String, id: UUID, image: UIImage?) {
        guard let load = inFlight[key], load.id == id else { return }
        inFlight.removeValue(forKey: key)
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
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
