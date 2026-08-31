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

    @Test func aBlurayImageIsRecognisedFromTheFieldsThatGiveItAway() throws {
        // Jellyfin describes WALL·E's Blu-ray image as container `ts` with
        // direct play available, then serves 64 GB of UDF. VideoType and
        // IsoType are the only fields that say so, and both have to survive
        // decoding (HEL-133).
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
        // This one Lagoon opens itself, so the negotiated rung is where it
        // belongs and there is nothing for the HUD to explain.
        #expect(PlaybackFallbackPolicy.start(for: layout) == .negotiated)
        #expect(layout.directPlayRefusal == nil)
    }

    @Test func everyOtherDiscStartsAtTheRungTheServerRebuildsItFrom() {
        // A DVD image needs a VIDEO_TS reader this client does not have, and
        // a rip is served as its folder, which Jellyfin gives no way to read
        // inside of. Both belong to the server, and neither should cost a
        // failed open to discover.
        let dvd = PlaybackSourceLayout(videoType: "Iso", isoType: "Dvd")
        let rip = PlaybackSourceLayout(videoType: "BluRay", isoType: nil)
        #expect(dvd == .discImage)
        #expect(rip == .discFolder)
        for layout in [dvd, rip] {
            #expect(PlaybackFallbackPolicy.start(for: layout) == .remux)
            #expect(layout.directPlayRefusal != nil)
            #expect(layout.isDisc)
        }
        #expect(PlaybackSourceLayout(videoType: "Dvd", isoType: nil) == .discFolder)
        // An image the server did not type is not assumed to be readable.
        #expect(PlaybackSourceLayout(videoType: "Iso", isoType: nil) == .discImage)
    }

    @Test func onlyAPlainFileIsTriedAtTheNegotiatedRung() {
        #expect(PlaybackSourceLayout(videoType: nil, isoType: nil) == .file)
        #expect(PlaybackSourceLayout(videoType: "VideoFile", isoType: nil) == .file)
        // An unrecognised value stays a file: one failed open and a rung of
        // ladder is a smaller price than silently forcing a server transcode
        // on something that might have played.
        #expect(PlaybackSourceLayout(videoType: "HoloDisc", isoType: nil) == .file)
        #expect(PlaybackFallbackPolicy.start(for: .file) == .negotiated)
        #expect(PlaybackSourceLayout.file.directPlayRefusal == nil)
        #expect(!PlaybackSourceLayout.file.isDisc)
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

/// HEL-108: the profile advertised 120 Mbps on every path, so an 80 Mbps
/// remux was offered as direct play over cellular.
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

    /// Never raises a ceiling that was already lower — the transcode rung
    /// asks for 20 Mbps and a metered path must not undo that.
    @Test func theCapOnlyEverLowers() {
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 1_000_000,
            cost: cellular,
            allowFullQuality: false
        ) == 1_000_000)
    }

    /// The static ceiling has to come down with the streaming one: it is
    /// what the server checks before offering the original file, so leaving
    /// it high would let an 89 Mbps remux direct-play over cellular anyway.
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
        // tvOS is a wired appliance; the cap is deliberately not applied.
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

    /// Two transforms can now each ask for a geometry bound and they no
    /// longer ask for the same number. The tighter one has to survive, or a
    /// metered 720p cap would be undone by a 1080p fallback bound.
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
        // And the order does not matter.
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
}
