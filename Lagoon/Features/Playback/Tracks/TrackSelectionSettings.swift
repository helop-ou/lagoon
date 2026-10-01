import Foundation

/// The viewer's settings that automatic track selection reads, resolved once
/// when the player opens and reused by every restart in that session: an
/// episode hand-off, a group item change, a delivery fallback.
nonisolated struct TrackSelectionSettings: Equatable {
    var audioMode: AudioDefaultMode = .serverDefault
    var subtitleMode: SubtitleDefaultMode = .system
    /// Never empty once resolved: the system languages stand in for an
    /// empty list.
    var preferredAudioLanguages: [String] = []
    var preferredSubtitleLanguages: [String] = []
}
