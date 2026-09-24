import Foundation

/// Launch-gated (`debug.playerInputTrace`): one console line per remote input
/// on the tvOS player, naming the path that took it and what it did. The
/// simulator and a Siri Remote deliver Back and Select by different routes,
/// and only this shows which one ran on the device.
nonisolated enum PlayerInputTrace {
    #if DEBUG
    static let isEnabled = UserDefaults.standard.bool(forKey: "debug.playerInputTrace")
    #endif

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        // NSLog, not print: it reaches both `devicectl --console` and the
        // simulator's unified log, where UI tests leave no stdout.
        NSLog("PlayerInput %@", message())
        #endif
    }
}
