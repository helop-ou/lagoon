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
