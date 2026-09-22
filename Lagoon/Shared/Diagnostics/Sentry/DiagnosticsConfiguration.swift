import Foundation
import LagoonEngine

/// Which backend stands behind `Diagnostics.shared`.
///
/// The DSN is injected at build time, never committed: a tracked one lets
/// any checkout's Release build flood the quota. No DSN means no sink.
/// `-diagnostics.sentryDSN <dsn>` overrides it for a local capture run.
nonisolated enum DiagnosticsConfiguration {
    /// From the `LAGOON_SENTRY_DSN` build setting via Info.plist.
    /// `scripts/upload-testflight.sh` requires it; other builds leave it empty.
    static let dsnInfoPlistKey = "LagoonSentryDSN"
    static let dsnOverrideKey = "diagnostics.sentryDSN"

    static var sentryDSN: String? {
        resolveDSN(
            override: UserDefaults.standard.string(forKey: dsnOverrideKey),
            injected: Bundle.main.object(forInfoDictionaryKey: dsnInfoPlistKey) as? String
        )
    }

    /// Override first. An empty value or an unexpanded
    /// `$(LAGOON_SENTRY_DSN)` means "no DSN".
    static func resolveDSN(override: String?, injected: String?) -> String? {
        for candidate in [override, injected] {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !value.contains("$(") else { continue }
            return value
        }
        return nil
    }

    /// Called once from the app's initialiser, on the main actor.
    @MainActor
    static func install() -> DiagnosticsProcessObserver {
        if let configured = sentryDSN, let dsn = SentryDSN(string: configured) {
            Diagnostics.shared.configure(sink: SentryTransport(
                dsn: dsn,
                context: .current(engineVersion: engineVersion)
            ))
        }
        return DiagnosticsProcessObserver(hub: Diagnostics.shared)
    }

    /// Engine version plus its FFmpeg: the engine can be rebuilt against a
    /// different libavformat without changing its own number.
    static var engineVersion: String { EngineVersion.summary }
}
