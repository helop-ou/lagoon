#if DEBUG
import Foundation

/// `-debug.regressionResetState YES`, honoured only with
/// `-debug.regressionBootstrapPublicDemo YES`: drops every account- and
/// server-scoped record and keychain item except the device id, so each run
/// starts identical. Launch arguments survive (`removeObject` never touches
/// that domain).
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

    /// A fresh device id per run would litter the server with devices.
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
