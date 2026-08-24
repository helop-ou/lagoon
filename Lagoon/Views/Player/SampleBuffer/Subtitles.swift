import CoreGraphics
import Foundation

// HEL-48 M5: subtitle model shared by the demuxed (embedded) and
// downloaded (Jellyfin external) paths. Cues render as a SwiftUI overlay
// in the player — nothing here touches the sample-buffer renderers.

/// One decoded bitmap (PGS/VobSub) with its position, normalized to the
/// subtitle plane so the overlay can scale it onto the displayed video.
nonisolated struct SubtitleImage: Equatable {
    let image: CGImage
    let rect: CGRect

    static func == (lhs: SubtitleImage, rhs: SubtitleImage) -> Bool {
        lhs.image === rhs.image && lhs.rect == rhs.rect
    }
}

nonisolated struct SubtitleCue {
    let start: Double
    /// `.infinity` marks an open-ended cue (the PGS norm: display until
    /// the next composition event) — the store closes it on the next event.
    var end: Double
    let text: String?
    let images: [SubtitleImage]
}

/// What one demuxed subtitle packet decodes to.
nonisolated enum SubtitleEvent {
    case cue(SubtitleCue)
    /// An empty composition (PGS clear screen): close open cues here.
    case clear(at: Double)
}

/// Thread-safe cue collection: the demux loop appends, the main-actor
/// display refresh reads. Small enough (a few thousand cues) that active
/// lookup is a plain scan.
nonisolated final class SubtitleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []

    func add(_ cue: SubtitleCue) {
        lock.lock()
        closeOpenCuesLocked(at: cue.start)
        cues.append(cue)
        lock.unlock()
    }

    func closeOpenCues(at seconds: Double) {
        lock.lock()
        closeOpenCuesLocked(at: seconds)
        lock.unlock()
    }

    func replaceAll(_ newCues: [SubtitleCue]) {
        lock.lock()
        cues = newCues
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        cues.removeAll()
        lock.unlock()
    }

    func active(at seconds: Double) -> (text: String?, images: [SubtitleImage]) {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        var images: [SubtitleImage] = []
        for cue in cues where cue.start <= seconds && seconds < cue.end {
            if let text = cue.text {
                lines.append(text)
            }
            images.append(contentsOf: cue.images)
        }
        return (lines.isEmpty ? nil : lines.joined(separator: "\n"), images)
    }

    private func closeOpenCuesLocked(at seconds: Double) {
        for index in cues.indices where cues[index].end == .infinity && cues[index].start < seconds {
            cues[index].end = seconds
        }
    }
}

/// Parses the external subtitle files Jellyfin delivers (vtt per the
/// device profile; srt tolerated since the timestamp shapes overlap).
nonisolated enum SubtitleParser {
    static func cues(from data: Data, languageHint: String? = nil) -> [SubtitleCue] {
        guard let content = SubtitleTextDecoder.text(from: data, languageHint: languageHint) else {
            return []
        }
        var result: [SubtitleCue] = []

        let blocks = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = seconds(fromTimestamp: timing[0]),
                  let end = seconds(fromTimestamp: timing[1]),
                  end > start else { continue }
            let text = lines[(timingIndex + 1)...]
                .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            result.append(SubtitleCue(start: start, end: end, text: text, images: []))
        }
        return result
    }

    /// "hh:mm:ss.mmm", "mm:ss.mmm", or the srt comma variant; vtt cue
    /// settings after the timestamp are ignored.
    private static func seconds(fromTimestamp raw: String) -> Double? {
        let stamp = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        let parts = stamp.replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Double = 0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Turns subtitle bytes into text without silently inventing them.
///
/// The previous chain ended in `isoLatin1`, which cannot fail — it maps every
/// byte — so a Windows-1251 Cyrillic file decoded to mojibake and rendered as
/// garbage with no error anywhere. Jellyfin converts to UTF-8 on its way out,
/// which hid this; a provider fetched directly does not (HEL-92).
///
/// The language is the strongest available signal for a legacy file, since a
/// codepage cannot be recovered from the bytes alone: a Cyrillic subtitle is
/// almost certainly Windows-1251 and a Baltic one Windows-1257. Every
/// candidate is still sanity-checked, so a wrong hint degrades to the next
/// option rather than to nonsense.
nonisolated enum SubtitleTextDecoder {
    static func text(from data: Data, languageHint: String? = nil) -> String? {
        guard !data.isEmpty else { return nil }
        if let viaBOM = decodeUsingBOM(data) { return viaBOM }
        // Valid UTF-8 is never accidental at any real length, so it wins
        // outright and needs no plausibility check.
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }

        var candidates: [String.Encoding] = []
        if let legacy = legacyEncoding(forLanguage: languageHint) {
            candidates.append(legacy)
        }
        candidates.append(contentsOf: [.windowsCP1252, .isoLatin1])

        var fallback: String?
        for encoding in candidates {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            if isPlausibleSubtitleText(decoded) { return decoded }
            if fallback == nil { fallback = decoded }
        }
        // Nothing looked like prose. Returning the first decodable form still
        // beats dropping the file: the caller validates that cues parsed out
        // of it, which is the check that actually protects playback.
        return fallback
    }

    private static func decodeUsingBOM(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// The single-byte codepage a subtitle in this language is written in when
    /// it is not UTF-8. Mapped from ISO 639 through Lagoon's existing
    /// normalisation so both two- and three-letter forms resolve.
    static func legacyEncoding(forLanguage language: String?) -> String.Encoding? {
        guard let language,
              let code = JellyfinSubtitleLanguageCode.twoLetter(for: language) else { return nil }
        switch code {
        case "ru", "uk", "bg", "be", "sr", "mk":
            return encoding(.windowsCyrillic)
        case "cs", "pl", "hu", "ro", "hr", "sk", "sl", "sq", "bs":
            return encoding(.windowsLatin2)
        case "el":
            return encoding(.windowsGreek)
        case "tr":
            return encoding(.windowsLatin5)
        case "he", "yi":
            return encoding(.windowsHebrew)
        case "ar", "fa", "ur":
            return encoding(.windowsArabic)
        case "et", "lv", "lt":
            return encoding(.windowsBalticRim)
        case "vi":
            return encoding(.windowsVietnamese)
        case "th":
            return encoding(.dosThai)
        default:
            return nil
        }
    }

    /// Only a handful of these have `String.Encoding` constants; going through
    /// CoreFoundation keeps the whole table in one shape.
    private static func encoding(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(value.rawValue)
        ))
    }

    /// Subtitle text is prose: letters, digits, punctuation and whitespace.
    /// A codepage applied to the wrong bytes produces a scatter of symbols and
    /// control characters instead, which this is enough to notice.
    static func isPlausibleSubtitleText(_ text: String) -> Bool {
        var plausible = 0
        var implausible = 0
        for scalar in text.unicodeScalars.prefix(4_000) {
            if scalar == "\u{FFFD}" {
                implausible += 1
            } else if CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                plausible += 1
            } else if CharacterSet.controlCharacters.contains(scalar) {
                implausible += 1
            } else {
                implausible += 1
            }
        }
        let total = plausible + implausible
        guard total > 0 else { return false }
        return Double(implausible) / Double(total) < 0.05
    }
}
