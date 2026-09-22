import CoreGraphics
import Foundation
import ImageIO
import LagoonEngine
import Observation

/// Feeds preview frames to the scrub chip.
///
/// Jellyfin trickplay sheets are typically 10×10 grids of 320×180 tiles, one
/// per 10 s, so one sheet covers ~16 minutes and a frame is a crop.
///
/// Not routed through `ImageCache`: a decoded sheet is ~23 MB and would
/// evict the poster cache on the first scrub.
@Observable
@MainActor
final class TrickplayLoader {
    /// The previous frame stays up while the next sheet downloads, so a
    /// scrub stalls the picture rather than blanking it.
    private(set) var frame: CGImage?

    /// Set when promised sheets never arrive, so the chip stops reserving
    /// space for them.
    private(set) var isUnavailable = false

    private let source: TrickplaySource
    /// The trickplay route 401s without the header credential.
    private var authorization: MediaRequestAuthorization? { source.authorization }
    /// Decoded sheets, most-recently-used first.
    private var sheets: [(index: Int, image: CGImage)] = []
    /// Compressed sheets, capped at 32 MiB, so a revisit re-decodes
    /// without downloading.
    private var sheetData: [Int: Data] = [:]
    private var sheetDataOrder: [Int] = []
    private var loading: Set<Int> = []
    @ObservationIgnored private var loadTasks: [Int: Task<Void, Never>] = [:]
    /// Re-checked when a sheet lands; the playhead has usually moved on.
    private var wanted: TrickplayTile?

    /// Two sheets ≈ 46 MB. A third buys almost nothing at 16 minutes each.
    private static let sheetLimit = 2
    private static let rawSheetByteLimit = 32 * 1_024 * 1_024
    /// Caps decode memory. Cropping uses the decoded size, so downscaling
    /// is safe.
    private static let maxSheetPixels = 3200

    init(source: TrickplaySource) {
        self.source = source
    }

    deinit { for task in loadTasks.values { task.cancel() } }

    /// Cheap per drag update: a no-op within one thumbnail's interval.
    func update(to seconds: Double) {
        guard let tile = source.tile(at: seconds), tile != wanted else { return }
        wanted = tile
        if let sheet = sheet(at: tile.sheet) {
            frame = crop(sheet, to: tile)
        } else {
            load(sheet: tile.sheet)
        }
    }

    private func sheet(at index: Int) -> CGImage? {
        guard let position = sheets.firstIndex(where: { $0.index == index }) else { return nil }
        let entry = sheets.remove(at: position)
        sheets.insert(entry, at: 0)
        return entry.image
    }

    private func load(sheet index: Int) {
        guard !loading.contains(index), source.sheetURLs.indices.contains(index) else { return }
        // A rapid scrub crosses many sheets; keep only this transfer.
        for (other, task) in loadTasks where other != index {
            task.cancel()
            loadTasks.removeValue(forKey: other)
            loading.remove(other)
        }
        loading.insert(index)
        let url = source.sheetURLs[index]
        let cached = sheetData[index]
        let authorization = authorization
        loadTasks[index] = Task { [weak self] in
            let data: Data?
            if let cached {
                data = cached
            } else {
                data = await Self.fetch(url, authorization: authorization)
            }
            let image = await Self.decode(data, maxPixelSize: Self.maxSheetPixels)
            guard !Task.isCancelled, let self else { return }
            self.loading.remove(index)
            self.loadTasks.removeValue(forKey: index)
            guard let image else {
                // Unavailable only if nothing ever loaded; otherwise one
                // bad sheet.
                self.isUnavailable = self.sheets.isEmpty
                return
            }
            self.sheetData[index] = data
            self.sheetDataOrder.removeAll { $0 == index }
            self.sheetDataOrder.append(index)
            while self.sheetData.values.reduce(0, { $0 + $1.count }) > Self.rawSheetByteLimit,
                  let oldest = self.sheetDataOrder.first {
                self.sheetData.removeValue(forKey: oldest)
                self.sheetDataOrder.removeFirst()
            }
            self.sheets.insert((index, image), at: 0)
            if self.sheets.count > Self.sheetLimit {
                self.sheets.removeLast()
            }
            if let wanted = self.wanted, wanted.sheet == index {
                self.frame = self.crop(image, to: wanted)
            }
        }
    }

    /// Geometry comes from the decoded sheet: it may be downscaled, and the
    /// last sheet is only partly filled.
    private func crop(_ sheet: CGImage, to tile: TrickplayTile) -> CGImage? {
        guard source.columns > 0, source.tileSize.width > 0, source.tileSize.height > 0 else { return nil }
        let scale = CGFloat(sheet.width) / (CGFloat(source.columns) * source.tileSize.width)
        guard scale > 0 else { return nil }
        let size = CGSize(width: source.tileSize.width * scale, height: source.tileSize.height * scale)
        let rect = CGRect(
            x: CGFloat(tile.column) * size.width,
            y: CGFloat(tile.row) * size.height,
            width: size.width,
            height: size.height
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height)
        guard bounds.contains(rect) else { return nil }
        return sheet.cropping(to: rect)
    }

    private nonisolated static func fetch(_ url: URL, authorization: MediaRequestAuthorization?) async -> Data? {
        let request = authorization?.request(for: url, timeoutInterval: 30) ?? {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            return request
        }()
        return try? await BoundedDownload.shared.data(for: request, limit: DownloadLimit.artwork, content: .image)
    }

    private nonisolated static func decode(_ data: Data?, maxPixelSize: Int) async -> CGImage? {
        guard let data else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
