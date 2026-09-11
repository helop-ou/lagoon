import Foundation
#if canImport(Network)
import Network
#endif

/// What the current network path *costs*, which is a different question from
/// how fast it is (HEL-108).
///
/// `DeviceProfile` advertised 120 Mbps on every device and every path, so an
/// 80 Mbps remux was offered as direct play over cellular or a hotspot —
/// unwatchable and expensive at once. The playback cache already made this
/// distinction one layer down, refusing expensive and constrained paths for
/// proactive range fills; the profile simply never asked.
nonisolated struct NetworkPathCost: Equatable, Sendable {
    /// Apple's term for cellular and personal hotspots.
    let isExpensive: Bool
    /// Low Data Mode.
    let isConstrained: Bool

    static let unrestricted = NetworkPathCost(isExpensive: false, isConstrained: false)

    /// Either flag is enough. They are different reasons for the same answer:
    /// do not pull the original file over this.
    var isMetered: Bool { isExpensive || isConstrained }
}

/// The bitrate and geometry a metered path is offered.
///
/// Pure, so the decision is pinned by tests rather than by finding a
/// cellular connection.
nonisolated enum MeteredPathPolicy {
    /// Low single digits, per the shape this was specified with. Enough for
    /// a decent 720p rendition and nowhere near a 4K remux.
    static let maxBitrate = 3_000_000
    /// A resolution ceiling rides along with the bitrate, which the original
    /// shape did not ask for and which measurement argued for: capping the
    /// bitrate alone leaves `MaxWidth` absent, so the server answers an
    /// 89 Mbps 4K source with a 4K re-encode at 3 Mbps. That is a picture
    /// nobody wants and minutes of server CPU to produce it, on a phone whose
    /// screen cannot show it. 720p is the conventional cellular rendition and
    /// makes the encode cheap.
    static let maxWidth = 1280
    static let maxHeight = 720

    /// `allowFullQuality` is the viewer's override, for a metered connection
    /// they know is fast. Deliberately theirs to make rather than a silent
    /// policy: Apple can only report that a path is expensive, never that it
    /// is slow, and an unmetered-but-throttled hotspot and a fast tethered
    /// 5G connection look identical from here.
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

/// The current path cost, kept live by `NWPathMonitor`.
///
/// Read when a profile is built, which is once per `PlaybackInfo` call. A
/// path that changes mid-title therefore does not re-negotiate, which is a
/// deliberate omission rather than an oversight: the alternative is tearing
/// down a working stream because a phone moved between two access points.
nonisolated final class NetworkPathObserver: @unchecked Sendable {
    static let shared = NetworkPathObserver()

    private let lock = NSLock()
    private var cost: NetworkPathCost = .unrestricted
    #if canImport(Network)
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ee.helop.lagoon.networkpath")
    #endif

    /// `start` is separate from `init` so the shared instance can exist
    /// without a monitor running in tests.
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

    /// `.unrestricted` until the monitor has reported, which errs toward the
    /// behaviour that existed before this: offer everything. A first
    /// negotiation on a cold launch over cellular may therefore miss the cap
    /// once.
    var current: NetworkPathCost {
        lock.withLock { cost }
    }

    /// Testing seam; the monitor overwrites this on its next update.
    func override(_ cost: NetworkPathCost) {
        lock.withLock { self.cost = cost }
    }
}
