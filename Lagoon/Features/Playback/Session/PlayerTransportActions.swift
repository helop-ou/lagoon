import Foundation

/// The transport actions the player chrome can request.
///
/// Closures rather than a controller reference keep the engine out of
/// anything SwiftUI retains.
struct PlayerTransportActions {
    /// Idempotent: system integrations state the wanted state, not a toggle.
    let play: () -> Void
    let pause: () -> Void
    let togglePause: () -> Void
    let seek: (_ seconds: Double, _ resume: Bool) -> Void
    let seekBy: (_ seconds: Double) -> Void
}
