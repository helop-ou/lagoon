import Foundation
import Testing
@testable import Lagoon

@Suite("Media quality tokens")
struct MediaQualityTests {
    private func source(streams: [[String: Any]]) throws -> MediaSource {
        let data = try JSONSerialization.data(withJSONObject: ["Id": "src", "MediaStreams": streams])
        return try JellyfinClient.decoder.decode(MediaSource.self, from: data)
    }

    private func video(width: Int, range: String? = nil) -> [String: Any] {
        var json: [String: Any] = ["Type": "Video", "Codec": "hevc", "Width": width]
        json["VideoRangeType"] = range
        return json
    }

    private func audio(
        _ codec: String,
        channels: Int,
        profile: String? = nil,
        default isDefault: Bool = false
    ) -> [String: Any] {
        var json: [String: Any] = [
            "Type": "Audio", "Codec": codec, "Channels": channels, "IsDefault": isDefault,
        ]
        json["Profile"] = profile
        return json
    }

    @Test func aFileNamesItsBestResolutionRangeAndAudio() throws {
        let src = try source(streams: [
            video(width: 3840, range: "DOVIWithHDR10"),
            audio("ac3", channels: 6, default: true),
            audio("truehd", channels: 8, profile: "Dolby TrueHD + Dolby Atmos"),
        ])
        #expect(src.qualityTokens == ["4K", "DV", "TrueHD 7.1", "Atmos"])
    }

    @Test func resolutionClassesChangeAtTheirExactWidths() {
        #expect(MediaQuality.resolutionClass(width: 3200) == "4K")
        #expect(MediaQuality.resolutionClass(width: 3199) == "1080p")
        #expect(MediaQuality.resolutionClass(width: 1800) == "1080p")
        #expect(MediaQuality.resolutionClass(width: 1799) == "720p")
        #expect(MediaQuality.resolutionClass(width: 1200) == "720p")
        #expect(MediaQuality.resolutionClass(width: 1199) == "SD")
    }

    @Test func rangesAreLabelledCompactlyAndSDRIsOmitted() throws {
        #expect(MediaQuality.rangeLabel("DOVIWithHDR10") == "DV")
        #expect(MediaQuality.rangeLabel("DOVI") == "DV")
        #expect(MediaQuality.rangeLabel("HDR10Plus") == "HDR10+")
        #expect(MediaQuality.rangeLabel("HDR10") == "HDR10")

        let plus = try source(streams: [video(width: 1920, range: "HDR10Plus")])
        #expect(plus.qualityTokens == ["1080p", "HDR10+"])
        let sdr = try source(streams: [video(width: 1920, range: "SDR")])
        #expect(sdr.qualityTokens == ["1080p"])
    }

    @Test func losslessAudioOutranksMoreChannelsOfALossyCodec() throws {
        let src = try source(streams: [
            audio("eac3", channels: 8),
            audio("truehd", channels: 6),
        ])
        #expect(src.qualityTokens == ["TrueHD 5.1"])
    }

    @Test func aFileWithoutStreamsHasNoTokens() throws {
        #expect(try source(streams: []).qualityTokens.isEmpty)
    }
}
