import Foundation

/// How long a start waits for the display to finish switching mode. On an
/// Apple TV 4K the switch began 3 to 35 ms after the criteria were set and
/// took about three seconds, with the panel black throughout.
nonisolated enum DisplaySwitchWait {
    /// What the display has been asked and what it has announced since.
    struct State: Equatable {
        /// When the criteria last changed, where the system honours them.
        var appliedAt: Double?
        /// When a switch began after that.
        var switchStartedAt: Double?
        var switchInProgress = false
    }

    /// How long after the criteria are set a switch may still begin. None
    /// begins when the display is already in the mode asked for.
    static let startGrace = 0.3
    /// The end of a switch is not always announced.
    static let longestSwitch = 4.0
    static let pollInterval = 0.05

    /// Seconds left to wait at `now`, nil when the start can go ahead.
    static func remaining(_ state: State, now: Double) -> Double? {
        let until: Double
        if let switchStartedAt = state.switchStartedAt {
            guard state.switchInProgress else { return nil }
            until = switchStartedAt + longestSwitch
        } else if let appliedAt = state.appliedAt {
            until = appliedAt + startGrace
        } else {
            return nil
        }
        return until > now ? until - now : nil
    }

    /// Returns once the display has settled.
    @MainActor
    static func settle(
        state: () -> State,
        now: () -> Double,
        sleep: (Double) async -> Void
    ) async {
        while let remaining = remaining(state(), now: now()) {
            await sleep(min(remaining, pollInterval))
        }
    }
}
