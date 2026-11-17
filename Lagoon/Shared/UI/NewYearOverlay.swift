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
                let year = NewYear.upcomingYear(on: startedAt)
                ZStack {
                    if reduceMotion {
                        FireworksFrame(time: 0, palette: Theme.palette, year: year, isStill: true)
                    } else {
                        FireworksLayers(startedAt: startedAt, palette: Theme.palette)
                        NewYearGreetingLayers(startedAt: startedAt, year: year)
                    }
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

    static let tintCount = 4

    /// The show's colours: the theme's two, gold and white.
    static func tints(for palette: ThemePalette) -> [Color] {
        [palette.accent, palette.signal, NewYearGreeting.gold, Color.white]
    }
    static let shells = Fireworks.show(tints: tintCount, seed: 2027)

    var body: some View {
        let moment = isStill ? Fireworks.stillMoment : time
        let tints = Self.tints(for: palette)
        ZStack {
            Color.black.opacity(Fireworks.scrim * (isStill ? 1 : Fireworks.presence(at: time)))
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
                style: StrokeStyle(lineWidth: line * Fireworks.glowWidth, lineCap: .round)
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

    /// The sleigh's golds, so the winter's two surprises match.
    static let gold = ChristmasInk.gold
    static let paleGold = ChristmasInk.paleGold
    private static let deepGold = ChristmasInk.deepGold
    /// It arrives with the opening burst and leaves before the last sparks.
    static let arrives: Double = 1.5
    static let leaves: Double = Fireworks.duration - 1.6
    /// Each numeral pops this long after the one before it.
    private static let stagger: Double = 0.09
    /// When a shine starts across the numerals, and how long it takes.
    private static let shines: [Double] = [arrives + 0.8, 5.6, Fireworks.finale + 0.5]
    private static let shineTime: Double = 1.1
    /// How wide the band of light is, as a share of the numerals' width.
    static let shineWidth = 0.4
    /// The middle of the greeting, as a share of the page's height.
    static let height = 0.56
    static let stars = NewYearGreeting.scatter(count: 16, seed: 31)

    static func digits(of year: Int) -> [Character] { Array(year.formatted(.number.grouping(.never))) }

    private var digits: [Character] { Self.digits(of: year) }

    // MARK: - Pieces

    /// The line above the numerals, as it stands.
    static var title: some View {
        Text("Happy New Year")
            .textCase(.uppercase)
            .font(.system(.title, design: .rounded, weight: .bold))
            .tracking(Metrics.newYearTracking)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.white)
    }

    /// One numeral, in whatever it is filled with.
    static func numeral(_ digit: Character, size: Double = Metrics.newYearNumeralSize) -> some View {
        Text(String(digit))
            .font(.system(size: size, weight: .black, design: .rounded))
            .lineLimit(1)
    }

    static let numeralFill = LinearGradient(colors: [paleGold, gold, deepGold], startPoint: .top, endPoint: .bottom)
    static let numeralGlow = gold.opacity(0.5)
    static let shadow = Color.black.opacity(0.65)

    // MARK: - Moments

    /// When a numeral pops in, by its place in the year.
    static func arrival(ofNumeral index: Int) -> Double {
        arrives + Double(index) * stagger
    }

    static let titleArrives = arrives + 0.45
    static let titleRise = 0.5
    static let numeralRise = 0.12

    /// How present the whole greeting is: full until it leaves with the
    /// last sparks.
    static func presence(at time: Double) -> Double {
        max(0, min(1, (leaves - time) / 1.1))
    }

    /// How bright a star is at a moment.
    static func brightness(of star: Star, at time: Double) -> Double {
        pow(max(0, sin(time * star.speed + star.phase)), 3) * rise(since: arrives + 0.3, at: time, over: 0.6)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in drawStars(in: &context, size: size) }
                VStack(spacing: Metrics.Space.s) {
                    Self.title
                        .opacity(Self.rise(since: Self.titleArrives, at: time, over: Self.titleRise))
                    numerals
                        .foregroundStyle(Self.numeralFill)
                        .overlay { shine.mask(numerals) }
                        .shadow(color: Self.numeralGlow, radius: Metrics.Space.xl)
                }
                .shadow(color: Self.shadow, radius: Metrics.Space.l)
                .padding(.horizontal, Metrics.Space.l)
                .frame(width: proxy.size.width)
                .position(x: proxy.size.width / 2, y: proxy.size.height * Self.height)
            }
            .opacity(time.map { Self.presence(at: $0) } ?? 1)
        }
    }

    private var numerals: some View {
        HStack(spacing: 0) {
            ForEach(digits.indices, id: \.self) { index in
                let since = Self.arrival(ofNumeral: index)
                Self.numeral(digits[index])
                    .scaleEffect(Self.pop(since: since, at: time))
                    .opacity(Self.rise(since: since, at: time, over: Self.numeralRise))
            }
        }
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
            let shown = time.map { Self.brightness(of: star, at: $0) } ?? star.rest
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
        SantaGeometry.star.applying(
            CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: radius, y: radius)
        )
    }
}
