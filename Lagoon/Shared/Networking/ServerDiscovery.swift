import Darwin
import Foundation
import Synchronization

/// A Jellyfin server that answered the local network broadcast.
nonisolated struct DiscoveredServer: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let address: URL
}

/// Jellyfin's client discovery: a UDP broadcast to port 7359, which every
/// server on the subnet answers with its id, name and address. A physical
/// iPhone or iPad sends it only with the multicast networking entitlement.
/// Apple TV and the simulators need none.
nonisolated enum ServerDiscovery {
    struct Target: Hashable, Sendable {
        var host: String
        var port: UInt16
    }

    static let port: UInt16 = 7359
    static let probe = Data("who is JellyfinServer?".utf8)
    /// Repeated, so servers still answer once the viewer allows local network access.
    static let sendTimes: [Duration] = [.zero, .seconds(1), .seconds(3)]
    static let window: Duration = .seconds(6)

    /// Each server once, as its reply arrives. Ends after `window`, or when
    /// the consumer stops listening.
    static func servers(
        targets: [Target] = broadcastTargets(),
        sendTimes: [Duration] = sendTimes,
        window: Duration = window
    ) -> AsyncStream<DiscoveredServer> {
        AsyncStream { continuation in
            let stop = StopFlag()
            continuation.onTermination = { _ in stop.set() }
            // Blocking socket calls, so off the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async {
                search(targets: targets, sendTimes: sendTimes, window: window, stop: stop) { continuation.yield($0) }
                continuation.finish()
            }
        }
    }

    /// The limited broadcast and each interface's own, because iOS does not
    /// always route the limited one.
    static func broadcastTargets() -> [Target] {
        var targets = [Target(host: "255.255.255.255", port: port)]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return targets }
        defer { freeifaddrs(interfaces) }
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }).map(\.pointee) {
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let broadcast = interface.ifa_dstaddr, broadcast.pointee.sa_family == sa_family_t(AF_INET),
                  let host = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { host(of: $0.pointee) })
            else { continue }
            let target = Target(host: host, port: port)
            if !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    private struct Reply: Decodable {
        var id: String?
        var name: String?
        var address: String?
    }

    /// The reply's address is the server's own idea of its URL. A missing or
    /// unusable one falls back to the sender on Jellyfin's default port.
    static func server(from data: Data, sender: String?) -> DiscoveredServer? {
        guard let reply = try? JellyfinClient.decoder.decode(Reply.self, from: data),
              reply.id?.isEmpty == false || reply.address?.isEmpty == false else { return nil }
        let address: URL
        if let stated = reply.address.flatMap(URL.init(string:)),
           ["http", "https"].contains(stated.scheme?.lowercased()), stated.host()?.isEmpty == false {
            address = stated
        } else if let sender, let fallback = URL(string: "http://\(sender):8096") {
            address = fallback
        } else {
            return nil
        }
        let id = reply.id.flatMap { $0.isEmpty ? nil : $0 } ?? address.absoluteString
        let name = reply.name.flatMap { $0.isEmpty ? nil : $0 } ?? address.host() ?? address.absoluteString
        return DiscoveredServer(id: id, name: name, address: address)
    }

    private static func search(
        targets: [Target], sendTimes: [Duration], window: Duration, stop: StopFlag,
        found: (DiscoveredServer) -> Void
    ) {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return }
        defer { close(socket) }
        var enabled: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        let clock = ContinuousClock()
        let start = clock.now
        var pendingSends = sendTimes.sorted()
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while !stop.isSet {
            let elapsed = clock.now - start
            guard elapsed < window else { break }
            while let next = pendingSends.first, next <= elapsed {
                pendingSends.removeFirst()
                // A refused send, such as no route or no entitlement, only means no replies.
                for target in targets { send(probe, to: target, on: socket) }
            }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socket, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0,
                  let server = server(from: Data(buffer[0..<count]), sender: host(of: source)),
                  seen.insert(server.id).inserted else { continue }
            found(server)
        }
    }

    private static func send(_ data: Data, to target: Target, on socket: Int32) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = target.port.bigEndian
        guard inet_pton(AF_INET, target.host, &address.sin_addr) == 1 else { return }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private static func host(of address: sockaddr_in) -> String? {
        var raw = address.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil else { return nil }
        return text.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private final class StopFlag: Sendable {
        private let stopped = Mutex(false)
        var isSet: Bool { stopped.withLock { $0 } }
        func set() { stopped.withLock { $0 = true } }
    }
}
