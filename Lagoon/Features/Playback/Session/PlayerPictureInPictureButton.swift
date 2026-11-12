import SwiftUI

/// The Picture in Picture button in the player itself. Nil hides it: a
/// disabled button in the tvOS row could not take focus anyway.
nonisolated enum PlayerPictureInPictureButton: Equatable {
    case start
    case stop

    static func state(isPossible: Bool, isActive: Bool, isAvailable: Bool) -> PlayerPictureInPictureButton? {
        guard isAvailable else { return nil }
        if isActive { return .stop }
        return isPossible ? .start : nil
    }

    var title: LocalizedStringKey {
        switch self {
        case .start: "Picture in Picture"
        case .stop: "Stop Picture in Picture"
        }
    }

    var systemImage: String {
        switch self {
        case .start: "pip.enter"
        case .stop: "pip.exit"
        }
    }
}
