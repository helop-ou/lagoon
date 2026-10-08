import Foundation
import Testing
@testable import Lagoon

/// The DSN is injected at build time, so every way of missing it must
/// resolve to `nil`, never a half-substituted address.
@Suite("Diagnostics configuration")
struct DiagnosticsConfigurationTests {
    static let dsn = "https://abc123@o1.ingest.de.sentry.io/2"

    @Test("An injected DSN is used when nothing overrides it")
    func injectedDSN() {
        #expect(DiagnosticsConfiguration.resolveDSN(override: nil, injected: Self.dsn) == Self.dsn)
    }

    @Test("A capture run's override wins over the injected DSN")
    func overrideWins() {
        let local = "http://key@127.0.0.1:8765/1"
        #expect(DiagnosticsConfiguration.resolveDSN(override: local, injected: Self.dsn) == local)
    }

    /// An undeclared setting leaves the Info.plist value empty or unexpanded.
    @Test("An empty or unexpanded build setting resolves to none",
          arguments: ["", "   ", "\n", "$(LAGOON_SENTRY_DSN)"])
    func emptyOrUnexpanded(value: String) {
        #expect(DiagnosticsConfiguration.resolveDSN(override: nil, injected: value) == nil)
        #expect(DiagnosticsConfiguration.resolveDSN(override: value, injected: nil) == nil)
    }

    @Test("An unusable override falls back to the injected DSN")
    func overrideFallsBack() {
        #expect(DiagnosticsConfiguration.resolveDSN(override: "", injected: Self.dsn) == Self.dsn)
    }
}
