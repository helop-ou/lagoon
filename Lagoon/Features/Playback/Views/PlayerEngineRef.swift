import CoreGraphics
import Foundation
import Observation

/// A player view's handle on the engine: weak on purpose.
///
/// `PlaybackController` owns the engine for exactly as long as the item plays
/// and replaces it at every episode handoff. The chrome over it is SwiftUI
/// views, and SwiftUI copies a view struct — every stored property with it —
/// into the closure contexts it keeps for gestures. The copy the surface's
/// Select gesture kept from before a handoff stayed alive beside the refreshed
/// one for as long as the player was up (`leaks --traceTree` named the
/// `AddGestureModifier` callback context; a later Select drove the new engine
/// and still did not release the old one), so with a strong `let engine`
/// every episode boundary leaked one drained `SampleBufferPlayerEngine` until
/// the player was dismissed.
///
/// So no player view holds the engine strongly. Declare the field as
/// `@PlayerEngineRef var engine: any PlayerEngine`: the memberwise initializer
/// still takes the engine itself, every read still goes to the live object
/// while its owner has it, and Observation still tracks the properties read.
/// A copy that outlives the engine reads `DetachedPlayerEngine` instead — a
/// stand-in that reports nothing playing and does nothing — rather than
/// crashing; the refreshed copy is the one whose closures run.
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
