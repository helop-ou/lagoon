import Foundation
import Testing
@testable import Lagoon

@Suite("Playback fallback")
struct PlaybackFallbackTests {
    @Test func aDeliveryFailureTriesTheCheapRemuxBeforeATranscode() {
        #expect(
            PlaybackFallbackPolicy.next(after: .negotiated, cause: .delivery) == .remux
        )
        #expect(
            PlaybackFallbackPolicy.next(after: .remux, cause: .delivery) == .transcode
        )
        #expect(
            PlaybackFallbackPolicy.next(after: .transcode, cause: .delivery) == nil
        )
    }

    @Test func anUndecodableStreamSkipsTheRemuxThatCouldNotHelp() {
        // A remux hands the decoder the same bitstream in a new container,
        // so spending a server-side rewrite to watch it fail again is pure
        // latency. Straight to the rung that re-encodes.
        #expect(
            PlaybackFallbackPolicy.next(after: .negotiated, cause: .undecodable) == .transcode
        )
        #expect(
            PlaybackFallbackPolicy.next(after: .transcode, cause: .undecodable) == nil
        )
    }

    @Test func theLadderAlwaysTerminates() {
        // Whatever the failure, following `next` from any rung has to reach
        // nil: an engine that fails every way must end in the error overlay,
        // never in a loop of restarts.
        for start in PlaybackDelivery.allCases {
            for cause in [PlaybackEngineFailure.Cause.delivery, .undecodable] {
                var delivery: PlaybackDelivery? = start
                var steps = 0
                while let current = delivery, steps < 8 {
                    delivery = PlaybackFallbackPolicy.next(after: current, cause: cause)
                    steps += 1
                }
                #expect(delivery == nil)
                #expect(steps <= PlaybackDelivery.allCases.count)
            }
        }
    }

    @Test func demuxErrorsSayWhetherRedeliveryCouldHelp() {
        // Container and transport problems are exactly what a server-side
        // remux fixes; a codec outside the envelope is not.
        #expect(DemuxError.openFailed("moov atom not found").cause == .delivery)
        #expect(DemuxError.seekFailed("invalid argument").cause == .delivery)
        #expect(DemuxError.unsupportedVideo("av1").cause == .undecodable)
    }

    @Test func eachRungWithdrawsExactlyOnePermissionFromJellyfin() throws {
        // Jellyfin defaults all four flags to true, so the negotiated rung
        // has to send what the server would have assumed on its own.
        #expect(PlaybackDelivery.negotiated.flags == PlaybackDeliveryFlags(
            enableDirectPlay: true,
            enableDirectStream: true,
            allowVideoStreamCopy: true,
            allowAudioStreamCopy: true
        ))
        // Remux: direct play is refused, everything that avoids a re-encode
        // stays on the table.
        #expect(PlaybackDelivery.remux.flags == PlaybackDeliveryFlags(
            enableDirectPlay: false,
            enableDirectStream: true,
            allowVideoStreamCopy: true,
            allowAudioStreamCopy: true
        ))
        // Transcode: video stream copy has to go too, or the server can
        // satisfy the request by copying the bitstream that just failed.
        // Audio copy stays — undecodable audio never reaches the ladder.
        #expect(PlaybackDelivery.transcode.flags == PlaybackDeliveryFlags(
            enableDirectPlay: false,
            enableDirectStream: false,
            allowVideoStreamCopy: false,
            allowAudioStreamCopy: true
        ))
    }

    /// The whole feature is silent if these key names are wrong: Jellyfin
    /// ignores what it does not recognize, would answer every rung with the
    /// same direct play, and the ladder would descend to a transcode that is
    /// also ignored.
    @Test func theRequestCarriesJellyfinsOwnFlagNames() throws {
        for delivery in PlaybackDelivery.allCases {
            let request = JellyfinClient.PlaybackInfoRequest(
                deviceProfile: DeviceProfile.lagoon,
                autoOpenLiveStream: true,
                maxStreamingBitrate: 120_000_000,
                delivery: delivery
            )
            let data = try JellyfinClient.encoder.encode(request)
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let flags = delivery.flags
            #expect(json["EnableDirectPlay"] as? Bool == flags.enableDirectPlay)
            #expect(json["EnableDirectStream"] as? Bool == flags.enableDirectStream)
            #expect(json["AllowVideoStreamCopy"] as? Bool == flags.allowVideoStreamCopy)
            #expect(json["AllowAudioStreamCopy"] as? Bool == flags.allowAudioStreamCopy)
            // The profile still has to ride along on every rung — a retry
            // that dropped it would let the server pick anything at all.
            #expect(json["DeviceProfile"] != nil)
            #expect(json["MaxStreamingBitrate"] as? Int == 120_000_000)
        }
    }
}
