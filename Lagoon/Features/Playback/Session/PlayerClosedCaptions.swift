import LagoonEngine

/// Picks the video's closed captions once the engine lists them, for a
/// viewer who chose them for the show or whose settings ask for subtitles
/// on a title with no other track.
///
/// The engine finds captions only when the first one is read, which can be
/// minutes in, so they cannot be selected at the start like a subtitle
/// track. A viewer who changes subtitles in the meantime has answered, and
/// is left alone.
@MainActor
final class PlayerClosedCaptions {
    private weak var engine: (any PlayerEngine)?
    private var isWaiting = false
    /// The subtitle selection the title started on, once it is known.
    private var startingSelection: Int??

    func attach(_ engine: any PlayerEngine, wanted: Bool) {
        self.engine = engine
        isWaiting = wanted
        startingSelection = nil
    }

    /// Called as the playhead advances.
    func check() {
        guard isWaiting, let engine else { return }
        let tracks = engine.subtitleTracks
        let selected = tracks.first(where: \.isSelected)?.engineID
        guard let startingSelection else {
            self.startingSelection = .some(selected)
            return check()
        }
        guard selected == startingSelection else {
            isWaiting = false
            return
        }
        guard tracks.contains(where: { $0.engineID == PlayerTrack.closedCaptionsEngineID }) else { return }
        isWaiting = false
        engine.selectSubtitleTrack(id: PlayerTrack.closedCaptionsEngineID)
    }
}
