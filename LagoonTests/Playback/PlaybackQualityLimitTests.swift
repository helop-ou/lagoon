import Foundation
import Testing
@testable import Lagoon

/// HEL-262: a remote viewer on weak Wi-Fi was offered 31–41 Mbps remuxes the
/// link could not carry, and stalled through them.
@Suite("Playback quality limit")
struct PlaybackQualityLimitTests {
    @Test func autoCapsARemoteServerBelowWhatTheLinkCarried() {
        // The tester's link: about 20 Mbit/s against a 35 Mbit/s remux.
        let cap = PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .remote(bitsPerSecond: 20_000_000))
        #expect(cap == 14_000_000)
        let profile = DeviceProfile.cappedToBitrate(DeviceProfile.everything, cap)
        #expect(profile.maxStreamingBitrate == 14_000_000)
        // The server checks this one before offering the original file.
        #expect(profile.maxStaticBitrate == 14_000_000)
    }

    @Test func autoLeavesAServerOnThisNetworkAtFullQuality() {
        #expect(PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .inNetwork) == nil)
        // An unanswered probe keeps today's ceiling rather than guessing.
        #expect(PlaybackQualityLimit.maxBitrate(setting: .auto, connection: nil) == nil)
        let untouched = DeviceProfile.cappedToBitrate(DeviceProfile.everything, nil)
        #expect(untouched.maxStreamingBitrate == DeviceProfile.everything.maxStreamingBitrate)
        #expect(untouched.maxStaticBitrate == DeviceProfile.everything.maxStaticBitrate)
    }

    @Test func aChosenMaximumOverridesAutoWhereverTheServerIs() {
        #expect(PlaybackQualityLimit.maxBitrate(setting: .mbps8, connection: .inNetwork) == 8_000_000)
        #expect(PlaybackQualityLimit.maxBitrate(setting: .mbps8, connection: .remote(bitsPerSecond: 90_000_000)) == 8_000_000)
        #expect(PlaybackQualityLimit.maxBitrate(setting: .unlimited, connection: .remote(bitsPerSecond: 2_000_000)) == nil)
    }

    @Test func aVerySlowLinkStillGetsAWatchableFloor() {
        #expect(PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .remote(bitsPerSecond: 300_000))
            == PlaybackQualityLimit.minimumBitrate)
    }

    @Test func aCapNeverRaisesTheEnvelope() {
        let capped = DeviceProfile.cappedToBitrate(DeviceProfile.everything, 500_000_000)
        #expect(capped.maxStreamingBitrate == DeviceProfile.everything.maxStreamingBitrate)
        #expect(capped.maxStaticBitrate == DeviceProfile.everything.maxStaticBitrate)
        // The transcode rung keeps its own, lower ceiling under a higher cap.
        let transcode = DeviceProfile.lagoon(for: .transcode, maxBitrate: 40_000_000)
        #expect(transcode.maxStreamingBitrate == DeviceProfile.realtimeTranscodeBitrateCeiling)
        #expect(DeviceProfile.lagoon(for: .negotiated, maxBitrate: 10_000_000).maxStreamingBitrate == 10_000_000)
    }

    @Test func theSettingRoundTripsAndDefaultsToAuto() {
        #expect(MaximumQuality(rawValue: "nonsense") == nil)
        #expect(MaximumQuality.allCases.first == .auto)
        #expect(MaximumQuality.mbps20.fixedBitrate == 20_000_000)
        #expect(MaximumQuality.auto.fixedBitrate == nil)
        #expect(MaximumQuality.unlimited.fixedBitrate == nil)
        // Fixed steps run from high to low, so the picker reads in order.
        let steps = MaximumQuality.allCases.compactMap(\.fixedBitrate)
        #expect(steps == steps.sorted(by: >))
    }

    @Test func aLowerQualityStepsBelowBothTheLinkAndWhatWasPlaying() {
        // Stalling on a 35 Mbit/s remux over a 12 Mbit/s link.
        #expect(PlaybackQualityLimit.loweredBitrate(
            linkBitsPerSecond: 12_000_000, playingBitrate: 35_000_000, currentCap: nil
        ) == 8_400_000)
        // A transcode that still stalls halves again.
        #expect(PlaybackQualityLimit.loweredBitrate(
            linkBitsPerSecond: 30_000_000, playingBitrate: nil, currentCap: 8_000_000
        ) == 4_000_000)
        // Nothing known: a conservative 4 Mbit/s.
        #expect(PlaybackQualityLimit.loweredBitrate(linkBitsPerSecond: nil, playingBitrate: nil, currentCap: nil)
            == 4_000_000)
        #expect(PlaybackQualityLimit.loweredBitrate(
            linkBitsPerSecond: 400_000, playingBitrate: nil, currentCap: nil
        ) == PlaybackQualityLimit.minimumBitrate)
    }

    @Test func theProbeConvertsATimedDownloadToBitsPerSecond() {
        #expect(ConnectionBitrateProbe.bitsPerSecond(bytes: 2_000_000, seconds: 0.8) == 20_000_000)
        #expect(ConnectionBitrateProbe.bitsPerSecond(bytes: 0, seconds: 1) == nil)
        #expect(ConnectionBitrateProbe.bitsPerSecond(bytes: 1_000, seconds: 0) == nil)
        // A slow first sample stops the probe before the larger download.
        let first = ConnectionBitrateProbe.steps[0]
        #expect(first.bytes < ConnectionBitrateProbe.steps[1].bytes)
        #expect(first.continueAbove > PlaybackQualityLimit.minimumBitrate)
    }

    /// A stub server: `System/Endpoint` answers `inNetwork`, BitrateTest
    /// serves the bytes asked for, PlaybackInfo answers with no sources.
    private static func stubServer(host: String, inNetwork: Bool) {
        StubURLProtocol.register(host: host) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/System/Endpoint") {
                return (200, [:], Data(#"{"IsLocal":false,"IsInNetwork":\#(inNetwork)}"#.utf8))
            }
            if path.hasSuffix("/Playback/BitrateTest") {
                let size = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "size" }?.value.flatMap(Int.init) ?? 0
                return (200, [:], Data(count: size))
            }
            return (200, [:], Data(#"{"MediaSources":[]}"#.utf8))
        }
    }

    private static func sentMaxStreamingBitrate(host: String) throws -> Int? {
        let request = try #require(StubURLProtocol.requests(host: host).last { $0.url?.path.hasSuffix("/PlaybackInfo") == true })
        let body = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        })
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return json["MaxStreamingBitrate"] as? Int
    }

    @Test @MainActor func aServerOnThisNetworkIsNeverProbed() async throws {
        let host = "quality-local.test"
        Self.stubServer(host: host, inNetwork: true)
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "quality-tests")
        #expect(await client.measureConnection() == .inNetwork)
        #expect(!StubURLProtocol.requests(host: host).contains { $0.url?.path.hasSuffix("BitrateTest") == true })
    }

    @Test @MainActor func aRemoteServerIsProbedSmallThenLarge() async throws {
        let host = "quality-remote.test"
        Self.stubServer(host: host, inNetwork: false)
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "quality-tests")
        let measurement = await client.measureConnection()
        guard case .remote(let bitsPerSecond) = measurement else {
            Issue.record("Expected a remote measurement, got \(String(describing: measurement))")
            return
        }
        #expect(bitsPerSecond > 0)
        let sizes = StubURLProtocol.requests(host: host)
            .filter { $0.url?.path.hasSuffix("BitrateTest") == true }
            .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
        // A stub answers instantly, so the probe always takes the large step.
        #expect(sizes == ["1000000", "8000000"])
    }

    @Test @MainActor func anAcceptedLowerQualityReachesTheServer() async throws {
        let host = "quality-cap.test"
        Self.stubServer(host: host, inNetwork: true)
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "quality-tests")
        _ = try? await client.playbackInfo(itemId: "film", maxBitrate: 8_400_000)
        #expect(try Self.sentMaxStreamingBitrate(host: host) == 8_400_000)
        // Without one, a server on this network keeps the full envelope.
        _ = try? await client.playbackInfo(itemId: "film")
        #expect(try Self.sentMaxStreamingBitrate(host: host) == DeviceProfile.lagoon.maxStreamingBitrate)
    }

    @Test @MainActor func aMeasurementIsReusedUntilItExpiresOrTheNetworkChanges() async {
        let cache = ConnectionMeasurementCache()
        var probes = 0
        let measure: @MainActor () async -> ConnectionMeasurement? = {
            probes += 1
            return .remote(bitsPerSecond: 10_000_000)
        }
        let first = await cache.measurement(for: "https://jf.example", now: 0, pathGeneration: 1, measure: measure)
        #expect(first == .remote(bitsPerSecond: 10_000_000))
        _ = await cache.measurement(for: "https://jf.example", now: 600, pathGeneration: 1, measure: measure)
        #expect(probes == 1)
        // Another Wi-Fi network: measure again.
        _ = await cache.measurement(for: "https://jf.example", now: 601, pathGeneration: 2, measure: measure)
        #expect(probes == 2)
        // Half an hour on.
        _ = await cache.measurement(for: "https://jf.example", now: 601 + ConnectionBitrateProbe.lifetime, pathGeneration: 2, measure: measure)
        #expect(probes == 3)
        // Another server is its own measurement.
        _ = await cache.measurement(for: "https://other.example", now: 602 + ConnectionBitrateProbe.lifetime, pathGeneration: 2, measure: measure)
        #expect(probes == 4)
    }

    @Test @MainActor func aFailedProbeIsRetriedSoonButNotBeforeEveryPlayback() async {
        let cache = ConnectionMeasurementCache()
        var probes = 0
        let measure: @MainActor () async -> ConnectionMeasurement? = {
            probes += 1
            return nil
        }
        _ = await cache.measurement(for: "https://jf.example", now: 0, pathGeneration: 1, measure: measure)
        _ = await cache.measurement(for: "https://jf.example", now: 30, pathGeneration: 1, measure: measure)
        #expect(probes == 1)
        _ = await cache.measurement(for: "https://jf.example", now: ConnectionBitrateProbe.failureLifetime, pathGeneration: 1, measure: measure)
        #expect(probes == 2)
    }
}
