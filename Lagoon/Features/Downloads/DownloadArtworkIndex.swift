#if os(iOS)
import Foundation
import os

/// Artwork key to saved file. Rebuilt on the main actor, read by
/// `ImageCache` off it before any network fetch, so artwork shows offline.
nonisolated final class DownloadArtworkIndex: Sendable {
    static let shared = DownloadArtworkIndex()

    private let lock = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    private init() {}

    /// Progress-only saves leave the index alone.
    func rebuild(entries: [DownloadEntry], directory: URL) {
        var map: [String: URL] = [:]
        for entry in entries {
            for (key, fileName) in entry.artworkFiles {
                map[key.lowercased()] = directory.appending(path: fileName)
            }
        }
        // The lock holds the only shared mutable state.
        let snapshot = map
        lock.withLock { $0 = snapshot }
    }

    /// Signed out, or switching accounts before the new manifest loads.
    func clear() {
        lock.withLock { $0 = [:] }
    }

    func url(imageItemID: String, type: String) -> URL? {
        let key = DownloadArtworkKey.indexKey(imageItemID: imageItemID, type: type)
        guard let candidate = lock.withLock({ $0[key] }) else { return nil }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
#endif
