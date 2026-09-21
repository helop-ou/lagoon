#if DEBUG
import Foundation

/// `-debug.regressionResetState YES`, honoured only next to
/// `-debug.regressionBootstrapPublicDemo YES`: before the session restores
/// anything, drop every account- and server-scoped record a previous run on
/// this simulator left behind, so the regression lane starts from the same
/// state every time (audit A18).
///
/// Scoped on purpose. What goes: the stored accounts and the active one, the
/// mid-connect server, every per-account preference (libraries, home rows,
/// subtitle and track preferences, recent searches), the Seerr server keyed
/// by Jellyfin server URL and its pending-removal bookkeeping, and every
/// keychain item of this app's service except the device id. What stays:
/// app-wide settings such as skip mode, autoplay and caption style, which
/// the lane sets through launch arguments when it cares, and the debug
/// switches themselves — those live in the argument domain, which
/// `removeObject` never touches.
///
/// This wipes real sign-ins. Only the public-demo lane passes the flag, and
/// that lane must never run on a simulator whose accounts anyone wants to
/// keep.
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
