import Darwin
import Foundation
import Synchronization
import Testing
@testable import Lagoon

@Suite("Local server discovery")
struct ServerDiscoveryTests {
    @Test func aReplyNamesTheServerAtItsOwnAddress() throws {
        let server = try #require(ServerDiscovery.server(
            from: Data(#"{"Address":"http://192.168.1.20:8096","Id":"abc","Name":"Living Room","EndpointAddress":null}"#.utf8),
            sender: "192.168.1.20"
        ))
        #expect(server == DiscoveredServer(id: "abc", name: "Living Room", address: URL(string: "http://192.168.1.20:8096")!))
    }

    @Test(arguments: [
        #"{"Id":"abc","Name":"Living Room"}"#,
        #"{"Address":"","Id":"abc","Name":"Living Room"}"#,
        #"{"Address":"ftp://192.168.1.20","Id":"abc","Name":"Living Room"}"#,
        #"{"Address":"not a url","Id":"abc","Name":"Living Room"}"#,
    ])
    func anUnusableAddressFallsBackToTheSenderOnJellyfinsPort(reply: String) throws {
        let server = try #require(ServerDiscovery.server(from: Data(reply.utf8), sender: "192.168.1.20"))
        #expect(server.address == URL(string: "http://192.168.1.20:8096")!)
        #expect(server.id == "abc")
    }

    @Test func aNamelessServerIsShownByItsHost() throws {
        let server = try #require(ServerDiscovery.server(
            from: Data(#"{"Address":"http://media.local:8096","Id":"abc","Name":""}"#.utf8), sender: nil
        ))
        #expect(server.name == "media.local")
    }

    @Test(arguments: ["{}", #"{"Name":"Living Room"}"#, "who is JellyfinServer?", "[1,2]"])
    func anythingButAServerReplyIsIgnored(reply: String) {
        #expect(ServerDiscovery.server(from: Data(reply.utf8), sender: "192.168.1.20") == nil)
    }

    @Test func eachServerIsFoundOnceThroughEveryProbe() async throws {
        let responder = try Responder(replies: [
            #"{"Address":"http://192.168.1.20:8096","Id":"abc","Name":"Living Room"}"#,
            #"{"Address":"http://192.168.1.20:8096","Id":"abc","Name":"Living Room"}"#,
            #"{"Address":"http://192.168.1.30:8096","Id":"def","Name":"Study"}"#,
        ])
        defer { responder.close() }
        var found: [DiscoveredServer] = []
        for await server in ServerDiscovery.servers(
            targets: [.init(host: "127.0.0.1", port: responder.port)],
            sendTimes: [.zero, .milliseconds(200)],
            window: .milliseconds(800)
        ) {
            found.append(server)
        }
        #expect(found.map(\.id) == ["abc", "def"])
        #expect(responder.probes.count == 2)
        #expect(responder.probes.allSatisfy { $0 == ServerDiscovery.probe })
    }

    @Test func noServerOnTheNetworkEndsTheSearchEmpty() async {
        let start = ContinuousClock.now
        var found = 0
        for await _ in ServerDiscovery.servers(
            targets: [.init(host: "127.0.0.1", port: 9)], sendTimes: [.zero], window: .milliseconds(300)
        ) {
            found += 1
        }
        #expect(found == 0)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func theLimitedBroadcastIsAlwaysATarget() {
        let targets = ServerDiscovery.broadcastTargets()
        #expect(targets.first == .init(host: "255.255.255.255", port: 7359))
        #expect(Set(targets).count == targets.count)
        #expect(targets.allSatisfy { $0.port == 7359 && $0.host != "127.0.0.1" })
    }
}

/// A server on loopback that answers every probe with all of its replies.
private final class Responder: Sendable {
    let port: UInt16
    private let socket: Int32
    private let received = Mutex<[Data]>([])

    var probes: [Data] { received.withLock { $0 } }

    init(replies: [String]) throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        try #require(socket >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        try #require(bound)
        self.socket = socket
        port = UInt16(bigEndian: address.sin_port)
        let replies = replies.map { Data($0.utf8) }
        Thread.detachNewThread { [self] in serve(replies) }
    }

    func close() {
        shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func serve(_ replies: [Data]) {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socket, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            received.withLock { $0.append(Data(buffer[0..<count])) }
            for reply in replies {
                _ = reply.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &sender) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(socket, bytes.baseAddress, bytes.count, 0, $0, length)
                        }
                    }
                }
            }
        }
    }
}
