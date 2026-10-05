import Foundation

/// Settings → Playback → Maximum Quality. Auto measures a remote server's
/// link before the first playback and caps below it; a server on this
/// network keeps the full envelope.
nonisolated enum MaximumQuality: String, CaseIterable, Identifiable, Sendable {
    case auto
    case unlimited
    case mbps40 = "40"
    case mbps20 = "20"
    case mbps12 = "12"
    case mbps8 = "8"
    case mbps4 = "4"
    case mbps2 = "2"

    static let defaultsKey = "playback.maximumQuality"

    var id: String { rawValue }

    static var current: MaximumQuality {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(MaximumQuality.init(rawValue:)) ?? .auto
    }

    /// A fixed ceiling in bit/s; nil for Auto and No Limit.
    var fixedBitrate: Int? {
        Int(rawValue).map { $0 * 1_000_000 }
    }

    var title: LocalizedStringResource {
        switch self {
        case .auto: "Auto"
        case .unlimited: "No Limit"
        default: "\(rawValue) Mbps"
        }
    }

    /// Compact form for a settings row's value column.
    var shortTitle: String {
        String(localized: title)
    }
}

/// What the server and a timed download said about the link to it.
nonisolated enum ConnectionMeasurement: Equatable, Sendable {
    /// The server sees this device on its own network.
    case inNetwork
    /// Remote, with the measured download rate in bit/s.
    case remote(bitsPerSecond: Int)
}

/// The bitrate ceiling a playback negotiates with. Nil leaves the envelope
/// alone.
nonisolated enum PlaybackQualityLimit {
    /// Share of the measured rate offered to playback. A title's bitrate is
    /// an average, peaks run well above it, and the link is shared.
    static let headroom = 0.7
    /// Below this a transcode is not worth watching; the cap stops here.
    static let minimumBitrate = 1_000_000

    static func maxBitrate(setting: MaximumQuality, connection: ConnectionMeasurement?) -> Int? {
        switch setting {
        case .unlimited:
            return nil
        case .auto:
            guard case .remote(let bitsPerSecond) = connection else { return nil }
            return max(Int(Double(bitsPerSecond) * headroom), minimumBitrate)
        default:
            return setting.fixedBitrate
        }
    }

    /// The step down a viewer accepts after repeated stalls: under both what
    /// the link carried and what was playing, so the next attempt is a
    /// transcode the link can keep up with.
    static func loweredBitrate(linkBitsPerSecond: Int?, playingBitrate: Int?, currentCap: Int?) -> Int {
        var candidates: [Double] = []
        if let linkBitsPerSecond, linkBitsPerSecond > 0 {
            candidates.append(Double(linkBitsPerSecond) * headroom)
        }
        if let playingBitrate, playingBitrate > 0 {
            candidates.append(Double(playingBitrate) / 2)
        }
        if let currentCap, currentCap > 0 {
            candidates.append(Double(currentCap) / 2)
        }
        let lowered = candidates.min().map { Int($0) } ?? 4_000_000
        return max(lowered, minimumBitrate)
    }
}

/// How a remote link is measured: Jellyfin's `Playback/BitrateTest`, timed
/// from the first response byte to the last. A small download first, and a
/// larger one only when the link is fast enough for the small one to end
/// before TCP has ramped up: against the public demo server 0.5, 2 and 8 MiB
/// read 8, 24 and 44 Mbit/s, with half a second to the first byte each.
nonisolated enum ConnectionBitrateProbe {
    struct Step: Equatable, Sendable {
        let bytes: Int
        /// Measure the next step only at or above this rate.
        let continueAbove: Int
    }

    static let steps = [
        Step(bytes: 1_000_000, continueAbove: 4_000_000),
        Step(bytes: 8_000_000, continueAbove: .max),
    ]
    /// Per request; a request that times out leaves the last step's figure.
    static let timeout: TimeInterval = 8
    /// How long a measurement stands. A path change (another Wi-Fi network,
    /// cellular) discards it sooner.
    static let lifetime: TimeInterval = 30 * 60
    /// A failed probe is not retried before every playback.
    static let failureLifetime: TimeInterval = 2 * 60

    static func bitsPerSecond(bytes: Int, seconds: TimeInterval) -> Int? {
        guard bytes > 0, seconds.isFinite, seconds > 0 else { return nil }
        let rate = Double(bytes) * 8 / seconds
        return rate < Double(Int.max) ? Int(rate) : nil
    }
}

/// Measurements per server, for the life of the process.
@MainActor
final class ConnectionMeasurementCache {
    static let shared = ConnectionMeasurementCache()

    private struct Entry {
        let measurement: ConnectionMeasurement?
        let measuredAt: TimeInterval
        let pathGeneration: Int
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<ConnectionMeasurement?, Never>] = [:]

    /// The cached answer, or one measurement shared by every caller that
    /// asks while it runs.
    func measurement(
        for serverKey: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime,
        pathGeneration: Int = NetworkPathObserver.shared.generation,
        measure: @escaping @MainActor () async -> ConnectionMeasurement?
    ) async -> ConnectionMeasurement? {
        if let entry = entries[serverKey], entry.pathGeneration == pathGeneration {
            let lifetime = entry.measurement == nil
                ? ConnectionBitrateProbe.failureLifetime
                : ConnectionBitrateProbe.lifetime
            if now - entry.measuredAt < lifetime { return entry.measurement }
        }
        if let running = inFlight[serverKey] { return await running.value }
        let task = Task { await measure() }
        inFlight[serverKey] = task
        let measurement = await task.value
        inFlight[serverKey] = nil
        entries[serverKey] = Entry(measurement: measurement, measuredAt: now, pathGeneration: pathGeneration)
        return measurement
    }

    func removeAll() {
        entries = [:]
    }
}
