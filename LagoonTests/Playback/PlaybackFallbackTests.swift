import Foundation
import Testing
import LagoonEngine
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
        // A remux hands the decoder the same bitstream, so go straight to the
        // rung that re-encodes.
        #expect(
            PlaybackFallbackPolicy.next(after: .negotiated, cause: .undecodable) == .transcode
        )
        #expect(
            PlaybackFallbackPolicy.next(after: .transcode, cause: .undecodable) == nil
        )
    }

    @Test func aBlurayImageIsRecognisedFromTheFieldsThatGiveItAway() throws {
        // Jellyfin reports a Blu-ray image as container `ts` with direct play,
        // then serves raw UDF. Only VideoType and IsoType give it away.
        let image = try JellyfinClient.decoder.decode(MediaSource.self, from: Data(#"""
        {
          "Id":"disc", "Container":"ts", "VideoType":"Iso", "IsoType":"BluRay",
          "SupportsDirectPlay":true, "SupportsDirectStream":true
        }
        """#.utf8))
        #expect(image.videoType == "Iso")
        #expect(image.isoType == "BluRay")
        let layout = PlaybackSourceLayout(videoType: image.videoType, isoType: image.isoType)
        #expect(layout == .blurayImage)
        // Lagoon opens this itself.
        #expect(PlaybackFallbackPolicy.start(for: layout) == .negotiated)
        #expect(layout.directPlayRefusal == nil)
    }

    @Test func aDVDImageIsReadHereToo() {
        // The UDF reader mounts it and the software path deinterlaces it.
        let dvd = PlaybackSourceLayout(videoType: "Iso", isoType: "Dvd")
        #expect(dvd == .dvdImage)
        #expect(dvd.isReadableDisc)
        #expect(PlaybackFallbackPolicy.start(for: dvd) == .negotiated)
        #expect(dvd.directPlayRefusal == nil)
    }

    @Test func everyOtherDiscStartsAtTheRungTheServerRebuildsItFrom() {
        // Jellyfin gives no way to read inside a rip folder, and an untyped
        // image is not assumed readable. Both start on the server's rung.
        let rip = PlaybackSourceLayout(videoType: "BluRay", isoType: nil)
        let untyped = PlaybackSourceLayout(videoType: "Iso", isoType: nil)
        #expect(rip == .discFolder)
        #expect(untyped == .discImage)
        for layout in [rip, untyped] {
            #expect(PlaybackFallbackPolicy.start(for: layout) == .remux)
            #expect(layout.directPlayRefusal != nil)
            #expect(layout.isDisc)
            #expect(!layout.isReadableDisc)
        }
        #expect(PlaybackSourceLayout(videoType: "Dvd", isoType: nil) == .discFolder)
    }

    @Test func onlyAPlainFileIsTriedAtTheNegotiatedRung() {
        #expect(PlaybackSourceLayout(videoType: nil, isoType: nil) == .file)
        #expect(PlaybackSourceLayout(videoType: "VideoFile", isoType: nil) == .file)
        // An unknown value stays a file: one failed open costs less than
        // forcing a transcode on something that might have played.
        #expect(PlaybackSourceLayout(videoType: "HoloDisc", isoType: nil) == .file)
        #expect(PlaybackFallbackPolicy.start(for: .file) == .negotiated)
        #expect(PlaybackSourceLayout.file.directPlayRefusal == nil)
        #expect(!PlaybackSourceLayout.file.isDisc)
    }

    @Test func theLadderAlwaysTerminates() {
        // Every path reaches nil, so repeated failure ends in the error
        // overlay, never a restart loop.
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

    @Test func eachRungWithdrawsExactlyOnePermissionFromJellyfin() throws {
        // Jellyfin defaults all four flags to true.
        #expect(PlaybackDelivery.negotiated.flags == PlaybackDeliveryFlags(
            enableDirectPlay: true,
            enableDirectStream: true,
            allowVideoStreamCopy: true,
            allowAudioStreamCopy: true
        ))
        // Remux: refuse direct play only.
        #expect(PlaybackDelivery.remux.flags == PlaybackDeliveryFlags(
            enableDirectPlay: false,
            enableDirectStream: true,
            allowVideoStreamCopy: true,
            allowAudioStreamCopy: true
        ))
        // Transcode: refuse video copy too, or the server copies the bitstream
        // that just failed. Audio copy stays; bad audio never reaches the ladder.
        #expect(PlaybackDelivery.transcode.flags == PlaybackDeliveryFlags(
            enableDirectPlay: false,
            enableDirectStream: false,
            allowVideoStreamCopy: false,
            allowAudioStreamCopy: true
        ))
    }

    /// Jellyfin silently ignores unknown keys, so a wrong name would make
    /// every rung the same direct play.
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
            // Without the profile the server could pick anything.
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

    /// Unbounded, the transcode rung asks for 4K at 120 Mbps, which the
    /// reference server encodes at 9.5 fps for a 30 fps source.
    @Test func theTranscodeRungAsksForSomethingAnEncoderCanKeepUpWith() {
        let bounded = DeviceProfile.boundedForRealtimeTranscode(DeviceProfile.everything)
        #expect(bounded.maxStreamingBitrate == DeviceProfile.realtimeTranscodeBitrateCeiling)
        for codec in ["hevc", "h264", "av1"] {
            let bound = hdBound(bounded, codec: codec)
            #expect(bound.width == "1920", "\(codec) width")
            #expect(bound.height == "1080", "\(codec) height")
        }
    }

    /// A resolution bound on `remux` would force a re-encode, and
    /// `negotiated` must keep direct-playing 4K.
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

    /// Several codecs already carry a 1080p ceiling; bounding again must not
    /// duplicate the condition.
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

@Suite("Metered path cap")
struct MeteredPathTests {
    private let cellular = NetworkPathCost(isExpensive: true, isConstrained: false)
    private let lowData = NetworkPathCost(isExpensive: false, isConstrained: true)

    @Test func onlyAMeteredPathIsCapped() {
        #expect(MeteredPathPolicy.applies(cost: .unrestricted, allowFullQuality: false) == false)
        #expect(MeteredPathPolicy.applies(cost: cellular, allowFullQuality: false))
        #expect(MeteredPathPolicy.applies(cost: lowData, allowFullQuality: false))
    }

    /// Both flags mean the same thing here: do not pull the original over
    /// this path.
    @Test func eitherFlagIsEnough() {
        #expect(NetworkPathCost.unrestricted.isMetered == false)
        #expect(cellular.isMetered)
        #expect(lowData.isMetered)
        #expect(NetworkPathCost(isExpensive: true, isConstrained: true).isMetered)
    }

    /// The viewer's override wins, because Apple can report that a path is
    /// expensive but never that it is slow.
    @Test func theOverrideRestoresFullQuality() {
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 120_000_000,
            cost: cellular,
            allowFullQuality: true
        ) == 120_000_000)
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 120_000_000,
            cost: cellular,
            allowFullQuality: false
        ) == MeteredPathPolicy.maxBitrate)
    }

    /// Never raises a lower ceiling, such as the transcode rung's.
    @Test func theCapOnlyEverLowers() {
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 1_000_000,
            cost: cellular,
            allowFullQuality: false
        ) == 1_000_000)
    }

    /// The server checks the static ceiling before offering the original
    /// file, so it must come down too.
    @Test func theStaticCeilingComesDownToo() {
        let capped = DeviceProfile.cappedForMeteredPath(
            DeviceProfile.everything,
            cost: cellular,
            allowFullQuality: false
        )
        #if os(iOS)
        #expect(capped.maxStreamingBitrate == MeteredPathPolicy.maxBitrate)
        #expect(capped.maxStaticBitrate <= MeteredPathPolicy.maxBitrate)
        #else
        // tvOS is a wired appliance; no cap.
        #expect(capped.maxStreamingBitrate == DeviceProfile.everything.maxStreamingBitrate)
        #endif
    }

    @Test func anOrdinaryPathIsUntouched() {
        let same = DeviceProfile.cappedForMeteredPath(
            DeviceProfile.everything,
            cost: .unrestricted,
            allowFullQuality: false
        )
        #expect(same.maxStreamingBitrate == DeviceProfile.everything.maxStreamingBitrate)
        #expect(same.maxStaticBitrate == DeviceProfile.everything.maxStaticBitrate)
    }

    /// The tighter bound wins, or a 1080p fallback bound would undo a
    /// metered 720p cap.
    @Test func twoGeometryBoundsResolveToTheTighter() {
        let hd = DeviceProfile.boundedTo(
            DeviceProfile.everything.codecProfiles.first { $0.codec == "hevc" }!,
            width: 1920,
            height: 1080
        )
        let both = DeviceProfile.boundedTo(hd, width: 1280, height: 720)
        let widths = both.conditions.filter { $0.property == "Width" }
        let heights = both.conditions.filter { $0.property == "Height" }
        #expect(widths.count == 1)
        #expect(heights.count == 1)
        #expect(widths.first?.value == "1280")
        #expect(heights.first?.value == "720")
        // In either order.
        let reversed = DeviceProfile.boundedTo(
            DeviceProfile.boundedTo(
                DeviceProfile.everything.codecProfiles.first { $0.codec == "hevc" }!,
                width: 1280,
                height: 720
            ),
            width: 1920,
            height: 1080
        )
        #expect(reversed.conditions.first { $0.property == "Width" }?.value == "1280")
    }

    // MARK: - Restart-point retry

}
