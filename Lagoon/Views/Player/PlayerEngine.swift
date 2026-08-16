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
