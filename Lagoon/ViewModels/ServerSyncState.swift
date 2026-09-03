import Foundation
import Observation

/// A top-level destination that can reconcile its own server-backed content.
/// The library id keeps two mounted Jellyfin libraries from sharing refresh
/// state merely because both happen to draw the same kind of grid.
nonisolated enum ServerSyncTarget: Hashable {
    case home
    case discover
    case library(String)

    var identifier: String {
        switch self {
        case .home: "home"
        case .discover: "discover"
        case .library(let id): "library.\(id)"
        }
    }
}

nonisolated enum ServerRefreshTrigger: String {
    case foreground
    case periodic
    case manual
}

/// Production refreshes use a quiet five-minute cadence. UI tests can shorten
/// it without changing the shipping behavior or waiting five real minutes.
nonisolated enum ServerRefreshPolicy {
    static let standardIntervalSeconds = 5 * 60.0

    static func intervalSeconds(defaults: UserDefaults = .standard) -> Double {
        #if DEBUG
        let override = defaults.double(forKey: "debug.serverSyncIntervalSeconds")
        if override > 0 { return override }
        #endif
        return standardIntervalSeconds
    }

    static func interval(defaults: UserDefaults = .standard) -> Duration {
        .seconds(intervalSeconds(defaults: defaults))
    }
}

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
    private(set) var activeTarget: ServerSyncTarget?
    private(set) var manualRefreshGeneration = 0
    private(set) var manualRefreshTarget: ServerSyncTarget?
    private var refreshingTargets: Set<ServerSyncTarget> = []

    #if DEBUG
    private(set) var refreshCounts: [String: Int] = [:]
    #endif

    func requestRefresh() {
        generation &+= 1
    }

    func activate(_ target: ServerSyncTarget) {
        activeTarget = target
    }

    func deactivate(_ target: ServerSyncTarget) {
        if activeTarget == target { activeTarget = nil }
    }

    func requestManualRefresh(for target: ServerSyncTarget) {
        guard activeTarget == target else { return }
        manualRefreshTarget = target
        manualRefreshGeneration &+= 1
    }

    func beginRefresh(_ target: ServerSyncTarget) {
        refreshingTargets.insert(target)
    }

    func endRefresh(_ target: ServerSyncTarget) {
        refreshingTargets.remove(target)
    }

    func isRefreshing(_ target: ServerSyncTarget) -> Bool {
        refreshingTargets.contains(target)
    }

    #if DEBUG
    func recordRefresh(_ target: ServerSyncTarget, trigger: ServerRefreshTrigger) {
        let key = "\(trigger.rawValue).\(target.identifier)"
        refreshCounts[key, default: 0] &+= 1
    }

    func refreshCount(_ target: ServerSyncTarget, trigger: ServerRefreshTrigger) -> Int {
        refreshCounts["\(trigger.rawValue).\(target.identifier)", default: 0]
    }
    #endif
}
