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
    static func cues(from data: Data) -> [SubtitleCue] {
        guard let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return [] }
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
