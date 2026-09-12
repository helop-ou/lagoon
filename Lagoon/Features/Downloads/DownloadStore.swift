#if os(iOS)
import Foundation
import Observation
import os

/// Owns offline downloads on iPhone and iPad (HEL-166): the per-account
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

    /// The active account's manifest; empty while signed out.
    private(set) var manifest = DownloadManifest()
    /// The account whose downloads are loaded, as `StoredAccount.id`.
    private(set) var accountID: String?

    var entries: [DownloadEntry] { manifest.entries }
    var storageUsed: Int64 { manifest.storageUsed }
    var completedCount: Int { manifest.completedCount }

    // MARK: - Settings

    /// The quality picked by default; Original is never the default.
    var defaultQuality: DownloadQuality {
        get { DownloadQuality(rawValue: UserDefaults.standard.string(forKey: Self.defaultQualityKey) ?? "") ?? .high }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.defaultQualityKey) }
    }

    /// Whether new transfers may use cellular and other expensive paths.
    var wifiOnly: Bool {
        get { UserDefaults.standard.object(forKey: Self.wifiOnlyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.wifiOnlyKey) }
    }

    static let defaultQualityKey = "downloads.defaultQuality"
    static let wifiOnlyKey = "downloads.wifiOnly"

    // MARK: - Account

    /// Loads the manifest for an account, or clears it for nil. Called by
    /// `SessionStore` whenever the active account changes.
    func activate(accountID: String?) {
        // Implemented in the store slice.
    }

    /// The filesystem-safe key of an account id (`StoredAccount.id` embeds
    /// a URL).
    nonisolated static func accountKey(for accountID: String) -> String {
        accountID
    }

    /// Deletes every download and manifest of an account. Safe to call for
    /// an account that never downloaded anything.
    nonisolated static func removeAll(forAccountKey key: String) {
        // Implemented in the store slice.
    }

    // MARK: - Reading

    func entry(for itemID: String) -> DownloadEntry? {
        manifest.entry(for: itemID)
    }

    func isDownloaded(_ itemID: String) -> Bool {
        manifest.isComplete(itemID)
    }

    /// The item as the server described it at download time, for a detail
    /// page reached from the Downloads screen without a server.
    func snapshotItem(for itemID: String) -> MediaItem? {
        nil
    }

    /// A finished download that is still on disk, ready to play.
    func localPlayback(for itemID: String) -> LocalPlayback? {
        nil
    }

    /// A poster or backdrop saved beside a download, matched against the
    /// server image URL a view would otherwise fetch, so every card and
    /// page shows a downloaded title's artwork offline.
    nonisolated static func localArtworkURL(matching serverURL: URL) -> URL? {
        nil
    }

    /// Whether the signed-in user may download at all: the server's
    /// "Allow media downloading" policy. Hides the control rather than
    /// letting the server refuse.
    func canDownload(client: JellyfinClient) async -> Bool {
        false
    }

    /// Bytes free for user content on the device volume.
    func freeSpace() -> Int64? {
        nil
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
        case notPermitted
        case noSpace
        case unsupportedItem
    }

    /// Takes a title off the server: saves the item snapshot and artwork,
    /// then hands the transfer to the background session. `item` must
    /// carry media sources (a detail read does; a rail item does not).
    func start(item: MediaItem, source: MediaSource, quality: DownloadQuality, client: JellyfinClient) async throws {
        // Implemented in the store slice.
    }

    func pause(_ itemID: String) {
        // Implemented in the store slice.
    }

    func resume(_ itemID: String, client: JellyfinClient) {
        // Implemented in the store slice.
    }

    /// Cancels a transfer or deletes a finished download, with its files.
    func delete(_ itemID: String) {
        // Implemented in the store slice.
    }

    func deleteAll() {
        // Implemented in the store slice.
    }

    // MARK: - Playback

    /// The resume point of local playback; nil once played through.
    func recordPosition(itemID: String, ticks: Int64?) {
        manifest.recordPosition(itemID, ticks: ticks)
        // Persisted in the store slice.
    }

    /// A stop report the server could not be given now; flushed later.
    func enqueuePendingReport(_ report: PendingPlaybackReport) {
        manifest.enqueue(report)
        // Persisted in the store slice.
    }

    /// Sends every pending report that the server accepts, keeping the rest.
    func flushPendingReports(client: JellyfinClient) async {
        // Implemented in the store slice.
    }
}
#endif
