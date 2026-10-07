import Foundation

/// Transport requests routed to a SyncPlay group instead of the local engine.
///
/// A request does nothing locally: the group's answering command is what
/// moves this player.
@MainActor
protocol GroupTransportRequests: AnyObject {
    func requestPlay()
    func requestPause()
    /// `resume` means seek and then play, so the implementation can order
    /// the two requests.
    func requestSeek(to seconds: Double, resume: Bool)
    func requestNextItem()
}
