import Foundation
import Testing
@testable import Lagoon

/// One owner for "which streams are video, audio or subtitles", shared by the
/// detail page, Top Shelf, diagnostics and subtitle search.
@Suite("MediaSource stream helpers")
struct MediaSourceStreamsTests {
    private func stream(
        _ type: String,
        codec: String,
        isDefault: Bool = false,
        profile: String? = nil
    ) -> [String: Any] {
        var json: [String: Any] = ["Type": type, "Codec": codec, "IsDefault": isDefault]
        json["Profile"] = profile
        return json
    }

    private func source(streams: [[String: Any]]?) throws -> MediaSource {
        var json: [String: Any] = ["Id": "src"]
        json["MediaStreams"] = streams
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JellyfinClient.decoder.decode(MediaSource.self, from: data)
    }

    @Test("kind predicates match the type string exactly")
    func kindPredicates() throws {
        let src = try source(streams: [
            stream("Video", codec: "hevc"),
            stream("Audio", codec: "eac3", profile: "Dolby Digital Plus + Dolby Atmos"),
            stream("Subtitle", codec: "srt"),
            stream("video", codec: "h264"),
        ])
        let streams = try #require(src.mediaStreams)
        #expect(streams[0].isVideo && !streams[0].isAudio && !streams[0].isSubtitle)
        #expect(streams[1].isAudio && !streams[1].isVideo)
        #expect(streams[2].isSubtitle && !streams[2].isAudio)
        #expect(!streams[3].isVideo)
        #expect(streams[1].hasAtmos)
        #expect(!streams[0].hasAtmos)
    }

    @Test("videoStream is the first video stream")
    func firstVideo() throws {
        let src = try source(streams: [
            stream("Audio", codec: "aac"),
            stream("Video", codec: "hevc"),
            stream("Video", codec: "h264"),
        ])
        #expect(src.videoStream?.codec == "hevc")
        #expect(src.audioStreams.count == 1)
        #expect(src.subtitleStreams.isEmpty)
    }

    @Test("defaultAudioStream prefers the default flag, then the first")
    func defaultAudio() throws {
        let flagged = try source(streams: [
            stream("Audio", codec: "aac"),
            stream("Audio", codec: "eac3", isDefault: true),
        ])
        #expect(flagged.defaultAudioStream?.codec == "eac3")

        let unflagged = try source(streams: [
            stream("Audio", codec: "aac"),
            stream("Audio", codec: "eac3"),
        ])
        #expect(unflagged.defaultAudioStream?.codec == "aac")
    }

    @Test("missing streams yield empty results")
    func noStreams() throws {
        let src = try source(streams: nil)
        #expect(src.videoStream == nil)
        #expect(src.audioStreams.isEmpty)
        #expect(src.subtitleStreams.isEmpty)
        #expect(src.defaultAudioStream == nil)
    }
}
