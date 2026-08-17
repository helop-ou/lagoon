import Foundation
import Observation

/// What the custom player UI is allowed to know about a playback engine.
///
/// HEL-48 decided the end state is one custom player over a sample-buffer
/// engine; until that exists the mpv engine (HEL-45) implements this. The
/// transport/track UI must only ever talk to this protocol so the engine
/// swap doesn't touch it.
@MainActor
protocol PlayerEngine: AnyObject, Observable {
    var timePosition: Double { get }
    var duration: Double { get }
    var isPaused: Bool { get }
    var isBuffering: Bool { get }
    var videoSize: CGSize? { get }
    var audioTracks: [PlayerTrack] { get }
    var subtitleTracks: [PlayerTrack] { get }
    /// The subtitle content on screen right now (M5): joined text lines
    /// and/or decoded bitmap rects, rendered by the player UI as an
    /// overlay. Empty/nil when no cue is active.
    var currentSubtitleText: String? { get }
    var currentSubtitleImages: [SubtitleImage] { get }
    /// mpv convention (M6): positive delays the audio relative to video.
    var audioDelay: Double { get }

    func togglePause()
    func seek(by seconds: Double)
    /// Absolute seek, clamped by the engine. Both seeks are optimistic:
    /// `timePosition` lands on the target the instant they're called, so
    /// the transport can commit a scrub without waiting for the demuxer.
    func seek(to seconds: Double)
    /// nil turns the stream off (subtitles); audio pickers shouldn't pass nil.
    func selectAudioTrack(id: Int?)
    func selectSubtitleTrack(id: Int?)
    func setAudioDelay(_ seconds: Double)
}

/// One selectable track as the engine reports it. `engineID` is the
/// engine's own identifier (mpv aid/sid today), unique per kind only.
nonisolated struct PlayerTrack: Identifiable, Equatable {
    enum Kind: String {
        case audio
        case subtitle
    }

    let engineID: Int
    let kind: Kind
    let displayName: String
    let isSelected: Bool

    var id: String { "\(kind.rawValue)-\(engineID)" }
}

/// A chapter mark on the transport (HEL-39 slice 3).
nonisolated struct PlayerChapter: Identifiable, Equatable {
    /// Position in the chapter list, which is also its display number.
    let id: Int
    let name: String?
    let start: Double
}

/// Everything the transport needs to pull trickplay preview frames: the
/// sheet URLs already resolved (tokens included), plus the grid inside each
/// sheet. Positions map to tiles through `tile(at:)`.
nonisolated struct TrickplaySource: Equatable {
    let sheetURLs: [URL]
    /// One thumbnail's pixel size as the server declared it.
    let tileSize: CGSize
    let columns: Int
    let rows: Int
    /// Seconds between thumbnails (the wire value is milliseconds).
    let interval: Double
    let thumbnailCount: Int

    var tilesPerSheet: Int { columns * rows }

    /// Which sheet and cell a position lands in, or nil if it falls outside
    /// what the server generated.
    func tile(at seconds: Double) -> TrickplayTile? {
        guard interval > 0, tilesPerSheet > 0, thumbnailCount > 0 else { return nil }
        let index = min(max(Int(seconds / interval), 0), thumbnailCount - 1)
        let sheet = index / tilesPerSheet
        guard sheetURLs.indices.contains(sheet) else { return nil }
        let cell = index % tilesPerSheet
        return TrickplayTile(sheet: sheet, column: cell % columns, row: cell / columns)
    }
}

nonisolated struct TrickplayTile: Equatable {
    let sheet: Int
    let column: Int
    let row: Int
}

/// Everything the player's Info tab and transport show about the item —
/// assembled by the playback controller, engine-independent.
nonisolated struct PlayerItemInfo {
    /// Transport headline: the series for episodes, the item otherwise.
    let title: String
    /// Small line above the headline, e.g. "S1 E1 · Freedom Day".
    let subtitle: String?
    let overview: String?
    /// Infuse-style spaced tokens: runtime, year, size, "HEVC (4K DV)",
    /// "Dolby Digital+ 5.1", bitrate, fps, genres, rating.
    let facts: [String]
    /// The Video tab's single read-only line, e.g.
    /// "HEVC · 4K DV · 3840×1600 · 23.976 fps".
    let videoSummary: String?
    let posterURL: URL?
    /// Empty whenever the server has no chapters for the item — the ticks
    /// and chapter jumps simply don't appear (HEL-39 slice 3).
    var chapters: [PlayerChapter] = []
    /// nil when the server hasn't generated trickplay tiles; the scrub chip
    /// then shows the timestamp alone.
    var trickplay: TrickplaySource?
}

/// A subtitle that lives outside the media file (Jellyfin external stream)
/// for the engine to side-load at start.
nonisolated struct ExternalSubtitleTrack {
    let url: URL
    let title: String?
    let language: String?
    /// Jellyfin's default-subtitle choice pointed at this external stream.
    let select: Bool
}
