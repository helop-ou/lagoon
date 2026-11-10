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

    @Test func remuxRefusesDirectPlayAndTranscodeRefusesTheVideoCopyToo() throws {
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
        // that just failed. Audio copy stays. Bad audio never reaches the ladder.
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

    // MARK: - After an engine failure

    private func retry(
        _ cause: PlaybackEngineFailure.Cause,
        transport: PlaybackTransportFailure? = nil,
        from current: PlaybackDelivery = .negotiated,
        isClosed: Bool = false,
        isFallingBack: Bool = false,
        canNegotiate: Bool = true
    ) -> PlaybackDelivery? {
        PlaybackController.fallbackDelivery(
            after: cause,
            transport: transport,
            from: current,
            isClosed: isClosed,
            isFallingBack: isFallingBack,
            canNegotiate: canNegotiate
        )
    }

    /// A refused sign-in, a missing file, an untrusted certificate or a lost
    /// network fails every rung the same way, so the ladder stops at once.
    @Test func aSourceThatRefusedEndsTheLadder() {
        for transport: PlaybackTransportFailure in [
            .httpStatus(401), .httpStatus(403), .httpStatus(404), .httpStatus(410),
            .urlError(-1202), .urlError(-1009), .urlError(-1004),
        ] {
            #expect(retry(.delivery, transport: transport) == nil, "\(transport)")
            #expect(retry(.delivery, transport: transport, from: .remux) == nil, "\(transport)")
            #expect(PlaybackSourceRefusal(transport) != nil)
        }
    }

    /// A server error or a dropped connection may not happen on another
    /// rung, and a damaged sample is still a verdict on the bitstream.
    @Test func whatALowerRungMightGetPastStillDescends() {
        #expect(retry(.delivery, transport: .httpStatus(500)) == .remux)
        #expect(retry(.delivery, transport: .httpStatus(503)) == .remux)
        #expect(retry(.delivery, transport: .urlError(-1005)) == .remux)
        #expect(retry(.delivery, transport: .urlError(-1001)) == .remux)
        #expect(retry(.undecodable) == .transcode)
    }

    @Test func eachRefusalSaysWhatTheViewerCanDo() {
        #expect(PlaybackSourceRefusal(.httpStatus(401)) == .signedOut)
        #expect(PlaybackSourceRefusal(.httpStatus(404)) == .missing)
        #expect(PlaybackSourceRefusal(.urlError(-1202)) == .untrustedCertificate)
        #expect(PlaybackSourceRefusal(.urlError(-1009)) == .offline)
        #expect(PlaybackSourceRefusal(.urlError(-1003)) == .unreachable)
        #expect(PlaybackSourceRefusal(nil) == nil)
        #expect(PlaybackSourceRefusal.signedOut.message.contains("Sign in again"))
    }

    /// A delivery failure on the first rung costs a remux, never a straight
    /// re-encode. Only the engine's verdict on the samples skips to one.
    @Test func aLiveSessionDescendsOneRungForTheEnginesVerdict() {
        #expect(retry(.delivery) == .remux)
        #expect(retry(.undecodable) == .transcode)
        #expect(retry(.delivery, from: .remux) == .transcode)
        #expect(retry(.delivery, from: .transcode) == nil)
    }

    /// The fallback under way owns the next attempt. A second failure from
    /// the dying engine must not start another one beside it.
    @Test func noSecondFallbackWhileOneIsUnderWay() {
        #expect(retry(.delivery, isFallingBack: true) == nil)
        #expect(retry(.undecodable, isFallingBack: true) == nil)
    }

    @Test func aClosedPlayerOrNothingToNegotiateWithEndsPlayback() {
        #expect(retry(.delivery, isClosed: true) == nil)
        #expect(retry(.undecodable, isClosed: true) == nil)
        #expect(retry(.delivery, canNegotiate: false) == nil)
        #expect(retry(.undecodable, canNegotiate: false) == nil)
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

    /// Several codecs already carry a 1080p ceiling. Bounding again must not
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

    @Test func dolbyVisionOutsideTheSpecDirectPlaysOnlyOverAPQBaseLayer() throws {
        // Profile 8.6, as Jellyfin labels F1: Drive to Survive S07.
        let pq = try dolbyVisionSource(range: "DOVIInvalid", transfer: "smpte2084")
        #expect(DolbyVisionBaseLayer.directPlayRefusal(for: pq) == nil)
        // No HDR10 base layer under it: the server delivers it.
        for transfer in ["bt709", "arib-std-b67", nil] {
            let other = try dolbyVisionSource(range: "DOVIInvalid", transfer: transfer)
            #expect(DolbyVisionBaseLayer.directPlayRefusal(for: other)?.cause == "dolby vision", "\(transfer ?? "untagged")")
        }
        // Only DOVIInvalid is guarded, and only when direct play was offered.
        let inSpec = try dolbyVisionSource(range: "DOVIWithHLG", transfer: "arib-std-b67")
        #expect(DolbyVisionBaseLayer.directPlayRefusal(for: inSpec) == nil)
        let remuxed = try dolbyVisionSource(range: "DOVIInvalid", transfer: "bt709", directPlay: false)
        #expect(DolbyVisionBaseLayer.directPlayRefusal(for: remuxed) == nil)

        // Refused before an attempt, at the remux rung.
        let refused = try dolbyVisionSource(range: "DOVIInvalid", transfer: "bt709")
        #expect(PlaybackFallbackPolicy.refusal(of: refused)?.rung == .remux)
        #expect(PlaybackFallbackPolicy.refusal(of: pq) == nil)
    }

    @Test func aDiscRipIsRefusedAtTheRungItsLayoutStartsOn() throws {
        let rip = try JellyfinClient.decoder.decode(MediaSource.self, from: Data(#"""
        {"Id":"rip", "Container":"ts", "VideoType":"BluRay", "SupportsDirectPlay":true}
        """#.utf8))
        let refused = try #require(PlaybackFallbackPolicy.refusal(of: rip))
        #expect(refused.rung == .remux)
        #expect(refused.refusal.cause == "disc rip")
    }

    private func dolbyVisionSource(range: String, transfer: String?, directPlay: Bool = true) throws -> MediaSource {
        let transferField = transfer.map { #","ColorTransfer":"\#($0)""# } ?? ""
        return try JellyfinClient.decoder.decode(MediaSource.self, from: Data("""
        {
          "Id":"f1", "Container":"mkv", "SupportsDirectPlay":\(directPlay), "SupportsDirectStream":true,
          "MediaStreams":[
            {"Type":"Video","Codec":"hevc","VideoRangeType":"\(range)"\(transferField)},
            {"Type":"Audio","Codec":"eac3"}
          ]
        }
        """.utf8))
    }
}
