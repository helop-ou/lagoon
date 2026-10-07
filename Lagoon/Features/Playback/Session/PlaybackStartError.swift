import Foundation

nonisolated enum PlaybackStartError: LocalizedError {
    case previousEngineDidNotRetire

    var errorDescription: String? {
        switch self {
        case .previousEngineDidNotRetire:
            "The previous video could not release its player resources. Close the player and try again."
        }
    }
}
