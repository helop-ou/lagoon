#if DEBUG && os(iOS)
import Foundation
import Observation
import os

/// One title taken off the server by the spike (HEL-166): what was asked
/// for, where it lives, and how far it got. Persisted as JSON so the list
/// survives relaunch, which is the whole question the spike asks.
nonisolated struct DownloadSpikeEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// `Items/{id}/Download`: the file as stored.
        case original
        /// The server's progressive MPEG-TS transcode as one response.
        case transcode
    }

    enum State: String, Codable, Sendable {
        case queued, downloading, paused, failed, complete
    }

    var id: String { "\(itemID)-\(kind.rawValue)" }
    let itemID: String
    let title: String
    let kind: Kind
    let fileName: String
    var expectedBytes: Int64?
    var receivedBytes: Int64 = 0
    var state: State = .queued
    var failure: String?
    /// Set while a task is in flight so a relaunch can re-adopt it.
    var taskIdentifier: Int?
    /// `resumeData` from a pause or a transport failure, kept as its own
    /// file because it can be megabytes.
    var resumeDataFile: String?
    let createdAt: Date
}

/// The HEL-166 spike: a background `URLSession` that downloads one title as
/// either the original file or a progressive transcode into Application
/// Support, survives suspension and termination, resumes after a kill, and
/// hands `PlaybackController` a local URL to play. Debug builds, iOS only.
/// Everything here is throwaway; the questions it answers are recorded on
/// the ticket, and the real feature gets its own owner and manifest.
@MainActor
@Observable
final class DownloadSpikeStore {
    static let shared = DownloadSpikeStore()
    static let sessionIdentifier = "ee.helop.lagoon.downloads.spike"
    nonisolated static let log = Logger(subsystem: "ee.helop.lagoon", category: "downloads.spike")

    private(set) var entries: [DownloadSpikeEntry] = []
    let directory: URL
    private let manifestURL: URL
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let delegate = SessionDelegate()

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        directory = base.appending(path: "Lagoon/Downloads", directoryHint: .isDirectory)
        manifestURL = directory.appending(path: "spike-manifest.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = directory
        try? excluded.setResourceValues(values)

        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([DownloadSpikeEntry].self, from: data) {
            entries = decoded
        }

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess = !UserDefaults.standard.bool(forKey: "downloads.spike.wifiOnly")
        configuration.allowsConstrainedNetworkAccess = false
        // A progressive transcode is one response that lasts as long as the
        // encode; the resource timeout must outlast a film.
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        configuration.timeoutIntervalForRequest = 10 * 60
        delegate.store = self
        delegate.directory = directory
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        Task { await reconcileTasks() }
    }

    // MARK: - Commands

    /// Where an original download goes when `Items/{id}/Download` answers
    /// 403 (the user lacks "Allow media downloading", which the public demo
    /// user does): the static stream, the same bytes without the policy
    /// check or the activity-log entry. The real feature hides the control
    /// instead; the spike records that the fallback exists.
    @ObservationIgnored private var fallbackRequests: [String: URLRequest] = [:]

    func start(item: MediaItem, source: MediaSource, kind: DownloadSpikeEntry.Kind, client: JellyfinClient) {
        guard let authorization = client.mediaRequestAuthorization() else { return }
        let url: URL
        let fileName: String
        do {
            switch kind {
            case .original:
                url = try client.downloadURL(itemId: item.id)
                fileName = "\(item.id).\(source.container?.split(separator: ",").first.map(String.init) ?? "bin")"
                if let stream = try? client.streamURL(itemId: item.id, source: source), stream.method == .directPlay {
                    fallbackRequests["\(item.id)-original"] = authorization.request(for: stream.url, timeoutInterval: 10 * 60)
                }
            case .transcode:
                url = try client.progressiveTranscodeURL(
                    itemId: item.id, source: source, videoBitrate: 8_000_000, maxWidth: 1_920, maxHeight: 1_080
                )
                fileName = "\(item.id).transcode.ts"
            }
        } catch {
            Self.log.error("url: \(error.localizedDescription, privacy: .public)")
            return
        }
        var entry = DownloadSpikeEntry(
            itemID: item.id, title: item.name ?? item.id, kind: kind, fileName: fileName,
            expectedBytes: kind == .original ? source.size : nil, createdAt: Date()
        )
        remove(entryID: entry.id, deleteFile: true)
        let request = authorization.request(for: url, timeoutInterval: 10 * 60)
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.taskDescription(for: entry)
        entry.taskIdentifier = task.taskIdentifier
        entry.state = .downloading
        entries.append(entry)
        save()
        task.resume()
        Self.log.info("started \(entry.id, privacy: .public) task \(task.taskIdentifier)")
    }

    func pause(_ entry: DownloadSpikeEntry) {
        guard let taskID = entry.taskIdentifier else { return }
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskID }) as? URLSessionDownloadTask else { return }
            task.cancel { data in
                Task { @MainActor [weak self] in self?.storeResumeData(data, for: entry.id, state: .paused) }
            }
        }
    }

    func resume(_ entry: DownloadSpikeEntry) {
        guard let file = entry.resumeDataFile,
              let data = try? Data(contentsOf: directory.appending(path: file)) else { return }
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = Self.taskDescription(for: entry)
        update(entry.id) {
            $0.taskIdentifier = task.taskIdentifier
            $0.state = .downloading
            $0.failure = nil
        }
        task.resume()
    }

    func delete(_ entry: DownloadSpikeEntry) {
        if let taskID = entry.taskIdentifier {
            session.getAllTasks { tasks in
                tasks.first(where: { $0.taskIdentifier == taskID })?.cancel()
            }
        }
        remove(entryID: entry.id, deleteFile: true)
    }

    /// What the player plays instead of the stream: the newest complete
    /// download of the item, original preferred.
    func completedLocalURL(itemID: String) -> URL? {
        let complete = entries.filter { $0.itemID == itemID && $0.state == .complete }
        guard let entry = complete.first(where: { $0.kind == .original }) ?? complete.first else { return nil }
        let url = fileURL(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fileURL(for entry: DownloadSpikeEntry) -> URL {
        directory.appending(path: entry.fileName)
    }

    /// Everything the delegate needs rides on the task itself, so an event
    /// for a task that finished while the process was dead still finds its
    /// entry and destination in the relaunched process.
    nonisolated static func taskDescription(for entry: DownloadSpikeEntry) -> String {
        "\(entry.id)|\(entry.fileName)"
    }

    // MARK: - Delegate reports

    func reportProgress(entryID: String, received: Int64, expected: Int64) {
        update(entryID) {
            $0.receivedBytes = received
            if expected > 0 { $0.expectedBytes = expected }
            $0.state = .downloading
        }
    }

    func reportFinished(entryID: String, status: Int, bytes: Int64) {
        if status == 403, let fallback = fallbackRequests.removeValue(forKey: entryID),
           let entry = entries.first(where: { $0.id == entryID }) {
            Self.log.info("\(entryID, privacy: .public): Download route refused (403), retrying with the static stream")
            let task = session.downloadTask(with: fallback)
            task.taskDescription = Self.taskDescription(for: entry)
            update(entryID) {
                $0.taskIdentifier = task.taskIdentifier
                $0.state = .downloading
                $0.failure = "Download route refused; using the static stream"
            }
            task.resume()
            return
        }
        update(entryID) {
            $0.taskIdentifier = nil
            if (200...299).contains(status) {
                $0.state = .complete
                $0.receivedBytes = bytes
                $0.expectedBytes = bytes
            } else {
                $0.state = .failed
                $0.failure = "HTTP \(status)"
            }
        }
    }

    func reportFailure(entryID: String, error: Error) {
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            storeResumeData(data, for: entryID, state: .failed)
        }
        update(entryID) {
            $0.taskIdentifier = nil
            if $0.state != .paused { $0.state = .failed }
            $0.failure = "\(nsError.domain) \(nsError.code)"
        }
    }

    // MARK: - Private

    private func storeResumeData(_ data: Data?, for entryID: String, state: DownloadSpikeEntry.State) {
        let file = "\(entryID).resume"
        if let data {
            try? data.write(to: directory.appending(path: file), options: .atomic)
        }
        update(entryID) {
            $0.taskIdentifier = nil
            $0.resumeDataFile = data == nil ? nil : file
            $0.state = state
        }
    }

    private func update(_ entryID: String, _ change: (inout DownloadSpikeEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        change(&entries[index])
        save()
    }

    private func remove(entryID: String, deleteFile: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = entries.remove(at: index)
        if deleteFile {
            try? FileManager.default.removeItem(at: fileURL(for: entry))
            if let file = entry.resumeDataFile {
                try? FileManager.default.removeItem(at: directory.appending(path: file))
            }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// After a relaunch: tasks the system kept running are re-adopted by
    /// their description; entries whose task is gone become paused if they
    /// hold resume data, otherwise failed.
    private func reconcileTasks() async {
        let tasks = await session.allTasks
        var live: Set<String> = []
        for task in tasks {
            guard let entryID = task.taskDescription?.split(separator: "|").first.map(String.init),
                  entries.contains(where: { $0.id == entryID }) else { continue }
            live.insert(entryID)
            update(entryID) { $0.taskIdentifier = task.taskIdentifier }
        }
        for entry in entries where entry.state == .downloading && !live.contains(entry.id) {
            update(entry.id) {
                $0.taskIdentifier = nil
                $0.state = $0.resumeDataFile == nil ? .failed : .paused
                if $0.resumeDataFile == nil { $0.failure = "task lost across relaunch" }
            }
        }
        Self.log.info("reconciled \(tasks.count) live tasks, \(self.entries.count) entries")
    }

    /// Delegate callbacks arrive on the session's queue while the app may be
    /// launching in the background; the file move must happen inside
    /// `didFinishDownloadingTo` before it returns, so the delegate keeps its
    /// own destination map and only reports to the store afterwards.
    nonisolated final class SessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        weak var store: DownloadSpikeStore?
        /// Set once by the store; the downloads directory is stable for the
        /// life of the container.
        var directory: URL?

        private func target(for task: URLSessionTask) -> (entryID: String, url: URL)? {
            guard let description = task.taskDescription, let directory else { return nil }
            let parts = description.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], directory.appending(path: parts[1]))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard let target = target(for: downloadTask) else { return }
            Task { @MainActor [store] in
                store?.reportProgress(entryID: target.entryID, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let target = target(for: downloadTask) else { return }
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            var bytes: Int64 = 0
            if (200...299).contains(status) {
                let manager = FileManager.default
                try? manager.removeItem(at: target.url)
                do {
                    try manager.moveItem(at: location, to: target.url)
                    bytes = (try? manager.attributesOfItem(atPath: target.url.path)[.size] as? Int64) ?? 0
                } catch {
                    DownloadSpikeStore.log.error("move failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let received = bytes
            DownloadSpikeStore.log.info("finished \(target.entryID, privacy: .public) status \(status) bytes \(received)")
            Task { @MainActor [store] in
                store?.reportFinished(entryID: target.entryID, status: status, bytes: received)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            guard let target = target(for: task) else {
                DownloadSpikeStore.log.error("failed task \(task.taskIdentifier) with no description: \((error as NSError).code)")
                return
            }
            DownloadSpikeStore.log.error("failed \(target.entryID, privacy: .public): \((error as NSError).code)")
            Task { @MainActor [store] in
                store?.reportFailure(entryID: target.entryID, error: error)
            }
        }

        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            DownloadSpikeStore.log.info("background session events delivered")
        }
    }
}
#endif
