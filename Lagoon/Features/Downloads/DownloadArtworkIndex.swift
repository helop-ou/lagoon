#if os(iOS)
import Foundation
import os

/// A nonisolated lookup from a saved download's artwork key to its file on
/// disk (HEL-166). `DownloadStore` rebuilds it on the main actor whenever
/// the active manifest changes; `ImageCache` reads it off the main actor,
/// before ever touching the network, so a downloaded title's poster and
/// backdrop still show up with the account offline.
final class DownloadArtworkIndex: @unchecked Sendable {
    static let shared = DownloadArtworkIndex()

    private let lock = OSAllocatedUnfairLock<[String: URL]>(initialState: [:])

    private init() {}

    /// Replaces the whole index with the active account's artwork. Called
    /// after every manifest save, so a rebuild is always cheap: at most a
    /// couple of files per entry.
    func rebuild(entries: [DownloadEntry], directory: URL) {
        var map: [String: URL] = [:]
        for entry in entries {
            for (key, fileName) in entry.artworkFiles {
                map[key.lowercased()] = directory.appending(path: fileName)
            }
        }
        lock.withLock { $0 = map }
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
