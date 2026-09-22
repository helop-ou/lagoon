import SwiftUI
import UIKit

/// Dominant colors sampled from artwork, driving the hero's ambient glow.
nonisolated struct ArtworkPalette: Equatable {
    let colors: [Color]

    static let fallback = ArtworkPalette(colors: [.lagoonAqua, .lagoonNavy, Color(red: 0.16, green: 0.1, blue: 0.35)])

    /// Pure-Swift 4-bit-per-channel RGB histogram, ranked by
    /// `bucketSize × (saturation + 0.05) × (brightness + 0.1)`. The floors
    /// keep letterbox bars and near-black fills from winning the ranking.
    static func extract(from image: UIImage, colorCount: Int = 3) -> ArtworkPalette {
        guard let cgImage = image.cgImage else { return .fallback }

        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .fallback }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            var bucket = buckets[key] ?? (0, 0, 0, 0)
            bucket = (bucket.count + 1, bucket.r + r, bucket.g + g, bucket.b + b)
            buckets[key] = bucket
        }

        let ranked = buckets.values
            .map { bucket -> (score: Double, color: Color) in
                let r = Double(bucket.r) / Double(bucket.count) / 255
                let g = Double(bucket.g) / Double(bucket.count) / 255
                let b = Double(bucket.b) / Double(bucket.count) / 255
                let maxC = max(r, g, b), minC = min(r, g, b)
                let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
                let score = Double(bucket.count) * (saturation + 0.05) * (maxC + 0.1)
                return (score, Color(red: r, green: g, blue: b))
            }
            .sorted { $0.score > $1.score }
            .prefix(colorCount)
            .map(\.color)

        guard !ranked.isEmpty else { return .fallback }
        return ArtworkPalette(colors: Array(ranked))
    }
}

/// Memoizes palettes per image URL so hero cycling never re-samples.
final class ArtworkPaletteCache {
    static let shared = ArtworkPaletteCache()

    private var palettes: [URL: ArtworkPalette] = [:]
    private var order: [URL] = []
    /// Sized for rail browsing (a palette per focused card); 40 let one
    /// sweep evict the hero's entries.
    private let limit = 160

    private init() {}

    func palette(for url: URL) async -> ArtworkPalette {
        if let cached = palettes[url] {
            return cached
        }
        guard let image = await ImageCache.shared.load(url, maxPixelSize: 120) else {
            return .fallback
        }
        let palette = await Task.detached(priority: .utility) {
            ArtworkPalette.extract(from: image)
        }.value
        palettes[url] = palette
        order.append(url)
        if order.count > limit {
            palettes[order.removeFirst()] = nil
        }
        return palette
    }
}
