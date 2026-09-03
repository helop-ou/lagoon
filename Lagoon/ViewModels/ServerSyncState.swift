import Observation

/// One app-wide invalidation clock for content read from Jellyfin.
///
/// SwiftUI keeps the tab and navigation trees mounted while the app is in the
/// background, so their ordinary `task` and `onAppear` work does not run again
/// when the scene becomes active. RootView advances this clock at that
/// boundary; visible server-backed screens observe it and reconcile their own
/// state without the root needing to know what they have loaded (HEL-135).
@Observable
final class ServerSyncState {
    private(set) var generation = 0

    func requestRefresh() {
        generation &+= 1
    }
}
