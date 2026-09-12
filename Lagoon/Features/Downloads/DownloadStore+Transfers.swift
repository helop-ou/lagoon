#if os(iOS)
import Foundation
import os

// The background session and the transfer commands it carries (HEL-166):
// starting, pausing, resuming and deleting a download, and routing the
// delegate's reports back into whichever account's manifest they belong to.
extension DownloadStore {
    /// Moves a finished file into place and reports back to the store, all
    /// from the task's own description, parsed by `DownloadTaskDescription`.
    /// Everything the delegate needs rides on the task, so an event for a
    /// task that finished while the process was dead still finds its
    /// destination in the relaunched process, for whichever account it
    /// belongs to (`baseDirectory` plus the key is enough to find it, even
    /// one that is not the currently active account).
    nonisolated final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let baseDirectory: URL

        init(baseDirectory: URL) {
            self.baseDirectory = baseDirectory
            super.init()
        }

        private func target(for task: URLSessionTask) -> (info: DownloadTaskDescription, directory: URL, fileURL: URL)? {
            guard let info = DownloadTaskDescription.parse(task.taskDescription) else { return nil }
            let directory = baseDirectory.appending(path: info.accountKey, directoryHint: .isDirectory)
            return (info, directory, directory.appending(path: info.fileName))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard let target = target(for: downloadTask) else { return }
            Task { @MainActor in
                DownloadStore.shared.reportProgress(
                    accountKey: target.info.accountKey, itemID: target.info.itemID, token: target.info.attemptToken,
                    received: totalBytesWritten, expected: totalBytesExpectedToWrite
                )
            }
        }

        /// Moves the file and writes the manifest change to disk
        /// synchronously, before returning: the system can suspend the app
        /// moments after this call on a background relaunch, and a change
        /// only queued for the main actor to apply later would be lost
        /// along with the completion it recorded (HEL-166 review finding
        /// 1). The account's directory is gone when the account was
        /// removed mid-transfer; the file is discarded rather than
        /// recreating a directory nothing else will ever look at again
        /// (HEL-166 review finding 2).
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let target = target(for: downloadTask) else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let manager = FileManager.default
            let accountRemoved = !manager.fileExists(atPath: target.directory.path)
            var bytes: Int64 = 0
            var moveError: String?
            if accountRemoved {
                try? manager.removeItem(at: location)
            } else if (200...299).contains(status) {
                try? manager.removeItem(at: target.fileURL)
                do {
                    try manager.moveItem(at: location, to: target.fileURL)
                    bytes = (try? manager.attributesOfItem(atPath: target.fileURL.path)[.size] as? Int64) ?? 0
                } catch {
                    moveError = error.localizedDescription
                }
            }
            guard !accountRemoved else { return }

            let info = target.info
            let receivedBytes = bytes
            DownloadStore.withStoredManifest(atAccountKey: info.accountKey) { manifest, directory in
                // A delete-then-restart routed this callback to the entry's
                // old attempt; the entry now belongs to a different task
                // and must not be touched by a report that no longer
                // matches it (HEL-166 review finding 4).
                guard manifest.entry(for: info.itemID)?.attemptToken == info.attemptToken else { return }
                if let moveError {
                    manifest.markFailed(info.itemID, reason: moveError, resumeDataFile: nil)
                } else {
                    DownloadStore.applyFinished(to: &manifest, itemID: info.itemID, status: status, bytes: receivedBytes, directory: directory)
                }
            }
            Task { @MainActor in
                guard DownloadStore.shared.accountKey == info.accountKey else { return }
                DownloadStore.shared.reloadActiveManifest()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let info = DownloadTaskDescription.parse(task.taskDescription) else { return }
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            Task { @MainActor in
                DownloadStore.shared.reportTransportFailure(
                    accountKey: info.accountKey, itemID: info.itemID, token: info.attemptToken,
                    error: nsError, resumeData: resumeData
                )
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            DownloadStore.log.info("background session events delivered")
            Task { @MainActor in
                DownloadStore.shared.resumeBackgroundEventsContinuationIfNeeded()
            }
        }
    }

    // MARK: - Reconciliation

    /// After a relaunch or an account switch: tasks the system kept running
    /// are re-adopted by their description; an active entry with no live
    /// task but a finished file on disk (its `didFinishDownloadingTo`
    /// landed while the process was dead, between the write and this
    /// process getting a chance to run) is promoted to complete instead of
    /// being declared lost (HEL-166 review finding 1). Anything left over
    /// becomes paused if it holds resume data, otherwise failed. Guards
    /// against a second switch completing first while this awaits.
    func reconcileLiveTasks(accountKey: String) {
        Task { @MainActor in
            let tasks = await self.session.allTasks
            guard self.accountKey == accountKey else { return }
            var live: [String: Int] = [:]
            for task in tasks {
                guard let info = DownloadTaskDescription.parse(task.taskDescription), info.accountKey == accountKey else { continue }
                live[info.itemID] = task.taskIdentifier
            }
            var completedFiles: [String: Int64] = [:]
            if let accountDirectory = self.accountDirectory {
                let manager = FileManager.default
                for entry in self.manifest.entries where entry.isActive && live[entry.itemID] == nil {
                    let fileURL = accountDirectory.appending(path: entry.fileName)
                    if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
                       let size = attributes[.size] as? Int64, size > 0 {
                        completedFiles[entry.itemID] = size
                    }
                }
            }
            let lost = self.manifest.reconcile(liveTasks: live, completedFiles: completedFiles)
            if !lost.isEmpty {
                Self.log.info("reconcile: \(lost.count) transfer(s) lost across relaunch")
            }
            self.save()
        }
    }

    // MARK: - Delegate reports

    func reportProgress(accountKey: String, itemID: String, token: String, received: Int64, expected: Int64) {
        guard accountKey == self.accountKey else { return }
        // A delete-then-restart routes a stale progress callback to the
        // entry's new attempt; without this check it would resurrect a
        // byte count for a transfer that no longer exists (HEL-166 review
        // finding 4).
        guard manifest.entry(for: itemID)?.attemptToken == token else { return }
        manifest.recordProgress(itemID, received: received, expected: expected > 0 ? expected : nil)
        saveProgressThrottled()
    }

    /// Maps a transport error to short copy for the viewer and records it,
    /// skipping the manifest write entirely when the mapping says there is
    /// nothing to show: a cancellation is just the echo of a `pause` or
    /// `delete` that already recorded the real state (HEL-166 review
    /// finding 7). Resume data is only ever meaningful for an original
    /// download; a transcode has no byte-range support to resume into, so
    /// it always restarts from the beginning (HEL-166 review finding 3).
    func reportTransportFailure(accountKey: String, itemID: String, token: String, error: NSError, resumeData: Data?) {
        guard let reason = DownloadTransportFailure.failureDescription(domain: error.domain, code: error.code) else { return }
        if accountKey == self.accountKey {
            guard manifest.entry(for: itemID)?.attemptToken == token else { return }
            let resumeFile = manifest.entry(for: itemID)?.quality == .original
                ? Self.storeResumeData(resumeData, itemID: itemID, directory: accountDirectory)
                : nil
            manifest.markFailed(itemID, reason: reason, resumeDataFile: resumeFile)
            save()
        } else {
            Self.withStoredManifest(atAccountKey: accountKey) { manifest, directory in
                guard manifest.entry(for: itemID)?.attemptToken == token else { return }
                let resumeFile = manifest.entry(for: itemID)?.quality == .original
                    ? Self.storeResumeData(resumeData, itemID: itemID, directory: directory)
                    : nil
                manifest.markFailed(itemID, reason: reason, resumeDataFile: resumeFile)
            }
        }
    }

    /// Shared by the active-account and stored-account report paths, and by
    /// the delegate's own synchronous write for the active account: the
    /// pure classification lives in `DownloadCompletion.outcome` so it can
    /// be pinned down with tests independent of the manifest and the
    /// filesystem (HEL-166 review finding 12).
    fileprivate nonisolated static func applyFinished(to manifest: inout DownloadManifest, itemID: String, status: Int, bytes: Int64, directory: URL?) {
        guard let entry = manifest.entry(for: itemID) else { return }
        switch DownloadCompletion.outcome(status: status, bytesOnDisk: bytes, expectedBytes: entry.expectedBytes, quality: entry.quality) {
        case .complete(let completedBytes):
            manifest.markComplete(itemID, bytes: completedBytes, at: Date())
        case .failed(let reason):
            manifest.markFailed(itemID, reason: reason, resumeDataFile: nil)
            if let directory { try? FileManager.default.removeItem(at: directory.appending(path: entry.fileName)) }
        }
    }

    // MARK: - Playback reports

    /// Retries stop reports a server couldn't take earlier, in order, oldest
    /// first; stops at the first failure rather than reordering the queue.
    /// The account can change while an await here is in flight (a sign-out
    /// mid-flush), so the account is captured up front and checked again
    /// after every await: the manifest must never be mutated for an account
    /// this call did not start out flushing (HEL-166 review finding 8).
    func flushPendingReports(client: JellyfinClient) async {
        let account = accountKey
        for report in manifest.pendingReports {
            do {
                try await client.reportPlaybackStopped(.init(
                    itemId: report.itemID, mediaSourceId: report.mediaSourceID,
                    playSessionId: nil, positionTicks: report.positionTicks
                ))
                guard accountKey == account else { return }
                manifest.removePendingReport(report)
                save()
            } catch {
                Self.log.error("flush pending report \(report.itemID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }
}
#endif
