import SwiftUI

/// The New Year surprise: fireworks and the year in gold over the pages, once
/// per profile, the first time Lagoon is on screen on 1 January or as the year
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
                        year: NewYear.upcomingYear(on: startedAt),
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
    /// The year being welcomed.
    let year: Int
    /// One full moment at full strength, whatever `time` is.
    var isStill = false

    private static let tintCount = 4
    private static let shells = Fireworks.show(tints: tintCount, seed: 2027)
    /// Dark enough that the page under the show does not fight it.
    private static let scrim = 0.7

    var body: some View {
        let moment = isStill ? Fireworks.stillMoment : time
        let tints = [palette.accent, palette.signal, NewYearGreeting.gold, Color.white]
        ZStack {
            Color.black.opacity(Self.scrim * (isStill ? 1 : Fireworks.presence(at: time)))
            Canvas { context, size in
                context.blendMode = .plusLighter
                for shell in Self.shells {
                    draw(shell, at: moment, in: &context, size: size, tint: tints[shell.tint % tints.count])
                }
            }
            NewYearGreeting(time: isStill ? nil : time, year: year)
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
        if let flash = Fireworks.flash(of: shell, at: moment, in: size) {
            context.fill(
                Path(ellipseIn: CGRect(
                    x: flash.center.x - flash.radius, y: flash.center.y - flash.radius,
                    width: flash.radius * 2, height: flash.radius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        .white.opacity(flash.opacity * 0.9), tint.opacity(flash.opacity * 0.45), tint.opacity(0),
                    ]),
                    center: flash.center, startRadius: 0, endRadius: flash.radius
                )
            )
        }
        guard let burst = Fireworks.burst(of: shell, at: moment, in: size) else { return }
        // Each spark's tail in three pieces, fainter and thinner toward its end.
        var pieces = [Path](repeating: Path(), count: Fireworks.tailPoints - 1)
        var heads = Path()
        for trail in burst.trails {
            for index in pieces.indices {
                pieces[index].move(to: trail[index])
                pieces[index].addLine(to: trail[index + 1])
            }
            if let head = trail.last {
                heads.move(to: head)
                heads.addLine(to: head)
            }
        }
        let strength = burst.opacity
        let looks: [(opacity: Double, width: Double)] = [(0.2, 0.5), (0.5, 0.78), (0.95, 1)]
        for (piece, look) in zip(pieces, looks) {
            context.stroke(
                piece, with: .color(tint.opacity(strength * look.opacity)),
                style: StrokeStyle(lineWidth: line * look.width, lineCap: .round)
            )
        }
        // A soft glow about the brightest piece, and a white-hot head.
        if let brightest = pieces.last {
            context.stroke(
                brightest, with: .color(tint.opacity(strength * 0.15)),
                style: StrokeStyle(lineWidth: line * 3.8, lineCap: .round)
            )
        }
        context.stroke(
            heads, with: .color(.white.opacity(strength * 0.95)),
            style: StrokeStyle(lineWidth: line * 1.05, lineCap: .round)
        )
    }
}

/// "Happy New Year" over the year in gold numerals. The numerals pop in one
/// after another, a shine crosses them now and then, and stars twinkle about
/// them. With no `time` it stands still at full strength.
struct NewYearGreeting: View {
    let time: TimeInterval?
    let year: Int

    static let gold = Color(red: 1, green: 0xD7 / 255, blue: 0x78 / 255)
    private static let paleGold = Color(red: 1, green: 0xF6 / 255, blue: 0xD6 / 255)
    private static let deepGold = Color(red: 0xF0 / 255, green: 0xA6 / 255, blue: 0x30 / 255)
    /// It arrives with the opening burst and leaves before the last sparks.
    static let arrives: Double = 1.5
    static let leaves: Double = Fireworks.duration - 1.6
    /// Each numeral pops this long after the one before it.
    private static let stagger: Double = 0.09
    /// When a shine starts across the numerals, and how long it takes.
    private static let shines: [Double] = [arrives + 0.8, 5.6, Fireworks.finale + 0.5]
    private static let shineTime: Double = 1.1
    /// The middle of the greeting, as a share of the page's height.
    private static let height = 0.56
    private static let stars = NewYearGreeting.scatter(count: 16, seed: 31)

    private var digits: [Character] { Array(year.formatted(.number.grouping(.never))) }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in drawStars(in: &context, size: size) }
                VStack(spacing: Metrics.Space.s) {
                    Text("Happy New Year")
                        .textCase(.uppercase)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .tracking(Metrics.newYearTracking)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.white)
                        .opacity(Self.rise(since: Self.arrives + 0.45, at: time, over: 0.5))
                    numerals
                        .foregroundStyle(LinearGradient(
                            colors: [Self.paleGold, Self.gold, Self.deepGold], startPoint: .top, endPoint: .bottom
                        ))
                        .overlay { shine.mask(numerals) }
                        .shadow(color: Self.gold.opacity(0.5), radius: Metrics.Space.xl)
                }
                .shadow(color: .black.opacity(0.65), radius: Metrics.Space.l)
                .padding(.horizontal, Metrics.Space.l)
                .frame(width: proxy.size.width)
                .position(x: proxy.size.width / 2, y: proxy.size.height * Self.height)
            }
            .opacity(time.map { max(0, min(1, (Self.leaves - $0) / 1.1)) } ?? 1)
        }
    }

    private var numerals: some View {
        HStack(spacing: 0) {
            ForEach(digits.indices, id: \.self) { index in
                let since = Self.arrives + Double(index) * Self.stagger
                Text(String(digits[index]))
                    .scaleEffect(Self.pop(since: since, at: time))
                    .opacity(Self.rise(since: since, at: time, over: 0.12))
            }
        }
        .font(.system(size: Metrics.newYearNumeralSize, weight: .black, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    /// A band of light that crosses the numerals, left to right.
    private var shine: some View {
        let position = Self.shinePosition(at: time)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: position - 0.2),
                .init(color: .white.opacity(0.9), location: position),
                .init(color: .white.opacity(0), location: position + 0.2),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    private func drawStars(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height * Self.height)
        let spread = Metrics.newYearNumeralSize
        for star in Self.stars {
            let twinkle = time.map { pow(max(0, sin($0 * star.speed + star.phase)), 3) } ?? star.rest
            let shown = twinkle * Self.rise(since: Self.arrives + 0.3, at: time, over: 0.6)
            guard shown > 0.02 else { continue }
            let at = CGPoint(x: center.x + star.offset.x * spread, y: center.y + star.offset.y * spread)
            context.fill(
                Self.star(at: at, radius: spread * star.size),
                with: .color(Self.paleGold.opacity(shown))
            )
        }
    }

    // MARK: - Timing

    /// 0 before `since`, 1 once `over` has passed. Always 1 standing still.
    static func rise(since: Double, at time: Double?, over: Double) -> Double {
        guard let time else { return 1 }
        return max(0, min(1, (time - since) / over))
    }

    /// A numeral's size as it pops: from small, past full size, and back.
    static func pop(since: Double, at time: Double?) -> Double {
        guard let time else { return 1 }
        let local = time - since
        guard local > 0 else { return 0.4 }
        return 1 - 0.6 * exp(-9 * local) * cos(11 * local)
    }

    /// Where the shine is across the numerals, 0 at the leading edge and 1
    /// at the trailing. Off to one side when none is crossing.
    static func shinePosition(at time: Double?) -> Double {
        guard let time, let start = shines.last(where: { $0 <= time }), time - start < shineTime else { return -1 }
        return -0.25 + 1.5 * (time - start) / shineTime
    }

    // MARK: - Stars

    struct Star: Equatable {
        /// From the greeting's middle, in numeral heights.
        let offset: CGPoint
        let size: Double
        let speed: Double
        let phase: Double
        /// How bright it is standing still.
        let rest: Double
    }

    /// Stars in a wide ring about the numerals, clear of their middle.
    static func scatter(count: Int, seed: UInt64) -> [Star] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let angle = (Double(index) + Double.random(in: -0.3...0.3, using: &generator)) / Double(count) * 2 * .pi
            let distance = Double.random(in: 0.85...1.25, using: &generator)
            return Star(
                offset: CGPoint(x: cos(angle) * distance * 1.55, y: sin(angle) * distance * 0.78),
                size: Double.random(in: 0.045...0.11, using: &generator),
                speed: Double.random(in: 2.2...4.2, using: &generator),
                phase: Double.random(in: 0...(2 * .pi), using: &generator),
                rest: Double.random(in: 0.35...1, using: &generator)
            )
        }
    }

    /// A four-pointed star: two thin diamonds crossed.
    static func star(at center: CGPoint, radius: Double) -> Path {
        var path = Path()
        let waist = radius * 0.16
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x - waist, y: center.y - waist))
        path.closeSubpath()
        return path
    }
}
