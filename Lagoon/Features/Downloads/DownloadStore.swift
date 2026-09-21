#if os(iOS)
import CryptoKit
import Foundation
import Observation
import os

/// Owns offline downloads on iPhone and iPad: the per-account
/// manifest on disk, the one background `URLSession` that carries every
/// transfer, the item snapshot and artwork saved beside each file, and the
/// stop reports kept for a server that could not be reached.
///
/// Files live under Application Support, excluded from backup, in a
/// directory per account keyed by `accountKey(for:)`, so removing an
/// account removes its downloads (`removeAll(forAccountKey:)`, called from
/// `AccountLocalData.beginRemoval`). tvOS has no persistent storage
/// guarantee and no downloads.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()
    static let sessionIdentifier = "ee.helop.lagoon.downloads"
    nonisolated static let log = Logger(subsystem: "ee.helop.lagoon", category: "downloads")

    /// Local playback of a finished download: the file, the item as the
    /// server described it at download time and the media source whose
    /// streams the file carries.
    struct LocalPlayback {
        let url: URL
        let item: MediaItem
        let source: MediaSource
        /// Original carries the source's streams as described; a transcode
        /// is a different file (H.264 or HEVC, E-AC-3 or AAC, no external
        /// subtitles), so its track metadata comes from probing, not the
        /// source.
        let quality: DownloadQuality
        /// The position recorded by local playback, if any.
        let resumeTicks: Int64?
    }

    /// What a download would cost, for the quality picker and the
    /// free-space gate.
    struct Estimate {
        let quality: DownloadQuality
        /// The quality actually fetched after the original fast path.
        let effectiveQuality: DownloadQuality
        let bytes: Int64?
        let freeBytes: Int64?
        /// The estimate does not fit in the free space at all.
        var exceedsFreeSpace: Bool {
            guard let bytes, let freeBytes else { return false }
            return bytes >= freeBytes
        }
        /// The estimate takes more than half of what is free: worth a
        /// confirmation before it starts.
        var isLarge: Bool {
            guard let bytes, let freeBytes else { return false }
            return bytes * 2 > freeBytes
        }
    }

    /// The active account's manifest; empty while signed out. Not
    /// `private(set)`: the transfer and file-handling extensions in this
    /// folder mutate it directly through `DownloadManifest`'s transition
    /// methods, then call `save()`.
    var manifest = DownloadManifest()
    /// The account whose downloads are loaded, as `StoredAccount.id`.
    private(set) var accountID: String?
    @ObservationIgnored private var activeOwner: ObjectIdentifier?
    /// `accountKey(for:)` of the active account; nil while signed out.
    private(set) var accountKey: String?
    /// The active account's downloads directory; nil while signed out.
    private(set) var accountDirectory: URL?
    @ObservationIgnored private(set) var accountGeneration = 0
    /// The commands extension owns preparation until URLSession takes over.
    /// A newer start or delete invalidates an older start across its awaits.
    @ObservationIgnored var preparationTokens: [String: UUID] = [:]
    /// Whether the active account may download at all, as last learned from
    /// the server; nil until asked. Observable state of the store rather
    /// than `DownloadControl`'s own, because a control with nothing to show
    /// renders no view and a task attached to no view never runs: left to
    /// itself the control could never resolve the permission that would
    /// make it appear. Refreshed on activation and each detail page load.
    private(set) var permitted: Bool?
    /// Every account's downloads: `Application Support/Lagoon/Downloads`.
    let baseDirectory: URL
    /// The one background session that carries every transfer, for every
    /// account, for the life of the process.
    let session: URLSession
    let delegate: SessionDelegate

    /// `snapshotItem(for:)` decodes a saved item from disk; a row body reads
    /// it on every draw, so results are kept here until the item they
    /// belong to changes.
    @ObservationIgnored var snapshotCache: [String: MediaItem] = [:]
    /// The last time a progress-only save reached disk, so `saveProgressThrottled`
    /// can coalesce the callbacks a fast transfer produces.
    @ObservationIgnored var lastProgressSaveDate: Date?
    /// Resumed once `urlSessionDidFinishEvents` reports every background
    /// callback delivered, or after a timeout if it never does, so the
    /// app's background task can wait for on-disk state to catch up before
    /// the OS suspends it.
    @ObservationIgnored private var backgroundEventsContinuation: CheckedContinuation<Void, Never>?

    var entries: [DownloadEntry] { manifest.entries }
    var storageUsed: Int64 { manifest.storageUsed }
    var completedCount: Int { manifest.completedCount }

    init() {
        defaultQuality = DownloadQuality(rawValue: UserDefaults.standard.string(forKey: Self.defaultQualityKey) ?? "") ?? .high
        wifiOnly = UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true

        let downloads = Self.downloadsRootDirectory()
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        Self.excludeFromBackup(downloads)
        baseDirectory = downloads

        let delegate = SessionDelegate()
        self.delegate = delegate

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // A progressive transcode is one response that lasts as long as the
        // encode; the resource timeout must outlast a film.
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        configuration.timeoutIntervalForRequest = 10 * 60
        // Keep delegate callbacks on the main executor. DownloadStore is MainActor-owned,
        // and completion must validate the attempt and move its file as one
        // serialized operation with delete/start commands.
        let delegateQueue = OperationQueue.main
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    // MARK: - Settings

    /// The quality picked by default; Original is never the default. A
    /// stored property (not computed over `UserDefaults`) so `@Observable`
    /// can track reads of it: a computed property is invisible to
    /// Observation, and the settings page never redrew when it changed.
    var defaultQuality: DownloadQuality {
        didSet { UserDefaults.standard.set(defaultQuality.rawValue, forKey: Self.defaultQualityKey) }
    }

    /// Whether new transfers may use cellular and other expensive paths.
    /// Stored for the same reason as `defaultQuality` above.
    var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Self.wifiOnlyKey) }
    }

    static let defaultQualityKey = "downloads.defaultQuality"
    static let wifiOnlyKey = "downloads.wifiOnly"

    // MARK: - Account

    /// Loads the manifest for an account, or clears it for nil. Called by
    /// `SessionStore` whenever the active account changes.
    func activate(accountID: String?) {
        activate(accountID: accountID, owner: nil)
    }

    /// `owner` identifies the session store making the call. SwiftUI can
    /// construct a root view's state object more than once and keep only
    /// the first, and every extra `SessionStore` restores nothing and
    /// announces a nil account: such a call must not clear downloads the
    /// real store activated, so a nil activation only counts from the
    /// owner that activated the current account.
    func activate(accountID: String?, owner: ObjectIdentifier?) {
        if accountID == nil, let activeOwner, owner != activeOwner { return }
        if accountID != nil { activeOwner = owner }
        guard accountID != self.accountID else { return }
        accountGeneration &+= 1
        preparationTokens.removeAll()
        save()
        self.accountID = accountID
        permitted = nil
        // Every cached snapshot belongs to the account that is leaving.
        snapshotCache.removeAll()

        guard let accountID else {
            accountKey = nil
            accountDirectory = nil
            manifest = DownloadManifest()
            DownloadArtworkIndex.shared.clear()
            return
        }

        let key = Self.accountKey(for: accountID)
        accountKey = key
        let directory = baseDirectory.appending(path: key, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        accountDirectory = directory
        manifest = Self.loadManifest(at: directory.appending(path: "manifest.json"))
        rebuildArtworkIndex()
        reconcileLiveTasks(accountKey: key)
    }

    /// The filesystem-safe key of an account id (`StoredAccount.id` embeds a
    /// URL): the first 32 hex characters of its SHA-256 digest.
    nonisolated static func accountKey(for accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    /// Deletes every download and manifest of an account. Safe to call for
    /// an account that never downloaded anything. Cancels every live
    /// transfer for the account first: the session is shared across
    /// accounts and outlives this call, so a task left running would keep
    /// writing into a directory that is about to disappear.
    func removeAll(forAccountKey key: String) {
        if accountKey == key {
            accountGeneration &+= 1
            preparationTokens.removeAll()
        }
        Task { @MainActor in
            let tasks = await self.session.allTasks
            for task in tasks where DownloadTaskDescription.parse(task.taskDescription)?.accountKey == key {
                task.cancel()
            }
            let directory = Self.downloadsRootDirectory().appending(path: key, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: directory)
            // The account being wiped might still be the active one if this
            // runs ahead of `SessionStore`'s own nil-activation; drop the
            // in-memory manifest too so nothing still points at deleted files.
            guard self.accountKey == key else { return }
            self.manifest = DownloadManifest()
            self.snapshotCache.removeAll()
            DownloadArtworkIndex.shared.clear()
        }
    }

    // MARK: - Reading

    func entry(for itemID: String) -> DownloadEntry? {
        manifest.entry(for: itemID)
    }

    func isDownloaded(_ itemID: String) -> Bool {
        manifest.isComplete(itemID)
    }

    /// The item as the server described it at download time, for a detail
    /// page reached from the Downloads screen without a server. Memoized:
    /// a row body calls this on every draw, and decoding from disk each
    /// time showed up as real cost in a long downloads list. The cache is
    /// cleared wherever the item on disk can change: `activate`, `delete`,
    /// `start`.
    func snapshotItem(for itemID: String) -> MediaItem? {
        if let cached = snapshotCache[itemID] { return cached }
        guard let accountDirectory else { return nil }
        let url = accountDirectory.appending(path: "\(itemID).item.json")
        guard let data = try? Data(contentsOf: url),
              let item = try? JellyfinClient.decoder.decode(MediaItem.self, from: data) else { return nil }
        snapshotCache[itemID] = item
        return item
    }

    /// A finished download that is still on disk, ready to play.
    func localPlayback(for itemID: String) -> LocalPlayback? {
        guard let entry = manifest.entry(for: itemID), entry.isComplete,
              let accountDirectory else { return nil }
        let fileURL = accountDirectory.appending(path: entry.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let item = snapshotItem(for: itemID) else { return nil }
        let source = item.mediaSources?.first { $0.id == entry.mediaSourceID } ?? item.mediaSources?.first
        guard let source else { return nil }
        return LocalPlayback(url: fileURL, item: item, source: source, quality: entry.quality, resumeTicks: entry.localPositionTicks)
    }

    /// A poster or backdrop saved beside a download, matched against the
    /// server image URL a view would otherwise fetch, so every card and
    /// page shows a downloaded title's artwork offline.
    nonisolated static func localArtworkURL(matching serverURL: URL) -> URL? {
        guard let key = DownloadArtworkKey.parse(serverURL) else { return nil }
        return DownloadArtworkIndex.shared.url(imageItemID: key.imageItemID, type: key.type)
    }

    /// Whether the signed-in user may download at all: the server's
    /// "Allow media downloading" policy. Hides the control rather than
    /// letting the server refuse.
    func canDownload(client: JellyfinClient) async -> Bool {
        await client.canDownloadContent()
    }

    /// Re-asks the server whether the account may download, for a
    /// permission an administrator could have turned on after sign-in, and
    /// publishes the answer for every `DownloadControl`. Unreachable and
    /// never learned both mean no, as `canDownloadContent()` reasons.
    func refreshPermission(client: JellyfinClient) async {
        let generation = accountGeneration
        let account = accountKey
        let value = await client.refreshContentDownloadingPermission() ?? false
        // A permission response belongs to the account that requested it;
        // never publish it after a switch or sign-out, even if that switch
        // briefly returned to the same account key.
        guard generation == accountGeneration, account == accountKey else { return }
        permitted = value
    }

    /// Bytes free for user content on the device volume.
    func freeSpace() -> Int64? {
        guard let directory = accountDirectory ?? baseDirectory as URL? else { return nil }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func estimate(for item: MediaItem, source: MediaSource, quality: DownloadQuality) -> Estimate {
        let effective = quality.effective(sourceSize: source.size, runTimeTicks: source.runTimeTicks ?? item.runTimeTicks)
        return Estimate(
            quality: quality,
            effectiveQuality: effective,
            bytes: effective.estimatedBytes(sourceSize: source.size, runTimeTicks: source.runTimeTicks ?? item.runTimeTicks),
            freeBytes: freeSpace()
        )
    }

    // MARK: - Commands

    enum StartError: Error {
        case notSignedIn
        case accountChanged
        case notPermitted
        case noSpace
        case unsupportedItem
    }

    // `start`, `pause`, `resume`, `delete` and `deleteAll` are implemented
    // in `DownloadStore+Transfers.swift`, along with the background session
    // delegate that drives them.

    // MARK: - Background session lifecycle

    /// Waits for every callback the background session already queued for
    /// this launch to reach the manifest on disk, so `LagoonApp`'s
    /// `.backgroundTask(.urlSession(...))` body has something durable to
    /// show before the OS can suspend the app.
    /// Falls back to a timeout: a background relaunch that never calls
    /// `urlSessionDidFinishEvents` must not hang the background task
    /// forever.
    func finishBackgroundEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if let existing = backgroundEventsContinuation {
                backgroundEventsContinuation = nil
                existing.resume()
            }
            backgroundEventsContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self.resumeBackgroundEventsContinuationIfNeeded()
            }
        }
    }

    /// Called from `SessionDelegate.urlSessionDidFinishEvents`.
    func resumeBackgroundEventsContinuationIfNeeded() {
        guard let backgroundEventsContinuation else { return }
        self.backgroundEventsContinuation = nil
        backgroundEventsContinuation.resume()
    }

    // MARK: - Playback

    /// The resume point of local playback; nil once played through.
    func recordPosition(itemID: String, ticks: Int64?) {
        manifest.recordPosition(itemID, ticks: ticks)
        save()
    }

    /// A stop report the server could not be given now; flushed later.
    func enqueuePendingReport(_ report: PendingPlaybackReport) {
        manifest.enqueue(report)
        save()
    }

    // `flushPendingReports` is implemented in `DownloadStore+Transfers.swift`.
}
#endif
