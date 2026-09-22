import CoreMedia
import Foundation

/// One `GetUtcTime` round trip: NTP's four timestamps, in seconds since 1970
/// on whichever clock observed each.
nonisolated struct ServerClockSample: Equatable, Sendable {
    /// Local clock.
    let requestSent: Double
    /// Server clock.
    let requestReceived: Double
    /// Server clock.
    let responseSent: Double
    /// Local clock.
    let responseReceived: Double

    /// Server clock minus local clock. Exact only for a symmetric trip.
    var offset: Double {
        ((requestReceived - requestSent) + (responseSent - responseReceived)) / 2
    }

    /// Time on the wire, excluding server processing.
    var roundTrip: Double {
        (responseReceived - requestSent) - (responseSent - requestReceived)
    }
}

/// Recent clock samples. The fastest round trip wins outright, never an
/// average: a slow sample is asymmetric, not noise (as NTP and jellyfin-web).
nonisolated struct ServerClockEstimate: Equatable, Sendable {
    /// Several minutes of samples: enough to keep a good one, short enough
    /// to forget the network before it changed.
    static let capacity = 8

    private(set) var samples: [ServerClockSample] = []

    mutating func record(_ sample: ServerClockSample) {
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    var best: ServerClockSample? {
        samples.min { $0.roundTrip < $1.roundTrip }
    }

    /// Server clock minus local clock, in seconds.
    var offset: Double? { best?.offset }

    /// One-way latency, in seconds.
    var ping: Double? { best.map { $0.roundTrip / 2 } }
}

/// Estimates the server's clock, so a SyncPlay command's server instant can
/// become a host-clock time the engine schedules against.
///
/// Samples are probes: failures are quiet and the poll keeps the old
/// estimate.
@Observable
final class ServerClock {
    static let greedySampleCount = 3
    static let greedyInterval: Duration = .seconds(1)
    /// Tracks network changes; clock drift per minute is negligible.
    static let steadyInterval: Duration = .seconds(60)

    private(set) var estimate = ServerClockEstimate()

    /// Called with `pingMilliseconds` (the best estimate) after each sample,
    /// so the SyncPlay store can post `SyncPlay/Ping` without its own timer.
    @ObservationIgnored var onSample: ((Int) -> Void)?

    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// `Date` and host clock read together. They are independent timebases,
    /// so mapping between them needs a pair captured at once.
    @ObservationIgnored private var anchor: (date: Date, hostTime: CMTime)?

    init(client: JellyfinClient) {
        self.client = client
    }

    /// Until true, `serverSeconds` falls back to the local clock; do not
    /// schedule a group against it.
    var isReady: Bool { estimate.best != nil }

    /// Server minus local, in seconds; nil before the first sample.
    var offset: Double? { estimate.offset }

    var pingMilliseconds: Int? {
        estimate.ping.map { Int(($0 * 1_000).rounded()) }
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.poll() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Restarts the fast sampling after a foreground or network change.
    /// Existing samples are kept.
    func forceUpdate() {
        stop()
        start()
    }

    /// What the server's clock reads now.
    func serverSeconds(now: Date = Date()) -> Double {
        now.timeIntervalSince1970 + (offset ?? 0)
    }

    /// The local instant at which the server's clock will read `seconds`.
    func localDate(forServer seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds - (offset ?? 0))
    }

    /// The instant on the host clock, which the engine's renderers use.
    /// Extrapolated from the latest anchor.
    func hostTime(forServer seconds: Double) -> CMTime {
        let anchor = anchor ?? (date: Date(), hostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        let ahead = localDate(forServer: seconds).timeIntervalSince(anchor.date)
        return CMTimeAdd(anchor.hostTime, CMTime(seconds: ahead, preferredTimescale: 1_000_000_000))
    }

    // MARK: - Sampling

    nonisolated struct UtcTimeResponse: Decodable {
        let requestReceptionTime: String
        let responseTransmissionTime: String
    }

    private func poll() async {
        var greedyRemaining = Self.greedySampleCount
        while !Task.isCancelled {
            await sample()
            let interval: Duration
            if greedyRemaining > 1 {
                greedyRemaining -= 1
                interval = Self.greedyInterval
            } else {
                interval = Self.steadyInterval
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    private func sample() async {
        let requestSent = Date().timeIntervalSince1970
        guard let response: UtcTimeResponse = try? await client.get("GetUtcTime", probe: true) else { return }
        // Read both clocks together, before anything else can suspend.
        let responseReceived = Date()
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard let requestReceived = JellyfinTimestamp.seconds(response.requestReceptionTime),
              let responseSent = JellyfinTimestamp.seconds(response.responseTransmissionTime) else { return }
        estimate.record(ServerClockSample(
            requestSent: requestSent,
            requestReceived: requestReceived,
            responseSent: responseSent,
            responseReceived: responseReceived.timeIntervalSince1970
        ))
        anchor = (date: responseReceived, hostTime: hostTime)
        if let pingMilliseconds { onSample?(pingMilliseconds) }
    }
}
