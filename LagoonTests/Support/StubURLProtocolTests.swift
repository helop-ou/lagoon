import Foundation
import Testing
@testable import Lagoon

/// The shared stub keeps one handler per host for the whole process, and
/// suites run in parallel, so a host registered by two files lets one suite
/// swap the other's handler and wipe its recorded requests mid-test.
@Suite("Stub URL protocol")
struct StubURLProtocolTests {
    @Test func everyStubHostIsRegisteredByOneFileOnly() throws {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        var owners: [String: Set<String>] = [:]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for host in Self.stubHosts(in: source) {
                owners[host, default: []].insert(file.lastPathComponent)
            }
        }
        // The scan must see the suites it guards, or it passes vacuously.
        #expect(owners["library.test"] == ["LibraryBrowseTests.swift"])
        #expect(owners["quality-local.test"] == ["PlaybackQualityLimitTests.swift"])
        #expect(owners["client-requests.test"] == ["JellyfinClientRequestTests.swift"])
        for (host, files) in owners.sorted(by: { $0.key < $1.key }) {
            #expect(files.count == 1, "\(host) is registered by \(files.sorted().joined(separator: ", "))")
        }
    }

    /// Hosts passed to `register(host:)` as literals, plus the `let host`
    /// literals of a file that registers through a variable or constant.
    static func stubHosts(in source: String) -> Set<String> {
        var hosts = Set(source.matches(of: /register\(host:\s*"([^"]+)"/).map { String($0.output.1) })
        if source.contains("register(host: host") || source.contains("register(host: Self.host") {
            hosts.formUnion(source.matches(of: /let host = "([^"]+)"/).map { String($0.output.1) })
        }
        return hosts.filter { $0.wholeMatch(of: /[A-Za-z0-9.-]+/) != nil }
    }

    @Test func aSharedHostIsCaught() {
        let first = #"StubURLProtocol.register(host: "shared.test") { _ in (200, [:], Data()) }"#
        let second = """
        let host = "shared.test"
        StubURLProtocol.register(host: host) { _ in (200, [:], Data()) }
        """
        #expect(Self.stubHosts(in: first) == ["shared.test"])
        #expect(Self.stubHosts(in: second) == ["shared.test"])
    }

    @Test func anUnregisteredHostFailsInsteadOfReachingTheNetwork() async throws {
        let session = URLSession(configuration: StubURLProtocol.configuration())
        let url = URL(string: "https://unregistered.stub.test/System/Info/Public")!
        let error = await #expect(throws: URLError.self) {
            _ = try await session.data(from: url)
        }
        #expect(error?.code == .unsupportedURL)
        #expect(StubURLProtocol.requests(host: "unregistered.stub.test").isEmpty)
    }

    @Test func aRecordedRequestKeepsItsBody() async throws {
        let host = "body.stub.test"
        StubURLProtocol.register(host: host) { _ in (204, [:], Data()) }
        defer { StubURLProtocol.unregister(host: host) }
        var request = URLRequest(url: URL(string: "https://\(host)/Sessions/Playing")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"ItemId":"film"}"#.utf8)
        _ = try await URLSession(configuration: StubURLProtocol.configuration()).data(for: request)
        let recorded = try #require(StubURLProtocol.requests(host: host).first)
        #expect(recorded.httpBody == Data(#"{"ItemId":"film"}"#.utf8))
    }
}
