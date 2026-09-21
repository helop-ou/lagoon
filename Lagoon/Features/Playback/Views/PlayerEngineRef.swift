import CoreGraphics
import Foundation
import Observation

/// A player view's handle on the engine: weak on purpose.
///
/// SwiftUI copies a view struct, stored properties and all, into the closure
/// contexts it keeps for gestures. The copy a gesture kept from before an
/// episode handoff stays alive beside the refreshed one for as long as the
/// player is up (`leaks --traceTree` named the `AddGestureModifier` context),
/// so a strong `let engine` leaked one drained engine per episode boundary.
///
/// Declare `@PlayerEngineRef var engine: any PlayerEngine`: the memberwise
/// init still takes the engine, reads still reach the live object, Observation
/// still tracks them. A copy that outlives it reads `DetachedPlayerEngine`
/// rather than crashing.
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

/// What a player view talks to once its engine is gone: nothing playing,
/// nothing to select, every control a no-op. Exists so `PlayerEngineRef`
/// can hand out a non-optional engine without extending the real one's life.
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
