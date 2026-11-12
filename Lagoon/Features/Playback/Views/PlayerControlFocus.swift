import Foundation

/// Shares the player's focus namespace so focus returns to the surface
/// without a dead frame.
enum PlayerControlFocus: Hashable {
    case surface
    case tab(PlayerPanelTab)
    case track(String)
    /// A button in the tvOS row above the scrubber.
    case control(String)
    /// A row in the tvOS sound list above that row.
    case sound(String)
    /// A row in the tvOS Episodes list, by its place in the list.
    case episode(Int)

    /// The row above the scrubber or a list above it: focus has left the
    /// surface for the transport's own controls.
    var isTransportControl: Bool {
        switch self {
        case .control, .sound, .episode: true
        default: false
        }
    }
}
