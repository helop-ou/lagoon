import Foundation
import Libavformat

/// App-owned wiring for HEL-159: which backend stands behind
/// `Diagnostics.shared`. The DSN is a client key for the `lagoon`
/// project in the `helop-ou` organisation on Sentry's EU region; it can
/// only submit events there. `-diagnostics.sentryDSN <dsn>` overrides it
/// for a run that captures payloads locally.
nonisolated enum DiagnosticsConfiguration {
    static let sentryDSN = "https://5d3867dd694aedb6e4446a2767c2b4c1@o4512064306282496.ingest.de.sentry.io/4512064311722064"
    static let dsnOverrideKey = "diagnostics.sentryDSN"

    /// Called once from the app's initialiser.
    static func install() -> DiagnosticsProcessObserver {
        let configured = UserDefaults.standard.string(forKey: dsnOverrideKey) ?? sentryDSN
        if let dsn = SentryDSN(string: configured) {
            Diagnostics.shared.configure(sink: SentryTransport(
                dsn: dsn,
                context: .current(engineVersion: engineVersion)
            ))
        }
        return DiagnosticsProcessObserver(hub: Diagnostics.shared)
    }

    /// The linked libavformat, as `lavf<major>.<minor>.<micro>`: the one
    /// component of the engine that is versioned independently of the app.
    static var engineVersion: String {
        let version = avformat_version()
        return "lavf\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)"
    }
}
