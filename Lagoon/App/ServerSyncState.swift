import Foundation
import Observation

/// A top-level destination that reconciles its own server-backed content.
/// The library id keeps two libraries from sharing refresh state.
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

/// Five minutes; debug builds let UI tests shorten it.
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

/// One app-wide invalidation clock for Jellyfin content.
///
/// Mounted trees do not re-run `task` or `onAppear` on foregrounding. Only
/// `RootView` advances `generation`; visible screens observe it and
/// reconcile their own state.
@Observable
final class ServerSyncState {
    private(set) var generation = 0
    private(set) var activeTarget: ServerSyncTarget?
    private(set) var manualRefreshGeneration = 0
    private(set) var manualRefreshTarget: ServerSyncTarget?
    private var refreshingTargets: Set<ServerSyncTarget> = []
    /// Set by `MainTabView` when loading libraries fails, cleared on success.
    /// Library shows the offline banner from it.
    var serverUnreachable = false

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
