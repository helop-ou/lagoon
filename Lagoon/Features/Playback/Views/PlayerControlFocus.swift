import Foundation

/// Shares the player's focus namespace so focus returns to the surface
/// without a dead frame.
enum PlayerControlFocus: Hashable {
    case surface
    case tab(PlayerPanelTab)
    case track(String)
}
