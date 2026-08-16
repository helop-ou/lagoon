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
    var audioTracks: [PlayerTrack] { get }
    var subtitleTracks: [PlayerTrack] { get }

    func togglePause()
    func seek(by seconds: Double)
    /// nil turns the stream off (subtitles); audio pickers shouldn't pass nil.
    func selectAudioTrack(id: Int?)
    func selectSubtitleTrack(id: Int?)
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

/// A subtitle that lives outside the media file (Jellyfin external stream)
/// for the engine to side-load at start.
nonisolated struct ExternalSubtitleTrack {
    let url: URL
    let title: String?
    let language: String?
    /// Jellyfin's default-subtitle choice pointed at this external stream.
    let select: Bool
}
