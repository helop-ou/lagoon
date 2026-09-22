#if os(iOS)
import Foundation
import os

// Routes background session reports into the right account's manifest.
extension DownloadStore {
    /// Everything it needs rides on the task description, so an event after
    /// a relaunch still finds its destination, for any account. Runs on
    /// `OperationQueue.main`, so the token check and file move are one
    /// operation relative to delete and restart.
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

        /// Persists file and manifest before returning, so relaunch recovery
        /// never depends on a queued Task.
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

    /// After a relaunch or account switch. See `DownloadManifest.reconcile`.
    /// Guards against a second switch finishing first while this awaits.
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
        // Drop progress from an attempt a delete-then-restart replaced.
        guard manifest.entry(for: itemID)?.attemptToken == token else { return }
        manifest.recordProgress(itemID, received: received, expected: expected > 0 ? expected : nil)
        saveProgressThrottled()
    }

    /// Cancellation is skipped: it echoes a pause or delete already
    /// recorded. Resume data is kept only for originals.
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

    /// Uses the in-memory manifest for the active account; a fresh copy from
    /// disk would discard unsaved progress and positions.
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

    /// Oldest first; stops at the first failure. Rechecks the account after
    /// every await so a sign-out mid-flush never touches another manifest.
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
