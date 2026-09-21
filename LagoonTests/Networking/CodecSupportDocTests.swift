import Foundation
import Testing
@testable import Lagoon

/// Renders `DeviceProfile.everything` as the published codec table.
///
/// Generated rather than written by hand. `docs/release.md` forbids
/// overstating supported formats, and a list maintained by hand drifts from
/// the profile the moment someone adds a codec. What gets published is by
/// construction the same envelope Lagoon sends Jellyfin in `PlaybackInfo`, so
/// the table cannot promise a direct play the server was never offered.
///
/// `scripts/generate-codec-support.sh` runs this and copies the result into
/// `docs/codec-support.md`. Its `--check` mode fails instead of copying, so
/// drift is caught rather than shipped.
@Suite("Codec support document")
struct CodecSupportDocTests {
    @Test func writesTheCodecSupportDocument() throws {
        let markdown = CodecSupportDocument.render(DeviceProfile.everything)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codec-support.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        // The script reads this line rather than guessing the sandbox path.
        print("CODEC_SUPPORT_DOC \(url.path)")
    }

    /// Guards the renderer, not the profile: a formatting change that quietly
    /// dropped a codec would otherwise publish a shorter table and pass.
    @Test func everyDeclaredVideoCodecReachesTheTable() throws {
        let markdown = CodecSupportDocument.render(DeviceProfile.everything)
        let declared = DeviceProfile.everything.directPlayProfiles
            .filter { $0.type == "Video" }
            .compactMap(\.videoCodec)
            .flatMap { $0.split(separator: ",") }
            .map(String.init)
        #expect(!declared.isEmpty)
        for codec in declared {
            #expect(markdown.contains(codec), "\(codec) missing from the generated table")
        }
    }
}

/// Turns the capability profile into the Markdown published as
/// `docs/codec-support.md`.
enum CodecSupportDocument {
    static func render(_ profile: DeviceProfile.Profile) -> String {
        var out = header()
        out += containers(profile)
        out += videoCodecs(profile)
        out += audioCodecs(profile)
        out += transcoding(profile)
        out += subtitles(profile)
        out += footer()
        return out
    }

    // MARK: - Sections

    private static func header() -> String {
        """
        # Codec support

        **Generated file. Do not edit.** Run `scripts/generate-codec-support.sh`
        after changing `DeviceProfile`.

        This is the capability profile Lagoon sends Jellyfin with every
        `PlaybackInfo` request. The server decides direct play against exactly
        this and nothing else, so what is listed here is what actually plays
        without a re-encode.

        Support is conditional, not a flat list. A codec appears below with the
        profiles, ranges and limits that go with it, because "everything direct
        plays" is never true and the conditions are where the real answer is.

        The reasoning behind each decision is in [Codec, timing and subtitle
        details](reference/playback/codecs-and-subtitles.md).


        """
    }

    private static func containers(_ profile: DeviceProfile.Profile) -> String {
        var out = "## Containers\n\n"
        for kind in ["Video", "Audio"] {
            let matching = profile.directPlayProfiles.filter { $0.type == kind }
            guard !matching.isEmpty else { continue }
            out += "**\(kind)** — "
            out += matching.map { entry in
                let containers = list(entry.container)
                if let audio = entry.audioCodec, kind == "Audio" {
                    return "\(containers) (\(list(audio)))"
                }
                return containers
            }.joined(separator: "; ")
            out += "\n\n"
        }
        return out
    }

    private static func videoCodecs(_ profile: DeviceProfile.Profile) -> String {
        codecTable(
            profile,
            type: "Video",
            title: "Video codecs",
            preamble: "",
            codecList: \.videoCodec
        )
    }

    private static func audioCodecs(_ profile: DeviceProfile.Profile) -> String {
        codecTable(
            profile,
            type: "Audio",
            title: "Audio tracks in a video file",
            preamble: """
            Some of these are passed through untouched and some Lagoon decodes
            itself before handing the result to the renderer. Either way the
            video is never re-encoded, which is what direct play means here.
            Which is which is in the reference note linked above.


            """,
            codecList: \.audioCodec
        )
    }

    private static func codecTable(
        _ profile: DeviceProfile.Profile,
        type: String,
        title: String,
        preamble: String,
        codecList: KeyPath<DeviceProfile.DirectPlayProfile, String?>
    ) -> String {
        let declared = profile.directPlayProfiles
            .filter { $0.type == "Video" }
            .compactMap { $0[keyPath: codecList] }
            .flatMap { $0.split(separator: ",").map(String.init) }
        guard !declared.isEmpty else { return "" }

        let rows = declared.map { codec in
            (codec, profile.codecProfiles
                .filter { $0.type == type && $0.codec == codec }
                .flatMap(\.conditions))
        }

        var out = "## \(title)\n\n"
        out += preamble
        // A table whose every row reads "no conditions" is worse than a list.
        guard rows.contains(where: { !$0.1.isEmpty }) else {
            out += rows.map { "`\($0.0)`" }.joined(separator: ", ")
            return out + "\n\n"
        }
        out += "| Codec | Conditions |\n| --- | --- |\n"
        for (codec, conditions) in rows {
            let text = conditions.isEmpty
                ? "None beyond the container"
                : conditions.map(describe).joined(separator: "; ")
            out += "| `\(codec)` | \(text) |\n"
        }
        return out + "\n"
    }

    private static func transcoding(_ profile: DeviceProfile.Profile) -> String {
        guard !profile.transcodingProfiles.isEmpty else { return "" }
        var out = """
        ## When direct play is not possible

        The server re-encodes and Lagoon plays the result. This is the only rung
        where the picture is not the original file.


        """
        for entry in profile.transcodingProfiles {
            out += "- **\(entry.type)** over `\(entry.protocol)` in `\(entry.container)` segments: "
            out += "video \(list(entry.videoCodec)), audio \(list(entry.audioCodec)), "
            out += "up to \(entry.maxAudioChannels) channels\n"
        }
        return out + "\n"
    }

    private static func subtitles(_ profile: DeviceProfile.Profile) -> String {
        guard !profile.subtitleProfiles.isEmpty else { return "" }
        var out = "## Subtitles\n\n"
        let byMethod = Dictionary(grouping: profile.subtitleProfiles, by: \.method)
        for method in byMethod.keys.sorted() {
            let formats = byMethod[method, default: []].map { "`\($0.format)`" }
            out += "- **\(methodName(method))** — \(formats.joined(separator: ", "))\n"
        }
        return out + "\n"
    }

    private static func footer() -> String {
        """
        ## Reading this table

        A codec listed here still needs its container listed too, and a stream
        that fails any condition is transcoded rather than refused. Conditions
        marked on the profile as not required pass when the server could not
        probe the property, which is why an unusual file sometimes direct plays
        where the table suggests it might not.

        Video level is the codec's own `level_idc` rather than the number people
        quote. Divide by 30 for HEVC, so `183` is level 6.1; divide by 10 for
        H.264, so `52` is level 5.2.

        """
    }

    // MARK: - Formatting

    private static func describe(_ condition: DeviceProfile.ProfileCondition) -> String {
        let property = spaced(condition.property)
        let values = list(condition.value, separator: "|")
        switch condition.condition {
        case "EqualsAny": return "\(property) one of \(values)"
        case "Equals": return "\(property) is \(values)"
        case "NotEquals": return "\(property) is not \(values)"
        case "LessThanEqual": return "\(property) at most \(values)"
        case "GreaterThanEqual": return "\(property) at least \(values)"
        case "LessThan": return "\(property) below \(values)"
        case "GreaterThan": return "\(property) above \(values)"
        default: return "\(property) \(condition.condition) \(values)"
        }
    }

    private static func list(_ value: String, separator: Character = ",") -> String {
        value.split(separator: separator)
            .map { "`\($0.trimmingCharacters(in: .whitespaces))`" }
            .joined(separator: ", ")
    }

    /// `VideoRangeType` reads as "Video range type" in a sentence.
    private static func spaced(_ property: String) -> String {
        var out = ""
        for (index, character) in property.enumerated() {
            if index > 0, character.isUppercase { out.append(" ") }
            out.append(index == 0 ? character : Character(character.lowercased()))
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    private static func methodName(_ method: String) -> String {
        switch method {
        case "Embed": return "Embedded in the file, decoded by Lagoon"
        case "External": return "Sidecar files"
        case "Hls": return "Delivered with an HLS transcode"
        default: return method
        }
    }
}
