import Foundation
import os

/// What a viewer asks for when taking a title off the server (HEL-166).
/// Original is the file as stored; the other two are the server's
/// progressive transcode under a bitrate and size cap, so a 30 GB 4K remux
/// never lands on a phone unless asked for by name.
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

    /// The transcode's video bitrate cap; nil for the original.
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

    /// The transcode's audio bitrate, part of every estimate.
    static let audioBitrate = 256_000

    /// Bytes the download is expected to take: the stored size for the
    /// original, bitrate times runtime for a transcode. Nil when the source
    /// carries neither.
    func estimatedBytes(sourceSize: Int64?, runTimeTicks: Int64?) -> Int64? {
        guard let videoBitrate else { return sourceSize }
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        let seconds = Double(runTimeTicks) / Double(Ticks.perSecond)
        return Int64(Double(videoBitrate + Self.audioBitrate) / 8 * seconds)
    }

    /// The quality that is actually fetched: a transcode whose estimate is
    /// no smaller than the original is pointless, so the original is taken
    /// directly (the fast path). Original stays original.
    func effective(sourceSize: Int64?, runTimeTicks: Int64?) -> DownloadQuality {
        guard self != .original, let sourceSize, sourceSize > 0,
              let estimate = estimatedBytes(sourceSize: sourceSize, runTimeTicks: runTimeTicks) else {
            return self
        }
        return sourceSize <= estimate ? .original : self
    }
}

/// One title on disk, or on its way there: what was asked for, where it
/// lives and how far it got. Enough listing metadata rides here for the
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
    /// What the viewer chose.
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
    /// A fresh UUID set on every `start`/`resume`, carried in the task
    /// description so a delegate report for an attempt that was replaced
    /// by a newer one (delete-then-restart, or a stale resume) is dropped
    /// instead of landing on the current attempt (HEL-166 review finding
    /// 4). Optional so a manifest saved before this field existed decodes.
    var attemptToken: String?
    /// `resumeData` from a pause or a transport failure, kept as its own
    /// file because it can be megabytes. Only ever set for `.original`:
    /// the transcode endpoint has no range support, so resume data would
    /// append a second encode onto the file (HEL-166 review finding 3).
    var resumeDataFile: String?
    /// The resume point recorded by local playback, authoritative for a
    /// downloaded title until the server hears about it.
    var localPositionTicks: Int64?
    /// Artwork saved beside the file, keyed "imageItemID/ImageType" (the
    /// id and type in the server image URL, so an episode's series poster
    /// is keyed by the series), valued by file name in the account folder.
    var artworkFiles: [String: String] = [:]
    let createdAt: Date
    var completedAt: Date?

    var isComplete: Bool { state == .complete }
    var isActive: Bool { state == .queued || state == .downloading }
    /// Whether a resume of this entry has to start over from byte zero: a
    /// transcode has no resume data to fall back on (HEL-166 review
    /// finding 3), so the paused caption can say so up front.
    var resumesFromStart: Bool { quality != .original }

    /// Progress in 0...1 while the size is known, else nil.
    var fractionComplete: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    /// "S1 E3" for an episode, nil otherwise.
    var episodeLabel: String? {
        guard type == .episode, let seasonNumber, let episodeNumber else { return nil }
        return "S\(seasonNumber) E\(episodeNumber)"
    }
}

/// A stop report the server could not be given at the time, kept until it
/// can: the resume position of an offline session reaches the server on
/// reconnect.
nonisolated struct PendingPlaybackReport: Codable, Hashable, Sendable {
    let itemID: String
    let mediaSourceID: String
    let positionTicks: Int64
    let createdAt: Date
}

/// The per-account list of downloads and its transitions, kept pure so the
/// state machine is unit-tested without a session, a disk or a clock. The
/// store persists it and drives the transfers.
nonisolated struct DownloadManifest: Codable, Equatable, Sendable {
    var entries: [DownloadEntry] = []
    var pendingReports: [PendingPlaybackReport] = []

    func entry(for itemID: String) -> DownloadEntry? {
        entries.first { $0.itemID == itemID }
    }

    func isComplete(_ itemID: String) -> Bool {
        entry(for: itemID)?.isComplete ?? false
    }

    /// Bytes on disk, counting partial transfers.
    var storageUsed: Int64 {
        entries.reduce(0) { $0 + $1.receivedBytes }
    }

    var completedCount: Int {
        entries.filter(\.isComplete).count
    }

    /// Adds an entry, replacing any earlier one for the same item.
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

    /// A no-op once the entry is paused or complete: a progress callback
    /// queued before a pause or a delete can still land after it, and must
    /// not un-pause the entry or resurrect a byte count for a title that
    /// no longer exists (HEL-166 review finding 6).
    mutating func recordProgress(_ itemID: String, received: Int64, expected: Int64?) {
        guard let entry = entry(for: itemID), entry.state != .paused, entry.state != .complete else { return }
        update(itemID) {
            $0.receivedBytes = received
            if let expected, expected > 0 { $0.expectedBytes = expected }
            $0.state = .downloading
        }
    }

    mutating func markPaused(_ itemID: String, resumeDataFile: String?) {
        update(itemID) {
            $0.taskIdentifier = nil
            $0.resumeDataFile = resumeDataFile
            $0.state = .paused
            // A late failure callback for the same cancel must not leave a
            // stale error string sitting under a deliberate pause (HEL-166
            // review finding 6).
            $0.failure = nil
        }
    }

    mutating func markFailed(_ itemID: String, reason: String, resumeDataFile: String?) {
        update(itemID) {
            $0.taskIdentifier = nil
            if let resumeDataFile { $0.resumeDataFile = resumeDataFile }
            // A pause that races its own failure callback stays a pause.
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

    /// After a relaunch: entries whose task the system kept running are
    /// re-adopted; an entry whose file is already on disk under
    /// `completedFiles` finished while the process was suspended before it
    /// could record that itself, so it is promoted straight to `.complete`
    /// with the file's own byte count rather than demoted to failed
    /// (HEL-166 review finding 1); the store computes this set from the
    /// account directory, keeping this method free of disk access. The
    /// rest of the in-flight entries become paused when they hold resume
    /// data, otherwise failed. Returns the ids that were actually lost,
    /// not the ones recovered as complete.
    @discardableResult
    mutating func reconcile(liveTasks: [String: Int], completedFiles: [String: Int64] = [:]) -> [String] {
        var lost: [String] = []
        for entry in entries where entry.isActive {
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

/// Where a server image URL points, for matching a downloaded title's saved
/// artwork back to whatever a view would otherwise fetch over the network
/// (HEL-166). Pure and platform-independent so the parser is pinned down by
/// a test without an iOS-only store.
nonisolated enum DownloadArtworkKey {
    /// Reads `Items/{imageItemID}/Images/{Type}`. `Type` can itself carry a
    /// slash (a backdrop's is `Backdrop/0`), so everything after "Images"
    /// is taken as one value rather than a single path component; the query
    /// string is ignored, since a viewer can ask for the same image at any
    /// size.
    static func parse(_ url: URL) -> (imageItemID: String, type: String)? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let itemsIndex = parts.firstIndex(of: "Items"),
              itemsIndex + 3 < parts.count,
              parts[itemsIndex + 2] == "Images" else { return nil }
        let type = parts[(itemsIndex + 3)...].joined(separator: "/")
        return (parts[itemsIndex + 1], type)
    }

    /// The key `DownloadEntry.artworkFiles` and the artwork index agree on:
    /// case-insensitive, since a saved file and a freshly built server URL
    /// only need to agree on spelling, not case.
    static func indexKey(imageItemID: String, type: String) -> String {
        "\(imageItemID)/\(type)".lowercased()
    }
}

/// The four fields threaded through a background download task's
/// `taskDescription`: everything a delegate callback needs to find a
/// finished transfer's destination and confirm the report still belongs
/// to the attempt that is current, even for an event delivered after a
/// relaunch or for a different account than the one active in the process
/// (HEL-166 review finding 4/12).
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

/// Whether a finished download task actually succeeded, decided once so
/// the delegate's synchronous write (which can run without the store
/// active) and the store's own reporting path always agree (HEL-166
/// review finding 12).
nonisolated enum DownloadCompletion {
    enum Outcome: Equatable {
        case complete(bytes: Int64)
        case failed(reason: String)
    }

    /// An HTTP 403 means the server refused the permission mid-transfer,
    /// any other non-2xx is a plain failure, and an original whose size
    /// does not match what was expected is an incomplete file; a
    /// transcode has no reliable expected size to compare against, so any
    /// size is accepted once the status is good.
    static func outcome(status: Int, bytesOnDisk: Int64, expectedBytes: Int64?, quality: DownloadQuality) -> Outcome {
        guard (200...299).contains(status) else {
            return .failed(reason: status == 403 ? "Not permitted by the server" : "HTTP \(status)")
        }
        if quality == .original, let expectedBytes, expectedBytes > 0, expectedBytes != bytesOnDisk {
            return .failed(reason: "Incomplete file")
        }
        return .complete(bytes: bytesOnDisk)
    }
}

/// Short, localized copy for a transport failure a viewer might see next
/// to a stalled download, in place of raw `NSError` text like "NSURLErrorDomain
/// -1005" (HEL-166 review finding 7).
nonisolated enum DownloadTransportFailure {
    private static let log = Logger(subsystem: "ee.helop.lagoon", category: "downloads")

    /// `cancelled` deliberately maps to no text at all: it is always the
    /// tail end of a pause or a delete the store already recorded, never a
    /// failure in its own right.
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
