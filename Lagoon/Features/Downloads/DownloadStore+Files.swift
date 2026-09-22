#if os(iOS)
import Foundation
import LagoonEngine
import os

// Directories, manifest persistence and artwork files.
extension DownloadStore {
    /// Persists the active account's manifest. Does not rebuild the artwork
    /// index, which is too costly per progress save: callers that add,
    /// remove or activate entries call `rebuildArtworkIndex()` themselves.
    func save() {
        guard let accountDirectory else { return }
        Self.saveManifest(manifest, at: accountDirectory.appending(path: "manifest.json"))
    }

    /// At most once per second, for progress callbacks. State changes call
    /// `save()` directly and are never delayed.
    func saveProgressThrottled() {
        let now = Date()
        if let lastProgressSaveDate, now.timeIntervalSince(lastProgressSaveDate) < 1 {
            return
        }
        lastProgressSaveDate = now
        save()
    }

    func rebuildArtworkIndex() {
        guard let accountDirectory else {
            DownloadArtworkIndex.shared.clear()
            return
        }
        DownloadArtworkIndex.shared.rebuild(entries: manifest.entries, directory: accountDirectory)
    }

    // MARK: - Directories

    nonisolated static func downloadsRootDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Lagoon/Downloads", directoryHint: .isDirectory)
    }

    nonisolated static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Manifest persistence

    static let manifestEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let manifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func loadManifest(at url: URL) -> DownloadManifest {
        guard let data = try? Data(contentsOf: url) else { return DownloadManifest() }
        return (try? manifestDecoder.decode(DownloadManifest.self, from: data)) ?? DownloadManifest()
    }

    static func saveManifest(_ manifest: DownloadManifest, at url: URL) {
        do {
            let data = try manifestEncoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("persist download manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mutates an inactive account's manifest on disk. Never creates the
    /// directory: a removed account must not be recreated by a late transfer.
    static func withStoredManifest(
        atAccountKey key: String,
        _ mutate: (inout DownloadManifest, URL) -> Void
    ) {
        let directory = downloadsRootDirectory().appending(path: key, directoryHint: .isDirectory)
        let manifestURL = directory.appending(path: "manifest.json")
        var manifest = loadManifest(at: manifestURL)
        mutate(&manifest, directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        saveManifest(manifest, at: manifestURL)
    }

    /// Returns the file name to record on the entry.
    @discardableResult
    static func storeResumeData(_ data: Data?, itemID: String, directory: URL?) -> String? {
        guard let data, let directory else { return nil }
        let fileName = "\(itemID).resume"
        do {
            try data.write(to: directory.appending(path: fileName), options: .atomic)
            return fileName
        } catch {
            log.error("persist download resume data: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Artwork

    /// Saves poster and backdrop before the transfer starts. Failures are
    /// logged, not fatal.
    func saveArtwork(
        for item: MediaItem, client: JellyfinClient, authorization: MediaRequestAuthorization,
        directory: URL, checkPreparation: () throws -> Void
    ) async throws -> [String: String] {
        var files: [String: String] = [:]
        // Same widths the detail page requests online.
        let kinds: [(ItemImageKind, Int)] = [(.poster, Metrics.detailPosterRequestWidth), (.backdrop, 1920)]
        for (kind, maxWidth) in kinds {
            guard let url = client.imageURL(for: item, kind: kind, maxWidth: maxWidth),
                  let key = DownloadArtworkKey.parse(url) else { continue }
            let request = authorization.request(for: url)
            do {
                let data = try await BoundedDownload.shared.data(for: request, limit: DownloadLimit.artwork, content: .image)
                try checkPreparation()
                let fileName = "art-\(key.imageItemID)-\(key.type.replacingOccurrences(of: "/", with: "-")).jpg"
                try data.write(to: directory.appending(path: fileName), options: .atomic)
                files[DownloadArtworkKey.indexKey(imageItemID: key.imageItemID, type: key.type)] = fileName
            } catch {
                try checkPreparation()
                Self.log.error("artwork for \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return files
    }
}
#endif
