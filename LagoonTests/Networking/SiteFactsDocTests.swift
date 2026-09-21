import Foundation
import Testing
@testable import Lagoon

/// Renders the facts the website states about the app, as JSON for it to read.
///
/// The website is a separate repository and restates what Lagoon plays. Copied
/// by hand, those claims go stale the moment `DeviceProfile` changes, and
/// `docs/release.md` forbids overstating format support because it is exactly
/// what a reviewer checks. Generating them means the site cannot claim a codec
/// the app never offers the server.
///
/// The version and build come from `Bundle.main`, which in an app-hosted test
/// is Lagoon.app, so they are what the project actually declares rather than
/// what somebody remembered to type into the site.
///
/// `scripts/generate-site-facts.sh` runs this and copies the result into the
/// website checkout. Its `--check` mode fails instead of copying.
@Suite("Site facts document")
struct SiteFactsDocTests {
    @Test @MainActor func writesTheSiteFactsDocument() throws {
        let json = try SiteFacts.render(
            DeviceProfile.everything,
            version: Changelog.version(),
            build: Changelog.build()
        )
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("app-facts.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        // The script reads this line rather than guessing the sandbox path.
        print("SITE_FACTS_DOC \(url.path)")
    }

    /// The point of the whole arrangement. Adding a codec to `DeviceProfile`
    /// without deciding what to call it in public fails here, rather than
    /// quietly dropping it from the site or printing a raw identifier at a
    /// reader.
    @Test func everyDeclaredIdentifierHasAPublicName() {
        let profile = DeviceProfile.everything
        for id in SiteFacts.declaredVideoCodecs(profile) {
            #expect(SiteFacts.videoNames[id] != nil, "No public name for video codec \(id)")
        }
        for id in SiteFacts.declaredAudioCodecs(profile) {
            #expect(SiteFacts.audioNames[id] != nil, "No public name for audio codec \(id)")
        }
        for id in SiteFacts.declaredSubtitleFormats(profile) {
            #expect(SiteFacts.subtitleNames[id] != nil, "No public name for subtitle format \(id)")
        }
        for id in SiteFacts.declaredVideoRanges(profile) {
            #expect(SiteFacts.rangeNames[id] != nil, "No public name for video range \(id)")
        }
    }

    @Test @MainActor func theDocumentCarriesTheDeclaredVersionAndBuild() throws {
        let json = try SiteFacts.render(
            DeviceProfile.everything,
            version: Changelog.version(),
            build: Changelog.build()
        )
        let parsed = try JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: String]
        let facts = try #require(parsed)
        #expect(facts["version"] == Changelog.version())
        #expect(facts["build"] == Changelog.build())
        for key in ["video", "hdr", "audio", "subtitles"] {
            let value = try #require(facts[key], "\(key) missing")
            #expect(!value.isEmpty)
        }
    }

    /// A row that lost its separator or came out empty would publish as a
    /// blank spec line rather than an obvious mistake.
    @Test func rowsAreSeparatedLists() throws {
        let json = try SiteFacts.render(DeviceProfile.everything, version: "1.0", build: "1")
        let facts = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        )
        for key in ["video", "hdr", "audio", "subtitles"] {
            let value = try #require(facts[key])
            #expect(value.contains(SiteFacts.separator), "\(key) is not a list: \(value)")
            #expect(!value.contains("  "), "\(key) has a doubled space")
        }
        // SDR is a range the profile accepts but not something to advertise.
        #expect(facts["hdr"]?.contains("SDR") == false)
    }
}

/// Turns `DeviceProfile` and the declared version into the JSON the website
/// reads as `src/lib/content/app-facts.json`.
enum SiteFacts {
    static let separator = " · "

    // MARK: - Public names
    //
    // What Lagoon calls each identifier in front of a reader. Editorial, and
    // deliberately here rather than in the website: the repository that
    // decides a codec is supported is the one that should decide what it is
    // called. A name missing from these maps fails the suite above.

    static let videoNames: [String: String] = [
        "hevc": "HEVC", "h264": "H.264", "av1": "AV1", "vp9": "VP9",
        "vc1": "VC-1", "wmv3": "WMV3", "mpeg4": "MPEG-4", "mpeg2video": "MPEG-2",
    ]

    static let audioNames: [String: String] = [
        "aac": "AAC", "mp3": "MP3", "mp2": "MP2", "ac3": "Dolby Digital",
        "eac3": "Dolby Digital Plus", "truehd": "TrueHD", "dts": "DTS",
        "flac": "FLAC", "alac": "ALAC", "opus": "Opus", "vorbis": "Vorbis",
        "pcm_s16le": "PCM", "pcm_s24le": "PCM", "pcm_s32le": "PCM",
        "pcm_f32le": "PCM", "pcm_f64le": "PCM", "pcm_s16be": "PCM",
        "pcm_s24be": "PCM", "pcm_s32be": "PCM", "pcm_f32be": "PCM",
        "pcm_f64be": "PCM", "pcm_bluray": "Blu-ray LPCM", "pcm_dvd": "DVD LPCM",
    ]

    static let subtitleNames: [String: String] = [
        "subrip": "Text", "srt": "Text", "ass": "Text", "ssa": "Text",
        "mov_text": "Text", "webvtt": "Text", "vtt": "Text",
        "pgs": "PGS", "pgssub": "PGS", "dvdsub": "VobSub", "dvbsub": "DVB",
    ]

    /// Dolby Vision arrives as a family of range types rather than a profile
    /// number, so the profile numbers a reader recognises are named here.
    /// `DOVIWithEL` is the dual-layer profile 7 converted in flight.
    static let rangeNames: [String: String] = [
        "SDR": "", // Accepted, never advertised.
        "HDR10": "HDR10",
        "HLG": "HLG",
        "HDR10Plus": "HDR10+",
        "DOVI": "Dolby Vision profile 5",
        "DOVIWithHDR10": "Dolby Vision profile 8",
        "DOVIWithHDR10Plus": "Dolby Vision profile 8",
        "DOVIWithHLG": "Dolby Vision profile 8",
        "DOVIWithSDR": "Dolby Vision profile 8",
        "DOVIWithEL": "Dolby Vision profile 7",
        "DOVIWithELHDR10Plus": "Dolby Vision profile 7",
    ]

    // MARK: - What the profile declares

    static func declaredVideoCodecs(_ profile: DeviceProfile.Profile) -> [String] {
        split(profile.directPlayProfiles.filter { $0.type == "Video" }.compactMap(\.videoCodec))
    }

    static func declaredAudioCodecs(_ profile: DeviceProfile.Profile) -> [String] {
        split(profile.directPlayProfiles.filter { $0.type == "Video" }.compactMap(\.audioCodec))
    }

    static func declaredSubtitleFormats(_ profile: DeviceProfile.Profile) -> [String] {
        ordered(profile.subtitleProfiles.map(\.format))
    }

    static func declaredVideoRanges(_ profile: DeviceProfile.Profile) -> [String] {
        let values = profile.codecProfiles
            .flatMap(\.conditions)
            .filter { $0.property == "VideoRangeType" }
            .map(\.value)
        return ordered(values.flatMap { $0.split(separator: "|").map(String.init) })
    }

    // MARK: - Rendering

    static func render(
        _ profile: DeviceProfile.Profile,
        version: String,
        build: String
    ) throws -> String {
        let facts: [String: String] = [
            "//": "Generated by the Lagoon app repository. Do not edit. "
                + "Run scripts/generate-site-facts.sh there.",
            "version": version,
            "build": build,
            "video": names(declaredVideoCodecs(profile), videoNames)
                .joined(separator: separator),
            "hdr": collapse(
                names(declaredVideoRanges(profile), rangeNames),
                matching: { $0.hasPrefix(dolbyVision) },
                into: dolbyVisionPhrase
            ).joined(separator: separator),
            "audio": collapse(
                names(declaredAudioCodecs(profile), audioNames),
                matching: { $0 == "PCM" || $0.hasSuffix("LPCM") },
                into: { _ in "PCM incl. Blu-ray and DVD LPCM" }
            ).joined(separator: separator),
            "subtitles": (names(declaredSubtitleFormats(profile), subtitleNames)
                + ["external files"]).joined(separator: separator),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: facts,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static let dolbyVision = "Dolby Vision profile "

    /// Names in the order the profile declares them, with duplicates dropped:
    /// several PCM identifiers are all just "PCM" to a reader, and four range
    /// types are all profile 8.
    private static func names(_ ids: [String], _ map: [String: String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids {
            guard let name = map[id], !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// Folds a family of names into one phrase, in place of the first of them.
    /// A row reading "Dolby Vision profile 5 · Dolby Vision profile 8 · Dolby
    /// Vision profile 7" is accurate and unreadable; three profiles of one
    /// thing belong in one entry.
    private static func collapse(
        _ list: [String],
        matching isMember: (String) -> Bool,
        into phrase: ([String]) -> String
    ) -> [String] {
        let members = list.filter(isMember)
        guard members.count > 1 else { return list }
        var out: [String] = []
        for name in list where !isMember(name) || name == members[0] {
            out.append(name == members[0] ? phrase(members) : name)
        }
        return out
    }

    /// "Dolby Vision profiles 5, 8 and 7", keeping the profile order the
    /// device profile declares rather than sorting it.
    private static func dolbyVisionPhrase(_ members: [String]) -> String {
        let numbers = members.map { $0.replacingOccurrences(of: dolbyVision, with: "") }
        guard let last = numbers.last else { return "" }
        let leading = numbers.dropLast().joined(separator: ", ")
        return "Dolby Vision profiles \(leading) and \(last)"
    }

    private static func split(_ values: [String]) -> [String] {
        ordered(values.flatMap { $0.split(separator: ",").map(String.init) })
    }

    /// First-seen order, so the rendered row follows the profile rather than
    /// an alphabet, and a reordering in `DeviceProfile` shows up as a diff.
    private static func ordered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
