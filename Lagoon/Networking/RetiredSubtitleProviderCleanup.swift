import Foundation

/// Removes what the direct OpenSubtitles integration left behind on devices
/// that ran builds 87–91. HEL-146 retired that path in favour of Jellyfin's
/// own subtitle search, so nothing reads these values any more; they must not
/// outlive the code that wrote them. Runs on every launch: four removals and a
/// directory check are cheaper than a marker, and repeating them is harmless.
nonisolated enum RetiredSubtitleProviderCleanup {
    static let keychainAccount = "lagoon.opensubtitles.token"
    static let defaultsKeys = [
        "subtitles.openSubtitlesAccountName",
        "subtitles.openSubtitlesAPIKey",
        "subtitles.source",
    ]
    /// Provider sidecars were cached under Caches/Lagoon/Subtitles.
    static let cacheSubdirectory = "Lagoon/Subtitles"

    static func run(defaults: UserDefaults, credentials: any AccountCredentialStorage, cachesDirectory: URL?) {
        try? credentials.delete(keychainAccount)
        for key in defaultsKeys {
            defaults.removeObject(forKey: key)
        }
        guard let cachesDirectory else { return }
        let directory = cachesDirectory.appending(path: cacheSubdirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
