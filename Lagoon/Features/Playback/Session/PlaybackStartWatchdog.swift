import Foundation
import LagoonEngine
import UIKit

/// Gives up on a start that has stopped getting anywhere.
///
/// Until the first frame the engine has no stall detection, so a stream that
/// stops sending keeps the spinner up for as long as the viewer waits. Bytes
/// read and packets queued count as progress, so a slow start that is still
/// moving is left alone. Pure so the limits can be pinned.
nonisolated struct PlaybackStartWatchdog: Equatable, Sendable {
    struct Progress: Equatable, Sendable {
        /// Bytes the cache has served. Zero without one, as for HLS.
        var bytes: Int64 = 0
        var videoIntake = 0
        var videoQueued = 0
        var audioQueued = 0
    }

    enum Reason: String, Equatable, Sendable {
        /// Nothing moved for `idleLimit`.
        case noProgress
        /// Still no first frame after `overallLimit`.
        case tooSlow
    }

    enum Verdict: Equatable, Sendable {
        case waiting
        case stalled(Reason, seconds: Double)
    }

    static let idleLimit: Double = 30
    static let overallLimit: Double = 120

    private(set) var startedAt: TimeInterval?
    private(set) var lastProgress: Progress?
    private(set) var lastProgressAt: TimeInterval?

    /// Time away from the app does not count: both clocks restart on return.
    mutating func observe(_ progress: Progress, isAppActive: Bool, at now: TimeInterval) -> Verdict {
        guard isAppActive else {
            self = PlaybackStartWatchdog()
            return .waiting
        }
        guard let startedAt, let lastProgressAt else {
            startedAt = now
            lastProgress = progress
            lastProgressAt = now
            return .waiting
        }
        var idleSince = lastProgressAt
        if progress != lastProgress {
            lastProgress = progress
            self.lastProgressAt = now
            idleSince = now
        }
        let waited = now - startedAt
        if now - idleSince >= Self.idleLimit {
            return .stalled(.noProgress, seconds: waited)
        }
        if waited >= Self.overallLimit {
            return .stalled(.tooSlow, seconds: waited)
        }
        return .waiting
    }
}

/// Samples a starting engine every two seconds and reports a stall once. The
/// controller ends it at the first frame and at every stop.
@MainActor
final class PlaybackStartWatch {
    struct Stall: Equatable {
        let reason: PlaybackStartWatchdog.Reason
        let seconds: Double
        let progress: PlaybackStartWatchdog.Progress
    }

    private enum Check {
        case waiting
        case stalled(Stall)
    }

    static let interval: Duration = .seconds(2)

    private var task: Task<Void, Never>?
    private let sleep: @MainActor (Duration) async throws -> Void
    private let uptime: @MainActor () -> TimeInterval
    private let isAppActive: @MainActor () -> Bool

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.sleep = sleep
        self.uptime = uptime
        self.isAppActive = isAppActive
    }

    isolated deinit {
        task?.cancel()
    }

    /// Replaces any earlier watch. Neither the engine nor this watch is held
    /// between samples, and a gone engine ends the watch.
    func begin(_ engine: DiagnosableEngine, onStall: @escaping @MainActor (Stall) -> Void) {
        end()
        let sleep = self.sleep
        task = Task { [weak self, weak engine] in
            var watchdog = PlaybackStartWatchdog()
            while !Task.isCancelled {
                switch self?.check(engine, with: &watchdog) {
                case .waiting?:
                    try? await sleep(Self.interval)
                case .stalled(let stall)?:
                    onStall(stall)
                    return
                case nil:
                    return
                }
            }
        }
    }

    func end() {
        task?.cancel()
        task = nil
    }

    static func progress(of engine: DiagnosableEngine) -> PlaybackStartWatchdog.Progress {
        let cache = engine.playbackCacheMetrics
        return PlaybackStartWatchdog.Progress(
            bytes: (cache?.networkBytes ?? 0) + (cache?.cacheHitBytes ?? 0),
            videoIntake: engine.videoIntakeCountDiagnostic,
            videoQueued: engine.videoQueueCountDiagnostic,
            audioQueued: engine.queueDepths.audio
        )
    }

    private func check(_ engine: DiagnosableEngine?, with watchdog: inout PlaybackStartWatchdog) -> Check? {
        guard let engine else { return nil }
        let progress = Self.progress(of: engine)
        switch watchdog.observe(progress, isAppActive: isAppActive(), at: uptime()) {
        case .waiting:
            return .waiting
        case .stalled(let reason, let seconds):
            return .stalled(Stall(reason: reason, seconds: seconds, progress: progress))
        }
    }
}
