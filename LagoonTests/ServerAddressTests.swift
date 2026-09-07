import Foundation
import Testing
@testable import Lagoon

@Suite("Server address discovery")
struct ServerAddressTests {
    @Test func defaultPortsBelongToTheHostBeforeTheProxyPath() {
        #expect(SessionStore.candidateURLs(for: "media.example/jellyfin/").map(\.absoluteString) == [
            "https://media.example/jellyfin", "http://media.example/jellyfin", "http://media.example:8096/jellyfin"
        ])
        #expect(SeerrClient.candidateURLs(for: "media.example/requests/api/v1/").map(\.absoluteString) == [
            "https://media.example/requests", "http://media.example/requests", "http://media.example:5055/requests"
        ])
    }

    @Test(arguments: ["http", "https", "HTTP", "HTTPS"])
    func explicitSchemesNeverProbeAnotherTransport(scheme: String) {
        let input = " \n\(scheme)://media.example:8443/Media///\t"
        let expected = ["\(scheme.lowercased())://media.example:8443/Media"]
        #expect(SessionStore.candidateURLs(for: input).map(\.absoluteString) == expected)
        #expect(SeerrClient.candidateURLs(for: input).map(\.absoluteString) == expected)
    }

    @Test func explicitPortsAndBracketedIPv6ArePreserved() {
        #expect(SessionStore.candidateURLs(for: "[::1]:9000/base").map(\.absoluteString) == [
            "http://[::1]:9000/base", "https://[::1]:9000/base"
        ])
        #expect(SessionStore.candidateURLs(for: "[2001:db8::1]/base").map(\.absoluteString) == [
            "http://[2001:db8::1]/base", "http://[2001:db8::1]:8096/base", "https://[2001:db8::1]/base"
        ])
        #expect(SeerrClient.candidateURLs(for: "[::1]/api/v1").map(\.absoluteString) == [
            "http://[::1]", "https://[::1]", "http://[::1]:5055"
        ])
        #expect(SessionStore.candidateURLs(for: "media.example:1234/base").map(\.absoluteString) == [
            "https://media.example:1234/base", "http://media.example:1234/base"
        ])
        #expect(SessionStore.candidateURLs(for: "http://[fe80::1%25en0]:8096/base").first?.absoluteString
                == "http://[fe80::1%25en0]:8096/base")
    }

    @Test(arguments: ["192.168.1.10", "media.LOCAL"])
    func localAddressesRetainHTTPFirstDiscovery(host: String) {
        #expect(SessionStore.candidateURLs(for: host).map(\.absoluteString) == [
            "http://\(host)", "http://\(host):8096", "https://\(host)"
        ])
        #expect(SeerrClient.candidateURLs(for: host).map(\.absoluteString) == [
            "http://\(host)", "https://\(host)", "http://\(host):5055"
        ])
    }

    @Test func encodedProxySegmentsAreNotDecodedOrMistakenForAnAPISuffix() {
        let path = "/Media%2FSpace%20A/%23%3F%25"
        #expect(SessionStore.candidateURLs(for: "media.example\(path)").last?.absoluteString
                == "http://media.example:8096\(path)")
        #expect(SeerrClient.candidateURLs(for: "media.example\(path)/api/v1///").last?.absoluteString
                == "http://media.example:5055\(path)")
        #expect(SeerrClient.candidateURLs(for: "https://media.example/base%2Fapi/v1/").first?.absoluteString
                == "https://media.example/base%2Fapi/v1")
        #expect(SeerrClient.candidateURLs(for: "https://media.example/api/v1/nested/").first?.path
                == "/api/v1/nested")
    }

    @Test func rootNormalizationAndInternationalNames() {
        #expect(SessionStore.candidateURLs(for: "https://bücher.example/").first?.absoluteString
                == "https://xn--bcher-kva.example")
        #expect(SeerrClient.candidateURLs(for: "https://media.example/api/v1///").first?.absoluteString
                == "https://media.example")
    }

    @Test(arguments: ["", " \n", "/media.example", "//media.example/base", "file:///tmp/server", "ftp://media.example",
                      "https:///base", "http://", "https://user:secret@media.example", "user@media.example",
                      "media.example?api_key=secret", "media.example#fragment", "media.example?", "media.example#",
                      "media.example:0", "media.example:65536", "media.example:abc", "media.example:",
                      "media.example:/base", "http://[::1]:", "::1", "http://[invalid]", "http://999.999.999.999",
                      "media..example", "media.example/base path", "media.example/\nbase", "media.example\\base",
                      "media.example/%", "media.example/%zz", "https://bad%2Fhost/base"])
    func malformedOrAmbiguousInputCannotTriggerDiscovery(input: String) {
        #expect(SessionStore.candidateURLs(for: input).isEmpty)
        #expect(SeerrClient.candidateURLs(for: input).isEmpty)
    }

    @Test func connectionDisplayRetainsTheDestinationButRedactsLegacySecrets() {
        let url = URL(string: "http://user:secret@media.example:8096/base%2Fpath?api_key=private#token")!
        #expect(ServerAddress.displayString(for: url) == "http://media.example:8096/base%2Fpath")
    }

    @Test @MainActor func discoveryCommitsTheSuccessfulProxyURLForSignIn() async throws {
        let suite = "ServerAddressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = AddressProbe()
        let store = SessionStore(accountDraft: true, defaults: defaults, credentials: MemoryAccountCredentials(),
                                 publicInfo: { try await probe.info(at: $0) })
        try await store.connect(to: "media.example/jellyfin")
        #expect(await probe.attempts.count == 3)
        #expect(store.client.serverURL?.absoluteString == "http://media.example:8096/jellyfin")
        #expect(store.phase == .needsSignIn)
        #expect(store.serverName == "Proxy fixture")
    }

    @Test @MainActor func invalidInputDoesNotProbeAndHTTPSFailureDoesNotDowngrade() async throws {
        let suite = "ServerAddressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = AddressProbe()
        let store = SessionStore(accountDraft: true, defaults: defaults, credentials: MemoryAccountCredentials(),
                                 publicInfo: { try await probe.info(at: $0) })
        do {
            try await store.connect(to: "https://user:secret@media.example")
            Issue.record("Credentials embedded in an address must be rejected")
        } catch ServerAddress.Failure.invalid {}
        #expect(await probe.attempts.isEmpty)
        do {
            try await store.connect(to: "https://media.example/jellyfin")
            Issue.record("The fixture rejects HTTPS")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        }
        #expect(await probe.attempts.map(\.absoluteString) == ["https://media.example/jellyfin"])
        #expect(store.phase == .needsServer)
        #expect(store.client.serverURL == nil)
    }
}

private actor AddressProbe {
    private(set) var attempts: [URL] = []
    func info(at url: URL) throws -> PublicSystemInfo {
        attempts.append(url)
        guard url.port == 8096, url.path == "/jellyfin" else { throw URLError(.cannotConnectToHost) }
        return PublicSystemInfo(serverName: "Proxy fixture", version: "10.11.0", id: "fixture")
    }
}
