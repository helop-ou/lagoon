import Foundation
import Testing
@testable import Lagoon

/// The viewer hears whenever the server converts what plays, and may play
/// the original when only a cap stood in its way.
@Suite("Playback transcode notice")
@MainActor
struct PlaybackTranscodeNoticeTests {
    private static let auto = PlaybackOffer(maxStreamingBitrate: 31_500_000, cap: .auto, probedBitsPerSecond: 45_000_000)

    private func notice(
        method: PlayMethod = .transcode,
        delivery: PlaybackDelivery = .negotiated,
        offer: PlaybackOffer? = auto,
        reasons: [String],
        isDownload: Bool = false,
        isInGroup: Bool = false
    ) -> PlaybackTranscodeNotice? {
        PlaybackTranscodeNotice.notice(
            method: method,
            delivery: delivery,
            offer: offer,
            transcodeReasons: reasons,
            isDownload: isDownload,
            isInGroup: isInGroup
        )
    }

    /// A 73.5 Mbit/s remux on Auto: the original would have played.
    @Test func aCapAloneOffersTheOriginal() {
        #expect(notice(reasons: ["ContainerBitrateExceedsLimit"])
            == .capped(.auto, probedBitsPerSecond: 45_000_000, maxBitrate: 31_500_000))
        let setting = PlaybackOffer(maxStreamingBitrate: 20_000_000, cap: .setting, probedBitsPerSecond: nil)
        #expect(notice(offer: setting, reasons: ["VideoBitrateNotSupported", "AudioBitrateNotSupported"])
            == .capped(.setting, probedBitsPerSecond: nil, maxBitrate: 20_000_000))
        let metered = PlaybackOffer(maxStreamingBitrate: 8_000_000, cap: .metered, probedBitsPerSecond: nil)
        #expect(notice(offer: metered, reasons: ["ContainerBitrateExceedsLimit", "ContainerNotSupported"])
            == .capped(.metered, probedBitsPerSecond: nil, maxBitrate: 8_000_000))
    }

    @Test func aGroupHearsOfTheCapButCannotRestart() {
        #expect(notice(reasons: ["ContainerBitrateExceedsLimit"], isInGroup: true) == .converting(.qualityLimit))
    }

    /// The viewer asked for less after stalls, so there is nothing to tell.
    @Test func aLoweredQualityIsNotNews() {
        let lowered = PlaybackOffer(maxStreamingBitrate: 4_000_000, cap: .lowered, probedBitsPerSecond: nil)
        #expect(notice(offer: lowered, reasons: ["ContainerBitrateExceedsLimit"]) == nil)
    }

    @Test func aBitrateAboveTheDeviceWithNoCapIsInformation() {
        let none = PlaybackOffer(maxStreamingBitrate: 120_000_000, cap: .none, probedBitsPerSecond: nil)
        #expect(notice(offer: none, reasons: ["ContainerBitrateExceedsLimit"]) == .converting(.bitrate))
        #expect(notice(offer: nil, reasons: ["ContainerBitrateExceedsLimit"]) == .converting(.bitrate))
    }

    /// Playing the original would not get past a format this device lacks.
    @Test func aFormatReasonIsInformationEvenWithACap() {
        #expect(notice(reasons: ["ContainerBitrateExceedsLimit", "VideoCodecNotSupported"]) == .converting(.video))
        #expect(notice(reasons: ["AudioCodecNotSupported", "VideoRangeTypeNotSupported"]) == .converting(.video))
        #expect(notice(reasons: ["InterlacedVideoNotSupported"]) == .converting(.video))
        #expect(notice(reasons: ["ContainerNotSupported", "AudioChannelsNotSupported"]) == .converting(.audio))
        #expect(notice(reasons: ["SecondaryAudioNotSupported"]) == .converting(.audio))
        #expect(notice(reasons: ["SubtitleCodecNotSupported"]) == .converting(.subtitles))
        #expect(notice(reasons: ["DirectPlayError"]) == .converting(.other))
    }

    /// A container rewrite copies the picture and the sound.
    @Test func aRemuxSaysNothing() {
        #expect(notice(reasons: ["ContainerNotSupported"]) == nil)
        #expect(notice(delivery: .remux, reasons: []) == nil)
    }

    /// Only a failure reaches the re-encode rung, and its URL may carry no
    /// reason at all.
    @Test func theReencodeRungIsAPlaybackProblem() {
        #expect(notice(delivery: .transcode, reasons: []) == .converting(.playbackProblem))
        #expect(notice(delivery: .transcode, reasons: ["ContainerBitrateExceedsLimit"]) == .converting(.playbackProblem))
    }

    @Test func theOriginalAndADownloadSayNothing() {
        #expect(notice(method: .directPlay, reasons: ["ContainerBitrateExceedsLimit"]) == nil)
        #expect(notice(method: .directStream, reasons: ["VideoCodecNotSupported"]) == nil)
        #expect(notice(reasons: ["VideoCodecNotSupported"], isDownload: true) == nil)
    }

    @Test func theReasonsComeFromTheTranscodingURL() {
        let url = "/videos/cc8d15/master.m3u8?api_key=x&TranscodeReasons=VideoCodecNotSupported,AudioCodecNotSupported,VideoCodecNotSupported"
        #expect(PlaybackTranscodeNotice.reasons(in: url) == ["VideoCodecNotSupported", "AudioCodecNotSupported"])
        #expect(PlaybackTranscodeNotice.reasons(in: "/videos/x/master.m3u8") == [])
        #expect(PlaybackTranscodeNotice.reasons(in: nil) == [])
    }

    @Test func onlyAnOfferPlaysTheOriginalAndOnlyOnce() {
        let prompt = PlaybackTranscodeNoticePrompt()
        var played = 0
        prompt.onPlayOriginal = { played += 1 }
        #expect(!prompt.dismiss())

        prompt.present(.converting(.video))
        prompt.playOriginal()
        #expect(played == 0)
        #expect(prompt.isVisible)
        #expect(prompt.dismiss())
        #expect(!prompt.isVisible)

        prompt.present(.capped(.auto, probedBitsPerSecond: nil, maxBitrate: 10_000_000))
        prompt.playOriginal()
        prompt.playOriginal()
        #expect(played == 1)
        #expect(!prompt.isVisible)
    }

    /// Said once the attempt's picture is up, not when it is negotiated, and
    /// only once.
    @Test func aStagedNoticeWaitsForTheFirstFrame() {
        let prompt = PlaybackTranscodeNoticePrompt()
        prompt.stage(.converting(.audio))
        #expect(!prompt.isVisible)
        prompt.playbackStarted()
        #expect(prompt.notice == .converting(.audio))
        prompt.withdraw()
        prompt.playbackStarted()
        #expect(!prompt.isVisible)
        // An attempt with nothing to say clears what an earlier one staged.
        prompt.stage(.converting(.video))
        prompt.stage(nil)
        prompt.playbackStarted()
        #expect(!prompt.isVisible)
    }

    /// Playing the original holds for the item, until a new one or a lower
    /// quality chosen after it.
    @Test func theOriginalHoldsForTheItemOnly() {
        let prompt = PlaybackTranscodeNoticePrompt()
        prompt.present(.capped(.auto, probedBitsPerSecond: nil, maxBitrate: 10_000_000))
        prompt.playOriginal()
        #expect(prompt.playsOriginal)
        prompt.viewerChoseLowerQuality()
        #expect(!prompt.playsOriginal)

        prompt.present(.capped(.auto, probedBitsPerSecond: nil, maxBitrate: 10_000_000))
        prompt.playOriginal()
        prompt.stage(.converting(.video))
        prompt.itemChanged()
        #expect(!prompt.playsOriginal)
        prompt.playbackStarted()
        #expect(!prompt.isVisible)
    }

    @Test func anAttemptsNoticeReadsTheSourcesReasons() throws {
        let json = #"{"Id":"s","TranscodingUrl":"/videos/x/master.m3u8?TranscodeReasons=AudioCodecNotSupported"}"#
        let source = try JellyfinClient.decoder.decode(MediaSource.self, from: Data(json.utf8))
        let notice = PlaybackTranscodeNotice.notice(
            for: source, method: .transcode, delivery: .negotiated, offer: Self.auto,
            isDownload: false, isInGroup: false
        )
        #expect(notice == .converting(.audio))
    }

    /// The controller answers Play Original. With nothing playing there is
    /// nothing to restart, and the choice still holds for the item.
    @Test func theControllerAnswersPlayOriginal() async throws {
        let controller = PlaybackController()
        #expect(controller.transcodeNotice.onPlayOriginal != nil)
        controller.transcodeNotice.present(.capped(.auto, probedBitsPerSecond: nil, maxBitrate: 10_000_000))
        controller.transcodeNotice.playOriginal()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.transcodeNotice.playsOriginal)
        #expect(!controller.transcodeNotice.isVisible)
    }

    /// Under the metered cap too, so a metered Mac reads the same.
    @Test func playingTheOriginalLiftsEveryCap() async throws {
        let host = "original.test"
        StubURLProtocol.register(host: host) { _ in (200, [:], Data(#"{"MediaSources":[]}"#.utf8)) }
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "original-tests")
        let offer = try await client.negotiate(itemId: "film", maxBitrate: 2_000_000, playsOriginal: true).offer
        #expect(offer.cap == .none)
        #expect(offer.maxStreamingBitrate == DeviceProfile.lagoon.maxStreamingBitrate)
    }
}
