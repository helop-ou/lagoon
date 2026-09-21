import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Feeds preview frames to the scrub chip.
///
/// Jellyfin serves trickplay as sprite sheets — typically a 10×10 grid of
/// 320×180 thumbnails per JPEG, one thumbnail every 10 s — so a "frame" is a
/// crop out of a sheet that is already in memory, and only crossing a sheet
/// boundary costs a download. That geometry is why so little caching is
/// needed: one sheet covers ~16 minutes of runtime.
///
/// Deliberately not routed through `ImageCache`: sheets are ~23 MB decoded
/// and would evict the entire poster cache on the first scrub. This holds
/// its own two and dies with the player.
@Observable
@MainActor
final class TrickplayLoader {
    /// The frame for the position last handed to `update(to:)`. The previous
    /// frame stays up while the next sheet downloads — a scrub that crosses
    /// a boundary should stall the picture, never blank it.
    private(set) var frame: CGImage?

    /// Set when a sheet the manifest promised doesn't come back — pruned
    /// files, a stale manifest — so the chip can stop reserving space for a
    /// picture that will never arrive.
    private(set) var isUnavailable = false

    private let source: TrickplaySource
    /// The trickplay route 401s without credentials, and the sheet URL
    /// carries no query token, so every sheet fetch sends
    /// the header credential the source arrived with.
    private var authorization: MediaRequestAuthorization? { source.authorization }
    /// Decoded sheets, most-recently-used first.
    private var sheets: [(index: Int, image: CGImage)] = []
    /// Compressed sheets, capped at 32 MiB. Revisiting a retained sheet
    /// re-decodes it without another download.
    private var sheetData: [Int: Data] = [:]
    private var sheetDataOrder: [Int] = []
    private var loading: Set<Int> = []
    @ObservationIgnored private var loadTasks: [Int: Task<Void, Never>] = [:]
    /// The tile the scrubber is asking for right now — re-checked when a
    /// sheet lands, since the playhead has usually moved on by then.
    private var wanted: TrickplayTile?

    /// Two sheets ≈ 46 MB. A third buys almost nothing at 16 minutes each.
    private static let sheetLimit = 2
    private static let rawSheetByteLimit = 32 * 1_024 * 1_024
    /// Caps the decode so a server generating fat trickplay resolutions
    /// can't blow up memory. Tile geometry is derived from the decoded
    /// sheet, so a downscaled one crops just as correctly.
    private static let maxSheetPixels = 3200

    init(source: TrickplaySource) {
        self.source = source
    }

    deinit { for task in loadTasks.values { task.cancel() } }

    /// Points the loader at a playback position. Cheap to call per drag
    /// update: within one thumbnail's interval it does nothing at all.
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
        // A rapid scrub can cross many sheets. Keep only the requested
        // sheet's transfer; the previous decoded frame remains visible.
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
                // Nothing has ever loaded, so the tiles aren't really there.
                // A later failure just means one bad sheet — keep going.
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

    /// Tile geometry comes from the *decoded* sheet rather than the declared
    /// numbers: the decode may have downscaled it, and the last sheet of a
    /// film is only partially filled, so its height isn't `rows` tiles.
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
