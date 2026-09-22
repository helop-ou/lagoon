import Foundation

/// Removes data left by the retired direct OpenSubtitles integration. Runs on
/// every launch: it is cheap and harmless to repeat, so there is no marker.
nonisolated enum RetiredSubtitleProviderCleanup {
    static let keychainAccount = "lagoon.opensubtitles.token"
    static let defaultsKeys = [
        "subtitles.openSubtitlesAccountName",
        "subtitles.openSubtitlesAPIKey",
        "subtitles.source",
    ]
    /// Under Caches.
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
