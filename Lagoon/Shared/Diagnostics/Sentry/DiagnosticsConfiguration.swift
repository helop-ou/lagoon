import Foundation
import LagoonEngine

/// App-owned wiring: which backend stands behind
/// `Diagnostics.shared`.
///
/// The DSN is injected at build time rather than committed. A DSN
/// is write-only ingest and grants nobody access to our data, but a tracked
/// one lets anyone flood the project's quota, and reporting defaults on in
/// Release builds — so without this, any checkout that archived the app would
/// report into it. A build that carries no DSN configures no sink and stays
/// silent; that is the ordinary case for a plain checkout.
///
/// `-diagnostics.sentryDSN <dsn>` overrides it for a run that captures
/// payloads locally.
nonisolated enum DiagnosticsConfiguration {
    /// Substituted into the app's Info.plist from the `LAGOON_SENTRY_DSN`
    /// build setting. `scripts/upload-testflight.sh` requires it; ordinary
    /// `xcodebuild` and Xcode builds leave it empty.
    static let dsnInfoPlistKey = "LagoonSentryDSN"
    static let dsnOverrideKey = "diagnostics.sentryDSN"

    /// The DSN this build should report to, or `nil` when none was injected.
    static var sentryDSN: String? {
        resolveDSN(
            override: UserDefaults.standard.string(forKey: dsnOverrideKey),
            injected: Bundle.main.object(forInfoDictionaryKey: dsnInfoPlistKey) as? String
        )
    }

    /// First usable candidate, override first. An absent build setting leaves
    /// the Info.plist value empty, and a target that never declared one leaves
    /// the `$(LAGOON_SENTRY_DSN)` reference unexpanded; both mean "no DSN".
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

    /// The playback package's version and the FFmpeg it was built against.
    /// Both, because the engine is versioned independently of this app now
    /// and can be rebuilt against a different libavformat without changing
    /// its own number.
    static var engineVersion: String { EngineVersion.summary }
}
