#if os(iOS)
import Foundation
import os

// Directories, manifest persistence and artwork files. Reading and
// writing the manifest is split from the transfer logic in
// `DownloadStore+Transfers.swift` so a relaunch, an account switch and a
// background delegate callback for a non-active account can all go through
// the same small set of helpers.
extension DownloadStore {
    /// Persists the active account's manifest. Every mutation goes through
    /// a `DownloadManifest` transition method, then this. Does not touch
    /// the artwork index: rebuilding it decodes every entry's files back
    /// into a lookup table, which is wasted work on the frequent saves a
    /// progress callback triggers, so callers that add, remove or activate
    /// entries call `rebuildArtworkIndex()` themselves.
    func save() {
        guard let accountDirectory else { return }
        Self.saveManifest(manifest, at: accountDirectory.appending(path: "manifest.json"))
    }

    /// Saves at most once per second: a fast transfer's `didWriteData`
    /// callback can fire many times a second, and encoding and writing the
    /// whole manifest on every one of them was measurable cost for no
    /// benefit the viewer could see. Real state
    /// changes (start, pause, resume, complete, fail) always call `save()`
    /// directly instead, so they are never delayed by this throttle.
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

    /// Loads another account's manifest, lets the caller mutate it, and
    /// saves it back: for a transfer that reports in while a different
    /// account is active, whose in-memory manifest must not change. Never
    /// creates the account directory: an account that was removed while a
    /// transfer for it was in flight has no directory to write into, and
    /// this must not recreate one for files that will never arrive. A
    /// missing directory still loads an
    /// empty manifest, so `mutate` can check for that itself when it
    /// matters.
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

    /// Writes resume data beside the other account files, returning the
    /// file name to record on the entry (nil clears any existing one).
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

    /// Saves the item's poster and backdrop beside the download, before the
    /// transfer starts, so a downloaded title has offline artwork the
    /// moment it appears in the Downloads list. Failures are logged, not
    /// fatal: a title with no saved artwork still downloads and plays.
    func saveArtwork(
        for item: MediaItem, client: JellyfinClient, authorization: MediaRequestAuthorization,
        directory: URL, checkPreparation: () throws -> Void
    ) async throws -> [String: String] {
        var files: [String: String] = [:]
        // Matches the widths the detail page requests live, so a
        // downloaded title's offline artwork is never a visibly softer
        // copy of the one the viewer saw online.
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
