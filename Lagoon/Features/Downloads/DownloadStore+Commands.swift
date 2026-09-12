#if os(iOS)
import Foundation
import os

// The viewer-facing commands: start, pause, resume, delete (HEL-166).
extension DownloadStore {
    /// Takes a title off the server: saves the item snapshot and artwork,
    /// then hands the transfer to the background session. `item` must
    /// carry media sources (a detail read does; a rail item does not).
    func start(item: MediaItem, source: MediaSource, quality: DownloadQuality, client: JellyfinClient) async throws {
        guard let authorization = client.mediaRequestAuthorization(),
              let accountKey, let accountDirectory else {
            throw StartError.notSignedIn
        }
        guard await canDownload(client: client) else { throw StartError.notPermitted }

        let supportedVideoType = source.videoType == nil || source.videoType == "VideoFile"
        guard supportedVideoType, item.type == .movie || item.type == .episode else {
            throw StartError.unsupportedItem
        }

        let runTimeTicks = source.runTimeTicks ?? item.runTimeTicks
        let effectiveQuality = quality.effective(sourceSize: source.size, runTimeTicks: runTimeTicks)
        let estimatedBytes = effectiveQuality.estimatedBytes(sourceSize: source.size, runTimeTicks: runTimeTicks)
        if let estimatedBytes, let free = freeSpace(), estimatedBytes >= free {
            throw StartError.noSpace
        }

        guard let url = try? transferURL(itemID: item.id, source: source, quality: effectiveQuality, client: client) else {
            throw StartError.unsupportedItem
        }

        // Cancel any task still running for this item before starting a
        // fresh one: without this, a delete-then-restart could leave two
        // tasks in flight for the same item, and the old one's callbacks
        // would race the new one's (HEL-166 review finding 4). The
        // awaitable `session.allTasks` makes this deterministic in a way
        // the callback-based `getAllTasks` cannot: the cancel is known to
        // have happened before the new task is created.
        await cancelLiveTask(itemID: item.id)
        delete(item.id)

        let ext = effectiveQuality == .original
            ? (source.container?.split(separator: ",").first.map(String.init) ?? "bin")
            : "ts"
        let fileName = "\(item.id).\(ext)"

        if let data = try? await client.itemData(id: item.id) {
            try? data.write(to: accountDirectory.appending(path: "\(item.id).item.json"), options: .atomic)
        }
        snapshotCache.removeValue(forKey: item.id)
        let artworkFiles = await saveArtwork(for: item, client: client, authorization: authorization, directory: accountDirectory)

        let entry = DownloadEntry(
            itemID: item.id, type: item.type, title: item.name ?? item.id,
            seriesID: item.seriesId, seriesName: item.seriesName,
            seasonNumber: item.parentIndexNumber, episodeNumber: item.indexNumber,
            productionYear: item.productionYear, runTimeTicks: runTimeTicks,
            requestedQuality: quality, quality: effectiveQuality, fileName: fileName,
            mediaSourceID: source.id, eTag: source.eTag,
            expectedBytes: effectiveQuality == .original ? source.size : estimatedBytes,
            artworkFiles: artworkFiles, createdAt: Date()
        )
        manifest.insert(entry)
        rebuildArtworkIndex()
        save()

        var request = authorization.request(for: url, timeoutInterval: 10 * 60)
        request.allowsExpensiveNetworkAccess = !wifiOnly
        request.allowsConstrainedNetworkAccess = !wifiOnly

        let attemptToken = UUID().uuidString
        let task = session.downloadTask(with: request)
        task.taskDescription = DownloadTaskDescription(itemID: item.id, fileName: fileName, accountKey: accountKey, attemptToken: attemptToken).raw
        manifest.markStarted(item.id, taskIdentifier: task.taskIdentifier, attemptToken: attemptToken)
        save()
        task.resume()
        Self.log.info("started \(item.id, privacy: .public) quality \(effectiveQuality.rawValue, privacy: .public)")
    }

    /// The original file or a fresh progressive-transcode URL, for a first
    /// attempt and for a `resume` that has no resume data to fall back on.
    fileprivate func transferURL(itemID: String, source: MediaSource, quality: DownloadQuality, client: JellyfinClient) throws -> URL {
        if quality == .original {
            return try client.downloadURL(itemId: itemID)
        }
        guard let videoBitrate = quality.videoBitrate, let maxSize = quality.maxSize else {
            throw StartError.unsupportedItem
        }
        return try client.progressiveTranscodeURL(
            itemId: itemID, source: source, videoBitrate: videoBitrate, maxWidth: maxSize.width, maxHeight: maxSize.height
        )
    }

    /// Cancels any task the session still has for an item, awaiting the
    /// cancel so a caller can be sure it happened before starting a new one
    /// (HEL-166 review finding 4).
    private func cancelLiveTask(itemID: String) async {
        let tasks = await session.allTasks
        guard let task = tasks.first(where: { DownloadTaskDescription.parse($0.taskDescription)?.itemID == itemID }) else { return }
        task.cancel()
    }

    /// Cancels the transfer. An original download's server response
    /// supports byte-range requests, so the system's resume data lets
    /// `resume` pick up where it left off; a transcode is a progressive
    /// stream the server builds as it goes, with no range support, so
    /// asking for resume data would only save bytes that can never be
    /// replayed into the same file, and `resume` always restarts a
    /// transcode from the beginning (HEL-166 review finding 3).
    func pause(_ itemID: String) {
        guard let entry = manifest.entry(for: itemID), let taskIdentifier = entry.taskIdentifier else { return }
        let resumable = entry.quality == .original
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) as? URLSessionDownloadTask else { return }
            if resumable {
                task.cancel { data in
                    Task { @MainActor in
                        DownloadStore.shared.applyPause(itemID: itemID, resumeData: data)
                    }
                }
            } else {
                task.cancel()
                Task { @MainActor in
                    DownloadStore.shared.applyPause(itemID: itemID, resumeData: nil)
                }
            }
        }
    }

    private func applyPause(itemID: String, resumeData: Data?) {
        if resumeData == nil, let existing = manifest.entry(for: itemID)?.resumeDataFile {
            try? FileManager.default.removeItem(at: (accountDirectory ?? baseDirectory).appending(path: existing))
        }
        let resumeFile = Self.storeResumeData(resumeData, itemID: itemID, directory: accountDirectory)
        manifest.markPaused(itemID, resumeDataFile: resumeFile)
        save()
    }

    /// Restarts a paused or failed download: from resume data when there is
    /// some (only ever stored for an original; see `pause`), otherwise a
    /// fresh request built from the saved item snapshot. Always gets a new
    /// attempt token, so any report still in flight for the previous
    /// attempt is dropped rather than applied to this one (HEL-166 review
    /// finding 4).
    func resume(_ itemID: String, client: JellyfinClient) {
        guard let entry = manifest.entry(for: itemID), let accountKey else { return }
        guard let authorization = client.mediaRequestAuthorization() else {
            manifest.markFailed(itemID, reason: "Sign in again to resume this download", resumeDataFile: entry.resumeDataFile)
            save()
            return
        }

        let attemptToken = UUID().uuidString

        if let resumeFile = entry.resumeDataFile,
           let data = try? Data(contentsOf: (accountDirectory ?? baseDirectory).appending(path: resumeFile)) {
            let task = session.downloadTask(withResumeData: data)
            task.taskDescription = DownloadTaskDescription(itemID: itemID, fileName: entry.fileName, accountKey: accountKey, attemptToken: attemptToken).raw
            manifest.markStarted(itemID, taskIdentifier: task.taskIdentifier, attemptToken: attemptToken)
            save()
            task.resume()
            return
        }

        guard let item = snapshotItem(for: itemID),
              let source = item.mediaSources?.first(where: { $0.id == entry.mediaSourceID }) ?? item.mediaSources?.first,
              let url = try? transferURL(itemID: itemID, source: source, quality: entry.quality, client: client) else {
            manifest.markFailed(itemID, reason: "The saved item details are missing", resumeDataFile: nil)
            save()
            return
        }

        var request = authorization.request(for: url, timeoutInterval: 10 * 60)
        request.allowsExpensiveNetworkAccess = !wifiOnly
        request.allowsConstrainedNetworkAccess = !wifiOnly
        let task = session.downloadTask(with: request)
        task.taskDescription = DownloadTaskDescription(itemID: itemID, fileName: entry.fileName, accountKey: accountKey, attemptToken: attemptToken).raw
        manifest.markStarted(itemID, taskIdentifier: task.taskIdentifier, attemptToken: attemptToken)
        save()
        task.resume()
    }

    /// Cancels any live transfer and removes every file the entry owns.
    /// Artwork is shared by name (two episodes of one series save the same
    /// series poster), so a file another entry still lists stays.
    func delete(_ itemID: String) {
        guard let entry = manifest.entry(for: itemID) else { return }
        if let taskIdentifier = entry.taskIdentifier {
            session.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskIdentifier })?.cancel()
            }
        }
        if let directory = accountDirectory {
            let manager = FileManager.default
            try? manager.removeItem(at: directory.appending(path: entry.fileName))
            if let resumeDataFile = entry.resumeDataFile {
                try? manager.removeItem(at: directory.appending(path: resumeDataFile))
            }
            try? manager.removeItem(at: directory.appending(path: "\(itemID).item.json"))
            let stillReferenced = Set(
                manifest.entries.filter { $0.itemID != itemID }.flatMap { $0.artworkFiles.values }
            )
            for fileName in entry.artworkFiles.values where !stillReferenced.contains(fileName) {
                try? manager.removeItem(at: directory.appending(path: fileName))
            }
        }
        manifest.remove(itemID)
        snapshotCache.removeValue(forKey: itemID)
        rebuildArtworkIndex()
        save()
    }

    func deleteAll() {
        for entry in manifest.entries {
            delete(entry.itemID)
        }
    }
}
#endif
