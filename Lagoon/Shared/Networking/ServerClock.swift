import CoreMedia
import Foundation

/// One round trip to `GetUtcTime`, in seconds since 1970 on whichever clock
/// observed each instant (HEL-172).
///
/// This is NTP's four-timestamp measurement, which is what SyncPlay's design
/// assumes: the two local instants bracket the request, the two server
/// instants come out of the response body, and the pair of differences
/// separates the clock offset from the time spent on the wire.
nonisolated struct ServerClockSample: Equatable, Sendable {
    /// Local clock, immediately before the request went out.
    let requestSent: Double
    /// Server clock, when the server says it received the request.
    let requestReceived: Double
    /// Server clock, when the server says it answered.
    let responseSent: Double
    /// Local clock, immediately after the response arrived.
    let responseReceived: Double

    /// How far ahead of the local clock the server's clock runs. The two
    /// halves of the trip cancel out only if they are symmetric, which is
    /// why the estimate below keeps the *fastest* sample rather than a mean.
    var offset: Double {
        ((requestReceived - requestSent) + (responseSent - responseReceived)) / 2
    }

    /// Time on the wire, with the server's own processing removed.
    var roundTrip: Double {
        (responseReceived - requestSent) - (responseSent - requestReceived)
    }
}

/// The recent history of clock samples, and the estimate drawn from it.
///
/// Deliberately not an average. A slow sample is not noise around the true
/// offset, it is a sample whose two halves were *asymmetric*, and averaging
/// folds that asymmetry into the answer. The sample with the lowest round
/// trip is the one with least room to be wrong, so it wins outright — the
/// same rule NTP and jellyfin-web's own SyncPlay time sync use.
nonisolated struct ServerClockEstimate: Equatable, Sendable {
    /// Eight is a couple of greedy samples plus several minutes of the slow
    /// cadence: long enough to have kept a good one, short enough to forget
    /// a measurement taken before the network changed.
    static let capacity = 8

    private(set) var samples: [ServerClockSample] = []

    mutating func record(_ sample: ServerClockSample) {
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    /// The fastest round trip still in the window, or nil before the first
    /// successful sample.
    var best: ServerClockSample? {
        samples.min { $0.roundTrip < $1.roundTrip }
    }

    /// Server clock minus local clock, in seconds.
    var offset: Double? { best?.offset }

    /// One-way latency, in seconds.
    var ping: Double? { best.map { $0.roundTrip / 2 } }
}

/// Keeps an estimate of the server's clock, so a SyncPlay group's "unpause
/// at 11:44:21.356" can be turned into a local instant — and then into a
/// host-clock time the playback engine can schedule against (HEL-172).
///
/// Main-actor owned, by the project's default isolation; the pure parts
/// above are `nonisolated` and carry the tests.
///
/// Failures are quiet on purpose. The sample request is marked as a probe,
/// so an unreachable server or a route an older build does not serve never
/// becomes an incident, and the poll simply keeps going: an old estimate is
/// better than none, and there is no diagnostic event that fits a clock
/// sample that did not land.
@Observable
final class ServerClock {
    /// Three samples one second apart is enough to have caught one clean
    /// round trip, which is all `best` needs, without a burst the server
    /// would notice.
    static let greedySampleCount = 3
    static let greedyInterval: Duration = .seconds(1)
    /// Clock drift between two computers over a minute is microseconds;
    /// what this cadence actually tracks is the *network* changing.
    static let steadyInterval: Duration = .seconds(60)

    private(set) var estimate = ServerClockEstimate()

    /// Called with the one-way latency in milliseconds each time a sample
    /// lands, so the SyncPlay store can post `SyncPlay/Ping` without owning
    /// a second timer. The value is the current best estimate rather than
    /// the sample just taken, matching `pingMilliseconds`.
    @ObservationIgnored var onSample: ((Int) -> Void)?

    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The local instant of the last sample paired with the host clock read
    /// beside it. Mapping a server instant onto the host clock has to go
    /// through a pair captured together: `Date` and the host clock are
    /// independent timebases and the offset between them is not fixed.
    @ObservationIgnored private var anchor: (date: Date, hostTime: CMTime)?

    init(client: JellyfinClient) {
        self.client = client
    }

    /// A usable estimate exists. Until then `serverSeconds` answers with the
    /// local clock, which is the honest fallback but not worth scheduling a
    /// group against.
    var isReady: Bool { estimate.best != nil }

    /// Server clock minus local clock, in seconds; nil until the first
    /// sample lands.
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

    /// Restarts the greedy phase — for a foreground transition or a network
    /// change, where the estimate is stale in a way the 60 s cadence would
    /// take minutes to correct. Existing samples are kept: the new fast ones
    /// only win if they are genuinely faster.
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

    /// The same instant on the host clock, which is the timebase the
    /// playback engine's renderers schedule against. Before the first
    /// sample, and for an instant far from the last one, this is an
    /// extrapolation from the most recent anchor pair.
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
