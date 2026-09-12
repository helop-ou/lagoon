import Foundation

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
    /// `resumeData` from a pause or a transport failure, kept as its own
    /// file because it can be megabytes.
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

    mutating func markStarted(_ itemID: String, taskIdentifier: Int) {
        update(itemID) {
            $0.taskIdentifier = taskIdentifier
            $0.state = .downloading
            $0.failure = nil
        }
    }

    mutating func recordProgress(_ itemID: String, received: Int64, expected: Int64?) {
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
    /// re-adopted; the rest of the in-flight entries become paused when
    /// they hold resume data, otherwise failed. Returns the ids that lost
    /// their task.
    @discardableResult
    mutating func reconcile(liveTasks: [String: Int]) -> [String] {
        var lost: [String] = []
        for entry in entries where entry.isActive {
            if let taskIdentifier = liveTasks[entry.itemID] {
                update(entry.itemID) { $0.taskIdentifier = taskIdentifier }
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
