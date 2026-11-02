import Foundation
import Testing
@testable import Lagoon

/// A transcode report says whether a cap chose it: what was offered, what
/// bounded the offer, what Auto measured, and the server's reasons.
@MainActor
@Suite("Playback offer diagnostics")
struct PlaybackOfferDiagnosticsTests {
    @Test func theLowestBoundNamesTheCap() {
        // Auto on a slow remote link.
        #expect(PlaybackOffer.cap(lowered: false, setting: .auto, ceiling: 3_500_000, metered: false) == .auto)
        // A server on this network, or No Limit.
        #expect(PlaybackOffer.cap(lowered: false, setting: .auto, ceiling: nil, metered: false) == .none)
        #expect(PlaybackOffer.cap(lowered: false, setting: .unlimited, ceiling: nil, metered: false) == .none)
        #expect(PlaybackOffer.cap(lowered: false, setting: .mbps8, ceiling: 8_000_000, metered: false) == .setting)
        #expect(PlaybackOffer.cap(lowered: true, setting: .auto, ceiling: 4_000_000, metered: false) == .lowered)
        // Cellular wins over a higher ceiling, and loses to a lower one.
        #expect(PlaybackOffer.cap(lowered: false, setting: .auto, ceiling: nil, metered: true) == .metered)
        #expect(PlaybackOffer.cap(lowered: false, setting: .mbps8, ceiling: 8_000_000, metered: true) == .metered)
        #expect(PlaybackOffer.cap(lowered: false, setting: .mbps2, ceiling: 2_000_000, metered: true) == .setting)
    }

    @Test func onlyJellyfinsReasonNamesLeaveTheURL() {
        let url = "/videos/cc8d15/master.m3u8?DeviceId=abc&api_key=secret-token&MediaSourceId=cc8d15"
            + "&TranscodeReasons=VideoCodecNotSupported,SomethingNew,ContainerBitrateExceedsLimit,VideoCodecNotSupported"
        #expect(PlaybackIncidentMonitor.transcodeReasons(url) == "VideoCodecNotSupported,ContainerBitrateExceedsLimit")
        #expect(PlaybackIncidentMonitor.transcodeReasons("/videos/cc8d15/master.m3u8?api_key=secret-token") == nil)
        #expect(PlaybackIncidentMonitor.transcodeReasons("/videos/x/master.m3u8?TranscodeReasons=secret-token") == nil)
        #expect(PlaybackIncidentMonitor.transcodeReasons(nil) == nil)
    }

    @Test func theSchemaTakesAListOfKnownReasonsOnly() {
        let kind = DiagnosticSchema.fields["transcodeReasons"]
        #expect(kind == .choiceList(DiagnosticSchema.transcodeReasonChoices))
        func accepts(_ text: String) -> Bool {
            DiagnosticSchema.accepts(.choiceList(DiagnosticSchema.transcodeReasonChoices), .string(text))
        }
        #expect(accepts("DirectPlayError"))
        #expect(accepts("VideoCodecNotSupported,ContainerBitrateExceedsLimit"))
        #expect(!accepts(""))
        #expect(!accepts("DirectPlayError,"))
        #expect(!accepts("DirectPlayError,DirectPlayError"))
        #expect(!accepts("DirectPlayError,jellyfin.example.eu"))
    }

    /// Under the metered cap, so a metered Mac reads the same.
    @Test func negotiationReportsALoweredQuality() async throws {
        let host = "offer.test"
        StubURLProtocol.register(host: host) { _ in (200, [:], Data(#"{"MediaSources":[]}"#.utf8)) }
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "offer-tests")
        let offer = try await client.negotiate(itemId: "film", maxBitrate: 2_000_000).offer
        #expect(offer == PlaybackOffer(maxStreamingBitrate: 2_000_000, cap: .lowered, probedBitsPerSecond: nil))
    }

    @Test func everyIncidentOfTheAttemptCarriesTheOffer() throws {
        let sink = PlaybackIncidentMonitorTests.CapturingSink()
        let hub = DiagnosticsHub(sink: sink, reportingEnabled: { true })
        let monitor = PlaybackIncidentMonitor(hub: hub)
        let source = try JellyfinClient.decoder.decode(MediaSource.self, from: Data(#"""
        {"Id":"cc8d15","Container":"mkv","Bitrate":3100746,
         "TranscodingUrl":"/videos/cc8d15/master.m3u8?api_key=secret-token&TranscodeReasons=VideoResolutionNotSupported",
         "MediaStreams":[{"Type":"Video","Codec":"hevc","Width":1920,"Height":1080}]}
        """#.utf8))
        monitor.beginAttempt(
            delivery: .negotiated, method: .transcode, source: source, cached: false, disc: false, resumeSeconds: 0,
            offer: PlaybackOffer(maxStreamingBitrate: 3_500_000, cap: .auto, probedBitsPerSecond: 5_000_000)
        )
        _ = hub.report(.playbackStall, level: .warning, fields: ["stallCause": .string("video")])
        let stall = try #require(sink.incidents.first)
        #expect(stall.fields["offeredBitrate"] == .int(3_500_000))
        #expect(stall.fields["cap"] == .string("auto"))
        #expect(stall.fields["probedBitrate"] == .int(5_000_000))
        #expect(stall.fields["transcodeReasons"] == .string("VideoResolutionNotSupported"))
        #expect(stall.fields["schemaRejected"] == nil)
    }
}
