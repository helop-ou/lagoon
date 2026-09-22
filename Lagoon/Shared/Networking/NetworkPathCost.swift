import Foundation
#if canImport(Network)
import Network
#endif

/// What the current network path costs (not how fast it is).
nonisolated struct NetworkPathCost: Equatable, Sendable {
    /// Apple's term for cellular and personal hotspots.
    let isExpensive: Bool
    /// Low Data Mode.
    let isConstrained: Bool

    static let unrestricted = NetworkPathCost(isExpensive: false, isConstrained: false)

    /// Either flag means: do not pull the original file.
    var isMetered: Bool { isExpensive || isConstrained }
}

/// The bitrate and geometry a metered path is offered.
nonisolated enum MeteredPathPolicy {
    /// Enough for a decent 720p rendition.
    static let maxBitrate = 3_000_000
    /// Cap resolution too: a bitrate cap alone gets a 4K re-encode at
    /// 3 Mbps, costly for the server and useless on a phone.
    static let maxWidth = 1280
    static let maxHeight = 720

    /// `allowFullQuality` is the viewer's override. Apple reports only that
    /// a path is expensive, never whether it is fast.
    static func maxStreamingBitrate(
        unrestricted: Int,
        cost: NetworkPathCost,
        allowFullQuality: Bool
    ) -> Int {
        guard applies(cost: cost, allowFullQuality: allowFullQuality) else { return unrestricted }
        return min(unrestricted, maxBitrate)
    }

    static func applies(cost: NetworkPathCost, allowFullQuality: Bool) -> Bool {
        cost.isMetered && !allowFullQuality
    }
}

/// The current path cost, kept live by `NWPathMonitor`. Read once per
/// `PlaybackInfo`; a path change mid-title deliberately does not
/// re-negotiate.
nonisolated final class NetworkPathObserver: @unchecked Sendable {
    static let shared = NetworkPathObserver()

    private let lock = NSLock()
    private var cost: NetworkPathCost = .unrestricted
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ee.helop.lagoon.networkpath")
    #endif

    /// Separate from `init` so tests run without a monitor.
    func start() {
        #if canImport(Network)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock {
                self?.cost = NetworkPathCost(
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                )
            }
        }
        monitor.start(queue: queue)
        #endif
    }

    /// `.unrestricted` until the monitor reports, so a cold-launch first
    /// negotiation over cellular may miss the cap once.
    var current: NetworkPathCost {
        lock.withLock { cost }
    }

    /// Testing seam; the monitor overwrites this on its next update.
    func override(_ cost: NetworkPathCost) {
        lock.withLock { self.cost = cost }
    }
}
