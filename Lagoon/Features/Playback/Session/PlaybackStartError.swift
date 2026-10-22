import Foundation

nonisolated enum PlaybackStartError: LocalizedError {
    case previousEngineDidNotRetire
    case stalled

    var errorDescription: String? {
        switch self {
        case .previousEngineDidNotRetire:
            "The previous video could not release its player resources. Close the player and try again."
        case .stalled:
            "The video stopped loading before it could start. Close the player and try again."
        }
    }
}
