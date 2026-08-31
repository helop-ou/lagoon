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

    // MARK: - The rung that re-encodes

    /// The bound the transcode rung carries, or nil where it carries none.
    private func hdBound(
        _ profile: DeviceProfile.Profile,
        codec: String
    ) -> (width: String?, height: String?) {
        let conditions = profile.codecProfiles.first { $0.codec == codec }?.conditions ?? []
        return (
            conditions.first { $0.property == "Width" }?.value,
            conditions.first { $0.property == "Height" }?.value
        )
    }

    /// Left unbounded the bottom rung inherits a direct-play envelope — 4K
    /// at 120 Mbps — and asks an encoder to produce it. The reference server
    /// answers that at 9.5 fps for a 30 fps source, so the rescue rung
    /// rebuffers worse than the failure it was descended to rescue.
    @Test func theTranscodeRungAsksForSomethingAnEncoderCanKeepUpWith() {
        let bounded = DeviceProfile.boundedForRealtimeTranscode(DeviceProfile.everything)
        #expect(bounded.maxStreamingBitrate == DeviceProfile.realtimeTranscodeBitrateCeiling)
        for codec in ["hevc", "h264", "av1"] {
            let bound = hdBound(bounded, codec: codec)
            #expect(bound.width == "1920", "\(codec) width")
            #expect(bound.height == "1080", "\(codec) height")
        }
    }

    /// Only the rung that re-encodes. `remux` stream-copies the video, so a
    /// resolution condition there would force the very re-encode that rung
    /// exists to avoid, and `negotiated` has to keep direct-playing 4K.
    @Test func theRungsThatDoNotReEncodeKeepTheFullEnvelope() {
        #expect(
            DeviceProfile.lagoon(for: .negotiated).maxStreamingBitrate
                == DeviceProfile.everything.maxStreamingBitrate
        )
        #expect(
            DeviceProfile.lagoon(for: .remux).maxStreamingBitrate
                == DeviceProfile.everything.maxStreamingBitrate
        )
        #expect(
            DeviceProfile.lagoon(for: .transcode).maxStreamingBitrate
                == DeviceProfile.realtimeTranscodeBitrateCeiling
        )
        #expect(hdBound(DeviceProfile.lagoon(for: .remux), codec: "hevc").width == nil)
    }

    /// vp9, vc1, wmv3, mpeg4 and mpeg2video are written with their own 1080p
    /// ceiling, and a device without hardware AV1 gets one applied too. Two
    /// transforms can now each ask for the same bound, and a codec that
    /// collected both would send Jellyfin a duplicated condition list.
    @Test func aCodecTheEnvelopeAlreadyBoundsDoesNotCollectADuplicate() {
        let once = DeviceProfile.boundedForRealtimeTranscode(DeviceProfile.everything)
        let twice = DeviceProfile.boundedForRealtimeTranscode(once)
        for codec in ["hevc", "h264", "av1", "vp9", "vc1", "wmv3", "mpeg4", "mpeg2video"] {
            let first = once.codecProfiles.first { $0.codec == codec }
            let second = twice.codecProfiles.first { $0.codec == codec }
            #expect(first?.conditions.count == second?.conditions.count, "\(codec)")
            #expect(
                first?.conditions.filter { $0.property == "Width" }.count == 1,
                "\(codec) width conditions"
            )
        }
    }
}
