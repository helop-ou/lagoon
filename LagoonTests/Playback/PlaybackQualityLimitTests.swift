import Foundation
import Testing
@testable import Lagoon

/// A remote viewer on a weak link is not offered remuxes the link cannot
/// carry.
@Suite("Playback quality limit")
struct PlaybackQualityLimitTests {
    @Test func autoCapsARemoteServerBelowWhatTheLinkCarried() {
        // A 20 Mbit/s link against a 35 Mbit/s remux.
        let cap = PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .remote(bitsPerSecond: 20_000_000))
        #expect(cap == 14_000_000)
        let profile = DeviceProfile.cappedToBitrate(DeviceProfile.everything, cap)
        #expect(profile.maxStreamingBitrate == 14_000_000)
        // The server checks this one before offering the original file.
        #expect(profile.maxStaticBitrate == 14_000_000)
    }

    /// A bitrate alone gets a 4K source re-encoded at 4K, so a low cap
    /// brings the encoded picture down with it. A high one leaves it alone.
    @Test func aLowCapBoundsTheResolutionAndAHighOneDoesNot() {
        func ceiling(_ bitrate: Int) -> String? {
            DeviceProfile.cappedToBitrate(DeviceProfile.everything, bitrate)
                .transcodingProfiles.first { $0.type == "Video" }?
                .conditions.first { $0.property == "Width" }?.value
        }
        #expect(ceiling(2_000_000) == "1280")
        #expect(ceiling(14_000_000) == "1920")
        #expect(ceiling(35_000_000) == nil)
    }

    /// A 3.1 Mbit/s 1080p episode under a 3.5 Mbit/s cap was re-encoded to
    /// 720p, at more bits than the original. The ceiling bounds only what the
    /// server encodes, never which files direct-play.
    @Test func aCapNeverBoundsWhatDirectPlays() throws {
        let capped = DeviceProfile.cappedToBitrate(DeviceProfile.everything, 3_500_000)
        let original = try JSONSerialization.jsonObject(
            with: JellyfinClient.encoder.encode(DeviceProfile.everything.codecProfiles)
        ) as? NSArray
        let sent = try JSONSerialization.jsonObject(
            with: JellyfinClient.encoder.encode(capped.codecProfiles)
        ) as? NSArray
        #expect(original != nil)
        #expect(sent == original)
    }

    /// Jellyfin reads the ceiling from the transcoding profile's
    /// `Conditions`.
    @Test func theCeilingReachesTheServerOnTheTranscodingProfile() throws {
        let capped = DeviceProfile.cappedToBitrate(DeviceProfile.everything, 2_000_000)
        let json = try #require(try JSONSerialization.jsonObject(
            with: JellyfinClient.encoder.encode(capped)
        ) as? [String: Any])
        let transcoding = try #require((json["TranscodingProfiles"] as? [[String: Any]])?.first)
        let conditions = try #require(transcoding["Conditions"] as? [[String: Any]])
        let width = try #require(conditions.first { $0["Property"] as? String == "Width" })
        #expect(width["Condition"] as? String == "LessThanEqual")
        #expect(width["Value"] as? String == "1280")
        #expect(width["IsRequired"] as? Bool == true)
        #expect(conditions.contains { $0["Property"] as? String == "Height" && $0["Value"] as? String == "720" })
    }

    /// The transcode rung withholds direct play, and Jellyfin then skips the
    /// transcoding profile's conditions, so the ceiling has to sit on the
    /// codec profiles there. The remux rung must keep them clear, or a file
    /// it could copy gets re-encoded.
    @Test func onlyTheTranscodeRungBoundsItsCodecProfiles() {
        func width(_ delivery: PlaybackDelivery) -> String? {
            DeviceProfile.lagoon(for: delivery, maxBitrate: 2_000_000)
                .codecProfiles.first { $0.codec == "h264" }?
                .conditions.first { $0.property == "Width" }?.value
        }
        #expect(width(.transcode) == "1280")
        let uncapped = DeviceProfile.lagoon.codecProfiles.first { $0.codec == "h264" }?
            .conditions.first { $0.property == "Width" }?.value
        #expect(width(.remux) == uncapped)
        #expect(width(.negotiated) == uncapped)
    }

    /// A 73.5 Mbit/s Dolby Vision remux transcoded on fast Wi-Fi to a
    /// remote server: the probe read what it could and 70% of that was not
    /// enough.
    @Test func autoLeavesAFastLinkUncapped() {
        let fast = PlaybackQualityLimit.unboundedLinkBitsPerSecond
        #expect(PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .remote(bitsPerSecond: fast)) == nil)
        #expect(PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .remote(bitsPerSecond: 90_000_000)) == nil)
        #expect(PlaybackQualityLimit.maxBitrate(setting: .auto, connection: .remote(bitsPerSecond: fast - 1)) != nil)
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

    @Test func theSettingRoundTripsAndDefaultsToAuto() throws {
        let suite = "PlaybackQualityLimitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MaximumQuality.stored(in: defaults) == .auto)
        defaults.set("nonsense", forKey: MaximumQuality.defaultsKey)
        #expect(MaximumQuality.stored(in: defaults) == .auto)
        defaults.set(MaximumQuality.mbps8.rawValue, forKey: MaximumQuality.defaultsKey)
        #expect(MaximumQuality.stored(in: defaults) == .mbps8)
        defaults.set(MaximumQuality.unlimited.rawValue, forKey: MaximumQuality.defaultsKey)
        #expect(MaximumQuality.stored(in: defaults) == .unlimited)
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
        // A stub is fast on a quiet machine but not on a loaded runner.
        #expect(sizes.first == "1000000")
        #expect(Array(["1000000", "8000000"].prefix(sizes.count)) == sizes)
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

    /// A 4 Mbit/s reading taken far from the router held a whole evening
    /// of 22-minute episodes to a transcode. The next one asks again.
    @Test @MainActor func aLowReadingIsMeasuredAgainSooner() async {
        let cache = ConnectionMeasurementCache()
        var readings = [4_000_000, 90_000_000]
        let measure: @MainActor () async -> ConnectionMeasurement? = {
            .remote(bitsPerSecond: readings.removeFirst())
        }
        _ = await cache.measurement(for: "https://jf.example", now: 0, pathGeneration: 1, measure: measure)
        let soon = await cache.measurement(for: "https://jf.example", now: 60, pathGeneration: 1, measure: measure)
        #expect(soon == .remote(bitsPerSecond: 4_000_000))
        let nextEpisode = await cache.measurement(
            for: "https://jf.example", now: ConnectionBitrateProbe.lowReadingLifetime, pathGeneration: 1, measure: measure
        )
        #expect(nextEpisode == .remote(bitsPerSecond: 90_000_000))
        #expect(ConnectionBitrateProbe.lowReadingLifetime < ConnectionBitrateProbe.lifetime)
        // Low means Auto would hold playback under the transcode rung's ceiling.
        let lowest = PlaybackQualityLimit.maxBitrate(
            setting: .auto, connection: .remote(bitsPerSecond: ConnectionBitrateProbe.lowReadingBelow)
        )
        #expect(lowest == DeviceProfile.realtimeTranscodeBitrateCeiling)
        #expect(ConnectionBitrateProbe.lifetime(of: .remote(bitsPerSecond: 28_000_000)) == ConnectionBitrateProbe.lowReadingLifetime)
        #expect(ConnectionBitrateProbe.lifetime(of: .remote(bitsPerSecond: 30_000_000)) == ConnectionBitrateProbe.lifetime)
        #expect(ConnectionBitrateProbe.lifetime(of: .inNetwork) == ConnectionBitrateProbe.lifetime)
    }

    @Test @MainActor func aMeasurementIsReusedUntilItExpiresOrTheNetworkChanges() async {
        let cache = ConnectionMeasurementCache()
        var probes = 0
        let measure: @MainActor () async -> ConnectionMeasurement? = {
            probes += 1
            return .remote(bitsPerSecond: 50_000_000)
        }
        let first = await cache.measurement(for: "https://jf.example", now: 0, pathGeneration: 1, measure: measure)
        #expect(first == .remote(bitsPerSecond: 50_000_000))
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
