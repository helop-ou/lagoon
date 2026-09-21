#if DEBUG
import Foundation

/// `-debug.regressionResetState YES`, honoured only alongside
/// `-debug.regressionBootstrapPublicDemo YES`: drop every account- and
/// server-scoped record a previous run left, so the lane starts identical.
///
/// Goes: stored accounts, the mid-connect server, per-account preferences, the
/// Seerr server and its bookkeeping, and every keychain item except the device
/// id. Stays: app-wide settings the lane sets by launch argument, and the
/// debug switches — the argument domain, which `removeObject` never touches.
///
/// This wipes real sign-ins. Only the public-demo lane passes the flag.
nonisolated enum RegressionStateReset {
    static let keyPrefixes: [String] = [
        "accounts",
        "session.",
        "server.url",
        "server.name",
        "libraries.",
        "library.selection.",
        "subtitles.preferences.",
        "playback.trackPreferences.",
        ThemeStore.keyPrefix,
        "home.sectionPreferences.",
        "search.recents",
        "seerr.",
    ]

    /// The device id is what Jellyfin knows this simulator as; a fresh one
    /// per run would leave a trail of devices on the server for nothing.
    static let preservedCredentialNames: Set<String> = ["deviceId"]

    static func isRequested(arguments: UserDefaults = .standard) -> Bool {
        arguments.bool(forKey: "debug.regressionResetState")
            && arguments.bool(forKey: "debug.regressionBootstrapPublicDemo")
    }

    struct Removed: Equatable, Sendable {
        var defaultsKeys: [String]
        var credentialNames: [String]
    }

    @discardableResult
    static func run(defaults: UserDefaults, credentials: any AccountCredentialStorage) -> Removed {
        let keys = defaults.dictionaryRepresentation().keys
            .filter { key in keyPrefixes.contains { key.hasPrefix($0) } }
            .sorted()
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        let names = ((try? credentials.accountNames()) ?? [])
            .filter { !preservedCredentialNames.contains($0) }
            .sorted()
        for name in names {
            try? credentials.delete(name)
        }
        return Removed(defaultsKeys: keys, credentialNames: names)
    }
}
#endif
