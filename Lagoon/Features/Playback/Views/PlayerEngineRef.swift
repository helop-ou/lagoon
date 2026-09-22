import CoreGraphics
import Foundation
import LagoonEngine
import Observation

/// A player view's handle on the engine: weak on purpose.
///
/// SwiftUI keeps copies of view structs in gesture closure contexts past an
/// episode handoff, so a strong `let engine` leaks one drained engine per
/// episode. Player views must declare
/// `@PlayerEngineRef var engine: any PlayerEngine`, never a strong reference.
/// A copy that outlives the engine reads `DetachedPlayerEngine`.
@propertyWrapper
struct PlayerEngineRef {
    private weak var engine: (any PlayerEngine)?

    init(wrappedValue: any PlayerEngine) {
        engine = wrappedValue
    }

    var wrappedValue: any PlayerEngine {
        engine ?? DetachedPlayerEngine.shared
    }

    /// Whether the owner still has the engine. Only a test needs to ask.
    var isAttached: Bool { engine != nil }
}

/// What a player view sees once its engine is gone: every control a no-op.
@Observable
final class DetachedPlayerEngine: PlayerEngine {
    static let shared = DetachedPlayerEngine()

    private init() {}

    var timePosition: Double { 0 }
    var duration: Double { 0 }
    var isPaused: Bool { true }
    var isBuffering: Bool { false }
    var rate: Double { 1 }
    var stallCount: Int { 0 }
    var videoSize: CGSize? { nil }
    var audioTracks: [PlayerTrack] { [] }
    var subtitleTracks: [PlayerTrack] { [] }
    var currentSubtitleText: String? { nil }
    var currentSubtitleImages: [SubtitleImage] { [] }
    var audioDelay: Double { 0 }
    var displayMatchRequest: DisplayMatchRequest? { nil }

    func play() {}
    func pause() {}
    func togglePause() {}
    func setRate(_ rate: Double) {}
    func seek(by seconds: Double) {}
    func seek(to seconds: Double) {}
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {}
    func setAudioDelay(_ seconds: Double) {}
}
