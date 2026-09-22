import Foundation
import os

/// Original is the stored file; the others are a capped server transcode, so
/// a 30 GB 4K remux never lands on a phone unless asked for by name.
nonisolated enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case original
    case high
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: String(localized: "Original")
        case .high: String(localized: "High")
        case .standard: String(localized: "Standard")
        }
    }

    var detail: String {
        switch self {
        case .original: String(localized: "The file as stored on the server")
        case .high: String(localized: "1080p, about 8 Mbps")
        case .standard: String(localized: "720p, about 3 Mbps")
        }
    }

    var videoBitrate: Int? {
        switch self {
        case .original: nil
        case .high: 8_000_000
        case .standard: 3_000_000
        }
    }

    var maxSize: (width: Int, height: Int)? {
        switch self {
        case .original: nil
        case .high: (1_920, 1_080)
        case .standard: (1_280, 720)
        }
    }

    static let audioBitrate = 256_000

    /// Stored size for the original, bitrate times runtime for a transcode.
    func estimatedBytes(sourceSize: Int64?, runTimeTicks: Int64?) -> Int64? {
        guard let videoBitrate else { return sourceSize }
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        let seconds = Double(runTimeTicks) / Double(Ticks.perSecond)
        return Int64(Double(videoBitrate + Self.audioBitrate) / 8 * seconds)
    }

    /// A transcode no smaller than the original is pointless, so the
    /// original is fetched instead (the fast path).
    func effective(sourceSize: Int64?, runTimeTicks: Int64?) -> DownloadQuality {
        guard self != .original, let sourceSize, sourceSize > 0,
              let estimate = estimatedBytes(sourceSize: sourceSize, runTimeTicks: runTimeTicks) else {
            return self
        }
        return sourceSize <= estimate ? .original : self
    }
}

/// One title on disk or on its way. Carries enough metadata for the
/// Downloads screen to render without decoding the item snapshot.
nonisolated struct DownloadEntry: Codable, Identifiable, Hashable, Sendable {
    enum State: String, Codable, Sendable {
        case queued
        case downloading
        case paused
        case failed
        case complete
    }

    var id: String { itemID }
    let itemID: String
    let type: MediaItemType
    let title: String
    let seriesID: String?
    let seriesName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let productionYear: Int?
    let runTimeTicks: Int64?
    let requestedQuality: DownloadQuality
    /// What is fetched, after the original fast path.
    let quality: DownloadQuality
    let fileName: String
    let mediaSourceID: String
    let eTag: String?
    var expectedBytes: Int64?
    var receivedBytes: Int64 = 0
    var state: State = .queued
    var failure: String?
    /// Set while a task is in flight so a relaunch can re-adopt it.
    var taskIdentifier: Int?
    /// New on every `start`/`resume` and carried in the task description,
    /// so reports from a replaced attempt are dropped. Optional for older
    /// manifests.
    var attemptToken: String?
    /// Its own file because it can be megabytes. Only for `.original`: the
    /// transcode endpoint has no range support, so resuming would append a
    /// second encode.
    var resumeDataFile: String?
    /// Authoritative until the server hears about it.
    var localPositionTicks: Int64?
    /// "imageItemID/ImageType" from the server image URL (an episode's
    /// series poster is keyed by the series) to file name.
    var artworkFiles: [String: String] = [:]
    let createdAt: Date
    var completedAt: Date?

    var isComplete: Bool { state == .complete }
    var isActive: Bool { state == .queued || state == .downloading }
    /// A transcode has no resume data, so resuming starts from byte zero.
    var resumesFromStart: Bool { quality != .original }

    var fractionComplete: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    var episodeLabel: String? {
        guard type == .episode, let seasonNumber, let episodeNumber else { return nil }
        return "S\(seasonNumber) E\(episodeNumber)"
    }
}

/// An offline session's stop report, sent on reconnect.
nonisolated struct PendingPlaybackReport: Codable, Hashable, Sendable {
    let itemID: String
    let mediaSourceID: String
    let positionTicks: Int64
    let createdAt: Date
}

/// The per-account download state machine, pure so it is unit-tested
/// without a session, disk or clock.
nonisolated struct DownloadManifest: Codable, Equatable, Sendable {
    var entries: [DownloadEntry] = []
    var pendingReports: [PendingPlaybackReport] = []

    func entry(for itemID: String) -> DownloadEntry? {
        entries.first { $0.itemID == itemID }
    }

    func isComplete(_ itemID: String) -> Bool {
        entry(for: itemID)?.isComplete ?? false
    }

    /// Counts partial transfers.
    var storageUsed: Int64 {
        entries.reduce(0) { $0 + $1.receivedBytes }
    }

    var completedCount: Int {
        entries.filter(\.isComplete).count
    }

    mutating func insert(_ entry: DownloadEntry) {
        entries.removeAll { $0.itemID == entry.itemID }
        entries.append(entry)
    }

    @discardableResult
    mutating func remove(_ itemID: String) -> DownloadEntry? {
        guard let index = entries.firstIndex(where: { $0.itemID == itemID }) else { return nil }
        return entries.remove(at: index)
    }

    @discardableResult
    mutating func update(_ itemID: String, _ change: (inout DownloadEntry) -> Void) -> Bool {
        guard let index = entries.firstIndex(where: { $0.itemID == itemID }) else { return false }
        change(&entries[index])
        return true
    }

    // MARK: - Transitions

    mutating func markStarted(_ itemID: String, taskIdentifier: Int, attemptToken: String) {
        update(itemID) {
            $0.taskIdentifier = taskIdentifier
            $0.attemptToken = attemptToken
            $0.state = .downloading
            $0.failure = nil
        }
    }

    /// A no-op unless active: a callback queued before a pause or delete can
    /// land after it and must not un-pause or resurrect the entry.
    mutating func recordProgress(_ itemID: String, received: Int64, expected: Int64?) {
        guard let entry = entry(for: itemID), entry.isActive else { return }
        update(itemID) {
            $0.receivedBytes = received
            if let expected, expected > 0 { $0.expectedBytes = expected }
            $0.state = .downloading
        }
    }

    mutating func markPaused(_ itemID: String, resumeDataFile: String?) {
        guard let entry = entry(for: itemID), !entry.isComplete else { return }
        update(itemID) {
            $0.taskIdentifier = nil
            $0.resumeDataFile = resumeDataFile
            $0.state = .paused
            // Clear any error a late cancel callback left.
            $0.failure = nil
        }
    }

    mutating func markFailed(_ itemID: String, reason: String, resumeDataFile: String?) {
        guard let entry = entry(for: itemID), !entry.isComplete else { return }
        update(itemID) {
            $0.taskIdentifier = nil
            if let resumeDataFile { $0.resumeDataFile = resumeDataFile }
            // A failed resume reports its error but stays paused.
            if $0.state != .paused { $0.state = .failed }
            $0.failure = reason
        }
    }

    mutating func markComplete(_ itemID: String, bytes: Int64, at date: Date) {
        update(itemID) {
            $0.taskIdentifier = nil
            $0.resumeDataFile = nil
            $0.receivedBytes = bytes
            $0.expectedBytes = bytes
            $0.state = .complete
            $0.failure = nil
            $0.completedAt = date
        }
    }

    mutating func recordPosition(_ itemID: String, ticks: Int64?) {
        update(itemID) { $0.localPositionTicks = ticks }
    }

    /// After a relaunch: live tasks are re-adopted; a file already in
    /// `completedFiles` finished while suspended and becomes `.complete`;
    /// the rest become paused if they hold resume data, else failed.
    /// Returns only the lost ids.
    @discardableResult
    mutating func reconcile(
        liveTasks: [String: Int], completedFiles: [String: Int64] = [:],
        queriedAttempts: [String: String]? = nil
    ) -> [String] {
        var lost: [String] = []
        for entry in entries where entry.isActive {
            // Skip attempts started after the task snapshot was taken.
            if let queriedAttempts, queriedAttempts[entry.itemID] != (entry.attemptToken ?? "") { continue }
            if let taskIdentifier = liveTasks[entry.itemID] {
                update(entry.itemID) { $0.taskIdentifier = taskIdentifier }
            } else if let bytes = completedFiles[entry.itemID] {
                markComplete(entry.itemID, bytes: bytes, at: Date())
            } else {
                lost.append(entry.itemID)
                update(entry.itemID) {
                    $0.taskIdentifier = nil
                    if $0.resumeDataFile != nil {
                        $0.state = .paused
                    } else {
                        $0.state = .failed
                        $0.failure = "Transfer lost across relaunch"
                    }
                }
            }
        }
        return lost
    }

    // MARK: - Pending reports

    /// One pending report per item: the newest position wins.
    mutating func enqueue(_ report: PendingPlaybackReport) {
        pendingReports.removeAll { $0.itemID == report.itemID }
        pendingReports.append(report)
    }

    mutating func removePendingReport(_ report: PendingPlaybackReport) {
        pendingReports.removeAll { $0 == report }
    }
}

/// Matches a server image URL to saved artwork. Platform-independent so it
/// is testable without the iOS-only store.
nonisolated enum DownloadArtworkKey {
    /// Reads `Items/{imageItemID}/Images/{Type}`. `Type` can contain a slash
    /// (`Backdrop/0`), so everything after "Images" is one value. The query
    /// (image size) is ignored.
    static func parse(_ url: URL) -> (imageItemID: String, type: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let itemsIndex = parts.firstIndex(of: "Items"),
              itemsIndex + 3 < parts.count,
              parts[itemsIndex + 2] == "Images" else { return nil }
        let type = parts[(itemsIndex + 3)...].joined(separator: "/")
        return (parts[itemsIndex + 1], type)
    }

    /// Case-insensitive key shared by `DownloadEntry.artworkFiles` and the
    /// artwork index.
    static func indexKey(imageItemID: String, type: String) -> String {
        "\(imageItemID)/\(type)".lowercased()
    }
}

/// Carried in a task's `taskDescription` so a callback can find its
/// destination and current attempt, even after a relaunch or for an
/// inactive account.
nonisolated struct DownloadTaskDescription: Equatable, Sendable {
    let itemID: String
    let fileName: String
    let accountKey: String
    let attemptToken: String

    var raw: String { "\(itemID)|\(fileName)|\(accountKey)|\(attemptToken)" }

    static func parse(_ description: String?) -> DownloadTaskDescription? {
        guard let description else { return nil }
        let parts = description.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        return DownloadTaskDescription(itemID: parts[0], fileName: parts[1], accountKey: parts[2], attemptToken: parts[3])
    }
}

/// Decided in one place so the delegate's synchronous write and the store's
/// reporting always agree.
nonisolated enum DownloadCompletion {
    enum Outcome: Equatable {
        case complete(bytes: Int64)
        case failed(reason: String)
    }

    /// Only an original is size-checked: a transcode has no reliable
    /// expected size.
    static func outcome(status: Int, bytesOnDisk: Int64, expectedBytes: Int64?, quality: DownloadQuality) -> Outcome {
        guard (200...299).contains(status) else {
            return .failed(reason: status == 403 ? "Not permitted by the server" : "HTTP \(status)")
        }
        guard bytesOnDisk > 0 else { return .failed(reason: "Incomplete file") }
        if quality == .original, let expectedBytes, expectedBytes > 0, expectedBytes != bytesOnDisk {
            return .failed(reason: "Incomplete file")
        }
        return .complete(bytes: bytesOnDisk)
    }
}

/// Short localized text for a transport failure, instead of raw `NSError`.
nonisolated enum DownloadTransportFailure {
    private static let log = Logger(subsystem: "ee.helop.lagoon", category: "downloads")

    /// Cancelled maps to nil: it is always a pause or delete already recorded.
    static func failureDescription(domain: String, code: Int) -> String? {
        log.error("transport failure \(domain, privacy: .public) \(code)")
        switch (domain, code) {
        case (NSURLErrorDomain, NSURLErrorCancelled):
            return nil
        case (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorNotConnectedToInternet),
             (NSURLErrorDomain, NSURLErrorTimedOut):
            return String(localized: "Connection lost")
        case (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorCannotConnectToHost):
            return String(localized: "Server unreachable")
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError):
            return String(localized: "Not enough space")
        default:
            return String(localized: "Download failed")
        }
    }
}
