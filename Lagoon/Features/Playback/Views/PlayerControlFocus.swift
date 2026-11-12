import Foundation

/// Shares the player's focus namespace so focus returns to the surface
/// without a dead frame.
enum PlayerControlFocus: Hashable {
    case surface
    case tab(PlayerPanelTab)
    case track(String)
    /// A SwiftUI button in the tvOS row above the scrubber. Its UIKit menu
    /// buttons report through `PlayerRowMenus` instead.
    case control(String)

    /// Focus has left the surface for the row's own controls.
    var isTransportControl: Bool {
        if case .control = self { return true }
        return false
    }
}
