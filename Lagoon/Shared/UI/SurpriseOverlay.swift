import SwiftUI

/// What every dated surprise plays in: over the pages, out of the way of
/// touches, focus and VoiceOver. It asks whether the surprise is due once a
/// profile is on screen with no title playing, and plays it when the theme
/// store's count for it moves.
struct SurpriseOverlay<Still: View, Moving: View>: View {
    /// The theme store's count for this surprise. Each step plays it once.
    let count: Int
    /// Seconds it stays on the page, in motion and under Reduce Motion.
    let duration: Double
    let stillDuration: Double
    /// Seconds the page has to itself before the surprise is asked for.
    var lead: Double = 0
    /// The launch argument that plays it once on request, in debug builds.
    let debugKey: String
    /// Said to VoiceOver as it starts, where it has words.
    var announcement: String?
    /// Asks the theme store whether the surprise is due, while this page
    /// stays on screen.
    let askIfDue: @MainActor () async -> Void
    /// One still moment, for Reduce Motion, and the surprise in motion.
    @ViewBuilder let still: (Date) -> Still
    @ViewBuilder let moving: (Date) -> Moving

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.playerCover) private var playerCover
    @State private var startedAt: Date?
    #if DEBUG
    @State private var playedOnRequest = false
    #endif

    private struct Watch: Equatable {
        let isOnScreen: Bool
        let accountID: String?
    }

    private var watch: Watch {
        Watch(
            isOnScreen: scenePhase == .active && playerCover?.isPlayerUp != true,
            accountID: ThemeStore.shared.accountID
        )
    }

    var body: some View {
        ZStack {
            if let startedAt {
                ZStack {
                    if reduceMotion {
                        still(startedAt)
                    } else {
                        moving(startedAt)
                    }
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: watch) { await watchForIt() }
        .onChange(of: count) { play() }
    }

    private func watchForIt() async {
        guard watch.isOnScreen else { return }
        if lead > 0 {
            try? await Task.sleep(for: .seconds(lead))
            guard !Task.isCancelled else { return }
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: debugKey), !playedOnRequest {
            playedOnRequest = true
            play()
        }
        #endif
        await askIfDue()
    }

    private func play() {
        let start = Date.now
        withAnimation(.easeIn(duration: Motion.standard)) { startedAt = start }
        if let announcement {
            AccessibilityNotification.Announcement(announcement).post()
        }
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? stillDuration : duration))
            // A later start has its own end.
            if startedAt == start {
                withAnimation(.easeOut(duration: Motion.standard)) { startedAt = nil }
            }
        }
    }
}
