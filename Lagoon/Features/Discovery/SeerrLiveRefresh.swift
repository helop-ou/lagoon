import Foundation
import SwiftUI

/// A detail page changes quickly while Radarr/Sonarr is transferring media,
/// but a request waiting for a person to approve it does not justify the same
/// network cadence.
nonisolated enum SeerrLiveRefreshCadence: Hashable {
    case waitingForApproval
    case transferring

    static let waitingIntervalSeconds = 30.0
    static let transferringIntervalSeconds = 10.0

    static func mediaDetails(_ details: SeerrMediaDetails?) -> Self? {
        guard let media = details?.mediaInfo else { return nil }

        // Once the title is wholly available (or definitively unavailable),
        // old request/queue rows in the payload must not keep the page alive.
        switch media.availability {
        case .available, .blocklisted, .deleted:
            return nil
        case .processing:
            return .transferring
        case .pending:
            return .waitingForApproval
        case .unknown, .partiallyAvailable:
            break
        }

        if media.downloadProgress() != nil { return .transferring }
        let statuses = media.requests?.map(\.requestStatus) ?? []
        if statuses.contains(.approved) { return .transferring }
        if statuses.contains(.pending) { return .waitingForApproval }
        return nil
    }

    static func request(_ request: SeerrMediaRequest) -> Self? {
        if request.downloadProgress != nil { return .transferring }
        switch request.progress {
        case .pending:
            return .waitingForApproval
        case .processing:
            return .transferring
        case .partiallyAvailable where request.requestStatus == .approved:
            // Some requested seasons may still be arriving even though the
            // show is already playable to a degree.
            return .transferring
        case .declined, .failed, .partiallyAvailable, .available,
             .removed, .blocked, .unknown:
            return nil
        }
    }

    func interval(defaults: UserDefaults = .standard) -> Duration {
        #if DEBUG
        let override = defaults.double(forKey: "debug.seerrLiveRefreshIntervalSeconds")
        if override > 0 { return .seconds(override) }
        #endif
        let seconds = switch self {
        case .waitingForApproval: Self.waitingIntervalSeconds
        case .transferring: Self.transferringIntervalSeconds
        }
        return .seconds(seconds)
    }
}

/// The loop is deliberately tiny and injectable: production sleeps on the
/// continuous clock, while tests can advance it instantly and prove that one
/// refresh always finishes before the next interval begins.
@MainActor
enum SeerrLiveRefreshLoop {
    static func run(
        interval: Duration,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        shouldContinue: () -> Bool = { true },
        refresh: () async -> Void
    ) async {
        while !Task.isCancelled, shouldContinue() {
            do {
                try await sleep(interval)
            } catch {
                return
            }
            guard !Task.isCancelled, shouldContinue() else { return }
            await refresh()
        }
    }
}

/// Runs a single sequential refresh loop only while its detail page is both
/// visible and foreground-active. SwiftUI cancels the structured task when
/// any part of the task id changes, so pushed routes and background scenes do
/// not retain an unowned poller. Foregrounding gets one immediate refresh;
/// normal appearance uses the page's own initial load and starts with a delay.
private struct SeerrLiveRefreshModifier: ViewModifier {
    let cadence: SeerrLiveRefreshCadence?
    let isPaused: Bool
    let action: @MainActor () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var isRefreshing = false
    @State private var foregroundGeneration = 0
    @State private var handledForegroundGeneration = 0

    private var canRefresh: Bool {
        isVisible && scenePhase == .active && cadence != nil && !isPaused
    }

    private var taskID: TaskID {
        TaskID(
            isVisible: isVisible,
            isSceneActive: scenePhase == .active,
            cadence: cadence,
            isPaused: isPaused,
            foregroundGeneration: foregroundGeneration
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: scenePhase) { previous, current in
                if previous != .active, current == .active {
                    foregroundGeneration &+= 1
                }
            }
            .task(id: taskID) {
                guard canRefresh else { return }

                if foregroundGeneration > handledForegroundGeneration {
                    handledForegroundGeneration = foregroundGeneration
                    await refresh()
                    guard !Task.isCancelled else { return }
                }

                guard let cadence else { return }
                await SeerrLiveRefreshLoop.run(
                    interval: cadence.interval(),
                    shouldContinue: { canRefresh }
                ) {
                    await refresh()
                }
            }
    }

    @MainActor
    private func refresh() async {
        guard canRefresh, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await action()
    }

    private struct TaskID: Hashable {
        let isVisible: Bool
        let isSceneActive: Bool
        let cadence: SeerrLiveRefreshCadence?
        let isPaused: Bool
        let foregroundGeneration: Int
    }
}

extension View {
    func seerrLiveRefreshable(
        cadence: SeerrLiveRefreshCadence?,
        isPaused: Bool = false,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(SeerrLiveRefreshModifier(
            cadence: cadence,
            isPaused: isPaused,
            action: action
        ))
    }
}
