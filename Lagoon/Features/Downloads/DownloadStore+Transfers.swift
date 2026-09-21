#if os(iOS)
import Foundation
import os

// The background session and the transfer commands it carries:
// starting, pausing, resuming and deleting a download, and routing the
// delegate's reports back into whichever account's manifest they belong to.
extension DownloadStore {
    /// Moves a finished file into place and reports back to the store, all
    /// from the task's own description, parsed by `DownloadTaskDescription`.
    /// Everything the delegate needs rides on the task, so an event for a
    /// task that finished while the process was dead still finds its
    /// destination in the relaunched process, for whichever account it
    /// belongs to, including an account that is not currently active.
    /// The session uses `OperationQueue.main` as its delegate queue. Keeping
    /// completion validation, file replacement and manifest persistence on
    /// that same serial executor makes the token check and delete/move one
    /// operation relative to MainActor commands such as delete and restart.
    nonisolated final class SessionDelegate: NSObject, URLSessionDownloadDelegate {
        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard let info = DownloadTaskDescription.parse(downloadTask.taskDescription) else { return }
            MainActor.assumeIsolated {
                DownloadStore.shared.reportProgress(
                    accountKey: info.accountKey, itemID: info.itemID, token: info.attemptToken,
                    received: totalBytesWritten, expected: totalBytesExpectedToWrite
                )
            }
        }

        /// URLSession keeps the app running until its background events are
        /// acknowledged. Persist both the file and manifest before returning
        /// this callback so relaunch recovery never depends on a queued Task.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let info = DownloadTaskDescription.parse(downloadTask.taskDescription) else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            MainActor.assumeIsolated {
                DownloadStore.shared.reportFinished(info: info, status: status, location: location)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let info = DownloadTaskDescription.parse(task.taskDescription) else { return }
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            MainActor.assumeIsolated {
                DownloadStore.shared.reportTransportFailure(
                    accountKey: info.accountKey, itemID: info.itemID, token: info.attemptToken,
                    error: nsError, resumeData: resumeData
                )
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            DownloadStore.log.info("background session events delivered")
            MainActor.assumeIsolated {
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
    /// being declared lost. Anything left over
    /// becomes paused if it holds resume data, otherwise failed. Guards
    /// against a second switch completing first while this awaits.
    func reconcileLiveTasks(accountKey: String) {
        let generation = accountGeneration
        Task { @MainActor in
            let queriedAttempts = Dictionary(uniqueKeysWithValues: self.manifest.entries.map { ($0.itemID, $0.attemptToken ?? "") })
            let tasks = await self.session.allTasks
            guard self.accountGeneration == generation, self.accountKey == accountKey else { return }
            var live: [String: Int] = [:]
            for task in tasks {
                guard let info = DownloadTaskDescription.parse(task.taskDescription), info.accountKey == accountKey,
                      let entry = self.manifest.entry(for: info.itemID), entry.attemptToken == info.attemptToken,
                      entry.fileName == info.fileName,
                      task.state == .running || task.state == .suspended else { continue }
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
            let lost = self.manifest.reconcile(liveTasks: live, completedFiles: completedFiles, queriedAttempts: queriedAttempts)
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
        // byte count for a transfer that no longer exists.
        guard manifest.entry(for: itemID)?.attemptToken == token else { return }
        manifest.recordProgress(itemID, received: received, expected: expected > 0 ? expected : nil)
        saveProgressThrottled()
    }

    /// Maps a transport error to short copy for the viewer and records it,
    /// skipping the manifest write entirely when the mapping says there is
    /// nothing to show: a cancellation is just the echo of a `pause` or
    /// `delete` that already recorded the real state. Resume data is only
    /// ever meaningful for an original download; a transcode has no
    /// byte-range support to resume into, so it always restarts from the
    /// beginning.
    func reportTransportFailure(accountKey: String, itemID: String, token: String, error: NSError, resumeData: Data?) {
        guard let reason = DownloadTransportFailure.failureDescription(domain: error.domain, code: error.code) else { return }
        if accountKey == self.accountKey {
            guard let entry = manifest.entry(for: itemID), entry.attemptToken == token, entry.isActive else { return }
            let resumeFile = entry.quality == .original
                ? Self.storeResumeData(resumeData, itemID: itemID, directory: accountDirectory)
                : nil
            manifest.markFailed(itemID, reason: reason, resumeDataFile: resumeFile)
            save()
        } else {
            Self.withStoredManifest(atAccountKey: accountKey) { manifest, directory in
                guard let entry = manifest.entry(for: itemID), entry.attemptToken == token, entry.isActive else { return }
                let resumeFile = entry.quality == .original
                    ? Self.storeResumeData(resumeData, itemID: itemID, directory: directory)
                    : nil
                manifest.markFailed(itemID, reason: reason, resumeDataFile: resumeFile)
            }
        }
    }

    /// Uses the active manifest directly. Loading a second copy from disk
    /// here would discard progress or playback positions still in memory.
    /// Inactive accounts persist through the same synchronous completion
    /// operation, including a background relaunch before any account loads.
    func reportFinished(info: DownloadTaskDescription, status: Int, location: URL) {
        if info.accountKey == accountKey, let accountDirectory {
            DownloadFileCompletion.apply(
                info: info, status: status, location: location,
                directory: accountDirectory, manifest: &manifest
            )
            save()
        } else {
            Self.withStoredManifest(atAccountKey: info.accountKey) { manifest, directory in
                DownloadFileCompletion.apply(
                    info: info, status: status, location: location,
                    directory: directory, manifest: &manifest
                )
            }
        }
    }

    // MARK: - Playback reports

    /// Retries stop reports a server couldn't take earlier, in order, oldest
    /// first; stops at the first failure rather than reordering the queue.
    /// The account can change while an await here is in flight (a sign-out
    /// mid-flush), so the account is captured up front and checked again
    /// after every await: the manifest must never be mutated for an account
    /// this call did not start out flushing.
    func flushPendingReports(client: JellyfinClient) async {
        let account = accountKey
        let generation = accountGeneration
        let client = client.sessionSnapshot()
        for report in manifest.pendingReports {
            do {
                try await client.reportPlaybackStopped(.init(
                    itemId: report.itemID, mediaSourceId: report.mediaSourceID,
                    playSessionId: nil, positionTicks: report.positionTicks
                ))
                guard accountGeneration == generation, accountKey == account else { return }
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
