#if os(iOS)
import Foundation
import os

// The viewer-facing commands: start, pause, resume, delete.
extension DownloadStore {
    /// Takes a title off the server: saves the item snapshot and artwork,
    /// then hands the transfer to the background session. `item` must
    /// carry media sources (a detail read does; a rail item does not).
    func start(item: MediaItem, source: MediaSource, quality: DownloadQuality, client: JellyfinClient) async throws {
        guard let authorization = client.mediaRequestAuthorization(),
              let accountKey, let accountDirectory else {
            throw StartError.notSignedIn
        }
        let generation = accountGeneration
        let preparation = UUID()
        preparationTokens[item.id] = preparation
        defer {
            if preparationTokens[item.id] == preparation { preparationTokens.removeValue(forKey: item.id) }
        }
        // Keep credentials stable through snapshot/artwork requests even if
        // SessionStore reconfigures its shared client during an await.
        let client = client.sessionSnapshot()
        func stillActive() -> Bool {
            generation == accountGeneration
                && self.accountKey == accountKey
                && self.accountDirectory == accountDirectory
        }
        func checkPreparation() throws {
            try Task.checkCancellation()
            guard stillActive() else { throw StartError.accountChanged }
            guard preparationTokens[item.id] == preparation else { throw CancellationError() }
        }
        let permitted = await canDownload(client: client)
        try checkPreparation()
        guard permitted else { throw StartError.notPermitted }

        let supportedVideoType = source.videoType == nil || source.videoType == "VideoFile"
        guard supportedVideoType, item.type == .movie || item.type == .episode else {
            throw StartError.unsupportedItem
        }

        let runTimeTicks = source.runTimeTicks ?? item.runTimeTicks
        let effectiveQuality = quality.effective(sourceSize: source.size, runTimeTicks: runTimeTicks)
        if effectiveQuality != .original {
            let transcodingAllowed = await client.canTranscodeForDownload()
            try checkPreparation()
            guard transcodingAllowed else { throw StartError.notPermitted }
        }
        let estimatedBytes = effectiveQuality.estimatedBytes(sourceSize: source.size, runTimeTicks: runTimeTicks)
        if let estimatedBytes, let free = freeSpace(), estimatedBytes >= free {
            throw StartError.noSpace
        }

        guard let url = try? transferURL(itemID: item.id, source: source, quality: effectiveQuality, client: client) else {
            throw StartError.unsupportedItem
        }

        // A snapshot is required for local playback. Refuse a download
        // whose metadata cannot be fetched/decoded rather than reporting a
        // finished file that still needs the server to become playable.
        let snapshotData = try await client.itemData(id: item.id)
        try checkPreparation()
        let snapshot = try JellyfinClient.decoder.decode(MediaItem.self, from: snapshotData)
        guard snapshot.id == item.id,
              snapshot.mediaSources?.contains(where: { $0.id == source.id }) == true else {
            throw StartError.unsupportedItem
        }

        let tasks = await session.allTasks
        try checkPreparation()
        for task in tasks {
            guard let info = DownloadTaskDescription.parse(task.taskDescription),
                  info.accountKey == accountKey, info.itemID == item.id else { continue }
            task.cancel()
        }
        removeEntry(item.id)

        let ext = effectiveQuality == .original
            ? (source.container?.split(separator: ",").first.map(String.init) ?? "bin")
            : "ts"
        let fileName = "\(item.id).\(ext)"
        try snapshotData.write(to: accountDirectory.appending(path: "\(item.id).item.json"), options: .atomic)
        snapshotCache.removeValue(forKey: item.id)
        let artworkFiles = try await saveArtwork(
            for: item, client: client, authorization: authorization, directory: accountDirectory,
            checkPreparation: checkPreparation
        )
        try checkPreparation()

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

    /// Cancels the transfer. An original download's server response
    /// supports byte-range requests, so the system's resume data lets
    /// `resume` pick up where it left off; a transcode is a progressive
    /// stream the server builds as it goes, with no range support, so
    /// asking for resume data would only save bytes that can never be
    /// replayed into the same file, and `resume` always restarts a
    /// transcode from the beginning.
    func pause(_ itemID: String) {
        guard let entry = manifest.entry(for: itemID), let taskIdentifier = entry.taskIdentifier,
              let accountKey, let attemptToken = entry.attemptToken else { return }
        let resumable = entry.quality == .original
        // Persist the intent before waiting for URLSession's cancellation
        // data. A background suspension must never lose the pause itself.
        manifest.markPaused(itemID, resumeDataFile: entry.resumeDataFile)
        save()
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskIdentifier }) as? URLSessionDownloadTask else { return }
            if resumable {
                task.cancel { data in
                    Task { @MainActor in
                        DownloadStore.shared.applyPause(itemID: itemID, accountKey: accountKey, attemptToken: attemptToken, resumeData: data)
                    }
                }
            } else {
                task.cancel()
                Task { @MainActor in
                    DownloadStore.shared.applyPause(itemID: itemID, accountKey: accountKey, attemptToken: attemptToken, resumeData: nil)
                }
            }
        }
    }

    private func applyPause(itemID: String, accountKey: String, attemptToken: String, resumeData: Data?) {
        func apply(to manifest: inout DownloadManifest, directory: URL?) {
            guard let entry = manifest.entry(for: itemID),
                  entry.attemptToken == attemptToken, !entry.isComplete else { return }
            if resumeData == nil, let existing = entry.resumeDataFile, let directory {
                try? FileManager.default.removeItem(at: directory.appending(path: existing))
            }
            let resumeFile = Self.storeResumeData(resumeData, itemID: itemID, directory: directory)
            manifest.markPaused(itemID, resumeDataFile: resumeFile)
        }
        if self.accountKey == accountKey {
            apply(to: &manifest, directory: accountDirectory)
            save()
        } else {
            Self.withStoredManifest(atAccountKey: accountKey) { manifest, directory in
                apply(to: &manifest, directory: directory)
            }
        }
    }

    /// Restarts a paused or failed download: from resume data when there is
    /// some (only ever stored for an original; see `pause`), otherwise a
    /// fresh request built from the saved item snapshot. Always gets a new
    /// attempt token, so any report still in flight for the previous
    /// attempt is dropped rather than applied to this one.
    func resume(_ itemID: String, client: JellyfinClient) {
        guard let entry = manifest.entry(for: itemID), let accountKey,
              entry.state == .paused || entry.state == .failed,
              preparationTokens[itemID] == nil else { return }
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
        preparationTokens.removeValue(forKey: itemID)
        removeEntry(itemID)
    }

    private func removeEntry(_ itemID: String) {
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
        preparationTokens.removeAll()
        for entry in manifest.entries {
            delete(entry.itemID)
        }
    }
}
#endif
