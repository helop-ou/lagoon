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

    /// The row above the scrubber or its sound list: focus has left the
    /// surface for the transport's own controls.
    var isTransportControl: Bool {
        switch self {
        case .control, .sound: true
        default: false
        }
    }
}
