import SwiftUI

/// The New Year surprise: fireworks and a greeting over the pages, once per
/// profile, the first time Lagoon is on screen on 1 January or as the year
/// turns. It waits for a playing title to close. Ignores touches and focus.
///
/// Reduce Motion gets one still moment of the show.
struct NewYearOverlay: View {
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
                TimelineView(.animation(paused: reduceMotion)) { timeline in
                    FireworksFrame(
                        time: timeline.date.timeIntervalSince(startedAt),
                        palette: Theme.palette,
                        isStill: reduceMotion
                    )
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: watch) { await watchForNewYear() }
        .onChange(of: ThemeStore.shared.newYearCount) { play() }
    }

    private func watchForNewYear() async {
        guard watch.isOnScreen else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.newYearFireworks"), !playedOnRequest {
            playedOnRequest = true
            play()
        }
        #endif
        ThemeStore.shared.welcomeNewYearIfDue()
        // Still open as the year turns.
        guard let wait = NewYear.secondsUntilMidnight(from: .now) else { return }
        try? await Task.sleep(for: .seconds(wait + 1))
        guard !Task.isCancelled else { return }
        ThemeStore.shared.welcomeNewYearIfDue()
    }

    private func play() {
        let start = Date.now
        withAnimation(.easeIn(duration: Motion.standard)) { startedAt = start }
        AccessibilityNotification.Announcement(String(localized: "Happy New Year")).post()
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? Fireworks.stillDuration : Fireworks.duration))
            if startedAt == start {
                withAnimation(.easeOut(duration: Motion.standard)) { startedAt = nil }
            }
        }
    }
}

/// The show at one moment: a scrim, the shells in the theme's colours and
/// the greeting.
struct FireworksFrame: View {
    let time: TimeInterval
    let palette: ThemePalette
    /// One full moment at full strength, whatever `time` is.
    var isStill = false

    private static let shells = Fireworks.show(shells: Metrics.fireworkShells, tints: 4, seed: 2027)
    /// A warm white, so not every shell is the theme's.
    private static let gold = Color(red: 1, green: 0xE9 / 255, blue: 0xA8 / 255)
    /// The greeting sits below the bursts, as a share of the page's height.
    private static let greetingHeight = 0.58
    /// Dark enough that a row title under the greeting does not fight it.
    private static let scrim = 0.62

    var body: some View {
        let moment = isStill ? Fireworks.stillMoment : time
        let tints = [palette.accent, palette.signal, Self.gold, Color.white]
        ZStack {
            Color.black.opacity(Self.scrim * (isStill ? 1 : Fireworks.presence(at: time)))
            Canvas { context, size in
                context.blendMode = .plusLighter
                for shell in Self.shells {
                    draw(shell, at: moment, in: &context, size: size, tint: tints[shell.tint % tints.count])
                }
            }
            GeometryReader { proxy in
                Text("Happy New Year")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.6), radius: Metrics.Space.m)
                    .opacity(isStill ? 1 : Fireworks.greeting(at: time))
                    .frame(width: proxy.size.width)
                    .position(x: proxy.size.width / 2, y: proxy.size.height * Self.greetingHeight)
            }
        }
    }

    private func draw(
        _ shell: Fireworks.Shell, at moment: Double, in context: inout GraphicsContext, size: CGSize, tint: Color
    ) {
        let line = Metrics.fireworkLineWidth
        if let rocket = Fireworks.rocket(of: shell, at: moment, in: size) {
            var tail = Path()
            tail.move(to: rocket.from)
            tail.addLine(to: rocket.to)
            context.stroke(
                tail, with: .color(.white.opacity(rocket.opacity)),
                style: StrokeStyle(lineWidth: line * 0.8, lineCap: .round)
            )
        }
        let sparks = Fireworks.sparks(of: shell, at: moment, in: size)
        guard let opacity = sparks.first?.opacity else { return }
        var streaks = Path()
        var heads = Path()
        for spark in sparks {
            streaks.move(to: spark.from)
            streaks.addLine(to: spark.to)
            heads.move(to: spark.to)
            heads.addLine(to: spark.to)
        }
        // A soft glow, the streak in the shell's colour, and a white head.
        context.stroke(
            streaks, with: .color(tint.opacity(opacity * 0.16)),
            style: StrokeStyle(lineWidth: line * 3.4, lineCap: .round)
        )
        context.stroke(
            streaks, with: .color(tint.opacity(opacity * 0.9)),
            style: StrokeStyle(lineWidth: line, lineCap: .round)
        )
        context.stroke(
            heads, with: .color(.white.opacity(opacity * 0.9)),
            style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round)
        )
    }
}
