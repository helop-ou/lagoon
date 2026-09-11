import Foundation
import Testing
@testable import Lagoon

@Suite("Local network recovery")
struct LocalNetworkAccessTests {
    private let server = URL(string: "https://jellyfin.example.test")!

    @Test func confirmedEndpointDenialExplainsHowToRecover() async {
        let error = await LocalNetworkAccess.explain(URLError(.notConnectedToInternet), at: server) { _ in true }
        #expect(error is LocalNetworkAccess.Failure)
        #expect(error.localizedDescription.contains("Settings"))
    }

    @Test func anOfflineServerIsNotMisreportedAsPermissionDenial() async {
        let error = await LocalNetworkAccess.explain(URLError(.cannotConnectToHost), at: server) { _ in false }
        #expect((error as? URLError)?.code == .cannotConnectToHost)
    }

    @Test(arguments: [URLError.Code.serverCertificateUntrusted, .userAuthenticationRequired, .cancelled, .badURL])
    func securityAndCancellationFailuresNeverTriggerAnotherConnection(code: URLError.Code) async {
        let error = await LocalNetworkAccess.explain(URLError(code), at: server) { _ in
            Issue.record("This failure must not create a diagnostic connection")
            return true
        }
        #expect((error as? URLError)?.code == code)
    }

    @Test func cancelledDiagnosisStopsWithoutReportingDenial() async {
        let pending = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LocalNetworkAccess.explain(URLError(.timedOut), at: server) { _ in
                Issue.record("A cancelled operation must not open a connection")
                return true
            }
        }
        let error = await pending.value
        #expect((error as? URLError)?.code == .timedOut)
    }

    @Test func diagnosticConnectionHonorsCancellation() async {
        let pending = Task { await LocalNetworkAccess.isDenied(at: URL(string: "https://192.0.2.1")!) }
        pending.cancel()
        #expect(await pending.value == false)
    }

    @Test @MainActor func deniedSetupStopsAlternateAddressesAndRetriesTheOriginalEndpoint() async throws {
        let suite = "LocalNetworkAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = SetupProbe()
        let store = SessionStore(accountDraft: true, defaults: defaults, credentials: MemoryAccountCredentials(),
                                 publicInfo: { try await probe.info(at: $0) })
        do {
            try await store.connect(to: "jellyfin.local")
            Issue.record("Denied setup must not advance to sign-in")
        } catch {
            #expect(error is LocalNetworkAccess.Failure)
        }
        #expect(store.phase == .needsServer)
        #expect(store.client.serverURL == nil)
        #expect(await probe.attempts.count == 1)
        await probe.allow()
        try await store.connect(to: "jellyfin.local")
        #expect(store.phase == .needsSignIn)
        let attempts = await probe.attempts
        #expect(attempts.count == 2)
        #expect(attempts.first == attempts.last)
        #expect(store.serverName == "Recovered fixture")
    }
}

private actor SetupProbe {
    private(set) var attempts: [URL] = []
    private var denied = true

    func allow() { denied = false }

    func info(at url: URL) throws -> PublicSystemInfo {
        attempts.append(url)
        if denied { throw LocalNetworkAccess.Failure.denied }
        return PublicSystemInfo(serverName: "Recovered fixture", version: "10.11.0", id: "fixture")
    }
}
