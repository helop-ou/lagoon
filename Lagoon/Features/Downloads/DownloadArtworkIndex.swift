#if os(iOS)
import Foundation
import os

/// A nonisolated lookup from a saved download's artwork key to its file on
/// disk. `DownloadStore` rebuilds it on the main actor whenever
/// the active manifest changes; `ImageCache` reads it off the main actor,
/// before ever touching the network, so a downloaded title's poster and
/// backdrop still show up with the account offline.
nonisolated final class DownloadArtworkIndex: Sendable {
    static let shared = DownloadArtworkIndex()

    private let lock = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    private init() {}

    /// Replaces the whole index with the active account's artwork. Called
    /// when account membership or entry artwork changes; progress-only
    /// saves leave the index alone.
    func rebuild(entries: [DownloadEntry], directory: URL) {
        var map: [String: URL] = [:]
        for entry in entries {
            for (key, fileName) in entry.artworkFiles {
                map[key.lowercased()] = directory.appending(path: fileName)
            }
        }
        // Publish a value snapshot; the only shared mutable state is held
        // inside OSAllocatedUnfairLock, which provides its Sendable contract.
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
