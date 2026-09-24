#if os(iOS)
import CryptoKit
import Foundation
import Observation
import os

/// Owns offline downloads on iPhone and iPad: the per-account manifest, the
/// one background `URLSession`, the item snapshot and artwork beside each
/// file, and stop reports queued for an unreachable server.
///
/// Files live in Application Support, excluded from backup, one directory
/// per account. tvOS has no persistent storage guarantee and no downloads.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()
    static let sessionIdentifier = "ee.helop.lagoon.downloads"
    nonisolated static let log = Logger(subsystem: "ee.helop.lagoon", category: "downloads")

    /// A finished download: the file, the item as saved at download time and
    /// the media source the file carries.
    struct LocalPlayback {
        let url: URL
        let item: MediaItem
        let source: MediaSource
        /// Original carries the source's streams; a transcode is a different
        /// file, so its track metadata comes from probing, not the source.
        let quality: DownloadQuality
        let resumeTicks: Int64?
    }

    /// What a download would cost, for the quality picker and the
    /// free-space gate.
    struct Estimate {
        let bytes: Int64?
        let freeBytes: Int64?
        var exceedsFreeSpace: Bool {
            guard let bytes, let freeBytes else { return false }
            return bytes >= freeBytes
        }
        /// More than half the free space: confirm before starting.
        var isLarge: Bool {
            guard let bytes, let freeBytes else { return false }
            return bytes * 2 > freeBytes
        }
    }

    /// Empty while signed out. Not `private(set)`: the extensions in this
    /// folder mutate it through `DownloadManifest`'s transitions, then `save()`.
    var manifest = DownloadManifest()
    /// `StoredAccount.id` of the loaded account.
    private(set) var accountID: String?
    @ObservationIgnored private var activeOwner: ObjectIdentifier?
    private(set) var accountKey: String?
    private(set) var accountDirectory: URL?
    @ObservationIgnored private(set) var accountGeneration = 0
    /// A newer start or delete invalidates an older start across its awaits.
    @ObservationIgnored var preparationTokens: [String: UUID] = [:]
    /// Whether the account may download; nil until asked. Lives here, not in
    /// `DownloadControl`: a control with nothing to show renders no view, so
    /// its own task would never run to resolve the permission.
    private(set) var permitted: Bool?
    /// `Application Support/Lagoon/Downloads`.
    let baseDirectory: URL
    /// Shared by every account for the life of the process.
    let session: URLSession
    let delegate: SessionDelegate

    /// Row bodies call `snapshotItem(for:)` on every draw; decoding from disk
    /// each time is too slow.
    @ObservationIgnored var snapshotCache: [String: MediaItem] = [:]
    @ObservationIgnored var lastProgressSaveDate: Date?
    /// Lets the app's background task wait for on-disk state before the OS
    /// suspends it.
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
        // Main-queue callbacks: completion must validate and move its file
        // serialized with delete/start commands.
        let delegateQueue = OperationQueue.main
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }

    // MARK: - Settings

    /// Original is never the default. Stored, not computed over
    /// `UserDefaults`, so Observation sees changes.
    var defaultQuality: DownloadQuality {
        didSet { UserDefaults.standard.set(defaultQuality.rawValue, forKey: Self.defaultQualityKey) }
    }

    /// Whether new transfers avoid cellular and other expensive paths.
    var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Self.wifiOnlyKey) }
    }

    static let defaultQualityKey = "downloads.defaultQuality"
    static let wifiOnlyKey = "downloads.wifiOnly"

    // MARK: - Account

    /// SwiftUI can construct extra `SessionStore`s that announce a nil
    /// account, so a nil activation only counts from the owner that
    /// activated the current account.
    func activate(accountID: String?, owner: ObjectIdentifier?) {
        if accountID == nil, let activeOwner, owner != activeOwner { return }
        if accountID != nil { activeOwner = owner }
        guard accountID != self.accountID else { return }
        accountGeneration &+= 1
        preparationTokens.removeAll()
        save()
        self.accountID = accountID
        permitted = nil
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

    /// Filesystem-safe key for an account id, which embeds a URL.
    nonisolated static func accountKey(for accountID: String) -> String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    /// Deletes an account's downloads. Cancels its transfers first: the
    /// shared session would otherwise keep writing into the deleted directory.
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
            // This can run before `SessionStore`'s nil-activation.
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

    /// The item as saved at download time, for offline detail pages.
    /// Memoized; `activate`, `delete` and `start` clear the cache.
    func snapshotItem(for itemID: String) -> MediaItem? {
        if let cached = snapshotCache[itemID] { return cached }
        guard let accountDirectory else { return nil }
        let url = accountDirectory.appending(path: "\(itemID).item.json")
        guard let data = try? Data(contentsOf: url),
              let item = try? JellyfinClient.decoder.decode(MediaItem.self, from: data) else { return nil }
        snapshotCache[itemID] = item
        return item
    }

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

    /// Saved artwork matching a server image URL, so downloaded titles show
    /// artwork offline.
    nonisolated static func localArtworkURL(matching serverURL: URL) -> URL? {
        guard let key = DownloadArtworkKey.parse(serverURL) else { return nil }
        return DownloadArtworkIndex.shared.url(imageItemID: key.imageItemID, type: key.type)
    }

    /// The server's "Allow media downloading" policy.
    func canDownload(client: JellyfinClient) async -> Bool {
        await client.canDownloadContent()
    }

    /// Re-asks the server, since an admin can grant the permission after
    /// sign-in. Unreachable counts as no.
    func refreshPermission(client: JellyfinClient) async {
        let generation = accountGeneration
        let account = accountKey
        let value = await client.refreshContentDownloadingPermission() ?? false
        // Drop a reply that outlived an account switch, even back to the same key.
        guard generation == accountGeneration, account == accountKey else { return }
        permitted = value
        // The card menu's quality list reads this. Warmed here, once per
        // account, rather than by every card on screen.
        if value, client.cachedVideoTranscodingAllowed == nil {
            await client.refreshVideoTranscodingPermission()
        }
    }

    func freeSpace() -> Int64? {
        guard let directory = accountDirectory ?? baseDirectory as URL? else { return nil }
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func estimate(for item: MediaItem, source: MediaSource, quality: DownloadQuality) -> Estimate {
        let effective = quality.effective(sourceSize: source.size, runTimeTicks: source.runTimeTicks ?? item.runTimeTicks)
        return Estimate(
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

    // MARK: - Background session lifecycle

    /// Waits until the session's queued callbacks reach the manifest on
    /// disk, before the OS suspends the app. Times out, because a relaunch
    /// may never call `urlSessionDidFinishEvents`.
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
}
#endif
