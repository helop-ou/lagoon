import Foundation

/// What the Together tab draws. A value, not the store, so the panel host's
/// `Equatable` boundary can compare it.
nonisolated struct PlayerTogetherState: Equatable, Sendable {
    let groupName: String
    let participants: [String]
    let state: SyncPlayGroupState
    /// This member no longer holds the group up when behind.
    let ignoresWait: Bool

    var stateTitle: String { SyncPlayStateCopy.title(for: state) }
}
