import SwiftUI

/// The Christmas surprise: Santa's sleigh crosses the sky over the pages, the
/// first time a profile is on screen on Christmas Eve and again on Christmas
/// Day. It waits for a playing title to close. Ignores touches and focus.
///
/// Reduce Motion gets one still moment of the flight.
struct SantaOverlay: View {
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
                    SantaFlightFrame(
                        time: timeline.date.timeIntervalSince(startedAt),
                        isStill: reduceMotion
                    )
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: watch) { await watchForChristmas() }
        .onChange(of: ThemeStore.shared.santaCount) { play() }
    }

    private func watchForChristmas() async {
        guard watch.isOnScreen else { return }
        // The page arrives first.
        try? await Task.sleep(for: .seconds(SantaFlight.wait))
        guard !Task.isCancelled else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.santaFlight"), !playedOnRequest {
            playedOnRequest = true
            play()
        }
        #endif
        ThemeStore.shared.welcomeSantaIfDue()
    }

    private func play() {
        let start = Date.now
        withAnimation(.easeIn(duration: Motion.standard)) { startedAt = start }
        Task {
            try? await Task.sleep(for: .seconds(reduceMotion ? SantaFlight.stillDuration : SantaFlight.duration))
            if startedAt == start {
                withAnimation(.easeOut(duration: Motion.standard)) { startedAt = nil }
            }
        }
    }
}

/// The flight at one moment: the page dimmed a little, the wake and its dust,
/// and the team in gold.
struct SantaFlightFrame: View {
    let time: TimeInterval
    /// One full moment at full strength, whatever `time` is.
    var isStill = false

    /// Enough that the gold reads over bright artwork, and the page stays a page.
    private static let scrim = 0.42

    var body: some View {
        let moment = isStill ? SantaFlight.stillMoment : time
        ZStack {
            Color.black.opacity(Self.scrim * (isStill ? 1 : SantaFlight.presence(at: time)))
            Canvas { context, size in
                let unit = SantaFlight.scale(in: size)
                var light = context
                light.blendMode = .plusLighter
                drawWake(at: moment, in: &light, size: size, unit: unit)
                drawDust(at: moment, in: &light, size: size)
                // A halo first, then the team itself over a soft shadow.
                context.drawLayer { halo in
                    halo.addFilter(.blur(radius: 9 * unit))
                    halo.opacity = 0.55
                    drawTeam(at: moment, in: &halo, size: size, unit: unit)
                }
                context.drawLayer { team in
                    team.addFilter(.shadow(color: .black.opacity(0.6), radius: 5 * unit))
                    drawTeam(at: moment, in: &team, size: size, unit: unit)
                }
                drawNose(at: moment, in: &light, size: size, unit: unit)
            }
        }
    }

    // MARK: - Team

    private func drawTeam(at moment: Double, in context: inout GraphicsContext, size: CGSize, unit: Double) {
        let sleigh = SantaFlight.placement(ahead: 0, bob: 1.4, phase: 2.2, at: moment, in: size)
        // Pairs first, the lead last, so each runs in front of the one behind.
        var reins = Path()
        reins.move(to: Self.point(SantaGeometry.hand, on: sleigh, unit: unit))
        for (index, ahead) in SantaFlight.pairs.enumerated() {
            let phase = Double(index) * 1.9
            let far = SantaFlight.placement(
                ahead: ahead + SantaFlight.farOffset.x, lift: SantaFlight.farOffset.y,
                bob: 3, phase: phase + 1.1, at: moment, in: size
            )
            let near = SantaFlight.placement(ahead: ahead, bob: 3, phase: phase, at: moment, in: size)
            reins.addLine(to: Self.point(SantaGeometry.collar, on: near, unit: unit))
            drawReindeer(
                at: far, stride: SantaFlight.stride(at: moment, phase: phase + 1.1),
                isFar: true, in: &context, unit: unit
            )
            drawReindeer(
                at: near, stride: SantaFlight.stride(at: moment, phase: phase),
                isFar: false, in: &context, unit: unit
            )
        }
        context.stroke(
            reins, with: .color(ChristmasInk.gold.opacity(0.8)),
            style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round, lineJoin: .round)
        )
        drawSleigh(at: sleigh, in: &context, unit: unit)
    }

    private func drawReindeer(
        at placement: SantaFlight.Placement, stride: Double, isFar: Bool,
        in context: inout GraphicsContext, unit: Double
    ) {
        let local = Self.local(context, at: placement, unit: unit)
        // Every colour is opaque: a see-through leg shows the body under it.
        let behind = GraphicsContext.Shading.color(isFar ? ChristmasInk.shade.mix(with: .black, by: 0.18) : ChristmasInk.shade)
        let coat = isFar
            ? GraphicsContext.Shading.color(ChristmasInk.gold.mix(with: ChristmasInk.shade, by: 0.72))
            : .linearGradient(
                Gradient(colors: [ChristmasInk.paleGold, ChristmasInk.gold, ChristmasInk.gold.mix(with: ChristmasInk.deepGold, by: 0.5)]),
                startPoint: CGPoint(x: 0, y: -62), endPoint: CGPoint(x: 0, y: 48)
            )
        let legs = SantaGeometry.legs(stride: stride)
        let line = StrokeStyle(lineWidth: SantaGeometry.antlerLine, lineCap: .round, lineJoin: .round)
        // Far legs and antler, then the body, then the near ones over it.
        for index in [0, 2] { Self.draw(legs[index], in: local, with: behind) }
        var farAntler = local
        farAntler.translateBy(x: SantaGeometry.farAntler.x, y: SantaGeometry.farAntler.y)
        farAntler.stroke(SantaGeometry.antler, with: behind, style: line)
        local.fill(SantaGeometry.reindeer, with: coat)
        for index in [1, 3] { Self.draw(legs[index], in: local, with: coat) }
        local.stroke(SantaGeometry.antler, with: isFar ? coat : .color(ChristmasInk.paleGold), style: line)
        guard !isFar else { return }
        local.stroke(
            SantaGeometry.harness, with: .color(ChristmasInk.red),
            style: StrokeStyle(lineWidth: SantaGeometry.harnessLine, lineCap: .round)
        )
        local.fill(Path(ellipseIn: SantaGeometry.bell), with: .color(ChristmasInk.paleGold))
    }

    private static func draw(_ leg: SantaGeometry.Leg, in context: GraphicsContext, with coat: GraphicsContext.Shading) {
        var upper = Path()
        upper.move(to: leg.hip)
        upper.addLine(to: leg.knee)
        context.stroke(upper, with: coat, style: StrokeStyle(lineWidth: leg.upper, lineCap: .round))
        var lower = Path()
        lower.move(to: leg.knee)
        lower.addLine(to: leg.hoof)
        context.stroke(lower, with: coat, style: StrokeStyle(lineWidth: leg.lower, lineCap: .round))
    }

    private func drawSleigh(at placement: SantaFlight.Placement, in context: inout GraphicsContext, unit: Double) {
        let local = Self.local(context, at: placement, unit: unit)
        local.stroke(
            SantaGeometry.runner, with: .color(ChristmasInk.gold),
            style: StrokeStyle(lineWidth: SantaGeometry.runnerLine, lineCap: .round, lineJoin: .round)
        )
        local.fill(
            SantaGeometry.sack,
            with: .linearGradient(
                Gradient(colors: [ChristmasInk.sack.mix(with: .white, by: 0.25), ChristmasInk.sack]),
                startPoint: CGPoint(x: -30, y: -62), endPoint: CGPoint(x: -50, y: 0)
            )
        )
        local.fill(SantaGeometry.suit, with: .color(ChristmasInk.red))
        local.fill(SantaGeometry.face, with: .color(ChristmasInk.skin))
        local.fill(SantaGeometry.eye, with: .color(.black.opacity(0.75)))
        local.fill(
            SantaGeometry.sleigh,
            with: .linearGradient(
                Gradient(colors: [ChristmasInk.paleGold, ChristmasInk.gold, ChristmasInk.gold.mix(with: ChristmasInk.deepGold, by: 0.75)]),
                startPoint: CGPoint(x: 0, y: -46), endPoint: CGPoint(x: 0, y: 30)
            )
        )
        local.stroke(
            SantaGeometry.arm, with: .color(ChristmasInk.red),
            style: StrokeStyle(lineWidth: SantaGeometry.armLine, lineCap: .round)
        )
        local.fill(SantaGeometry.fur, with: .color(.white))
        local.stroke(
            SantaGeometry.brim, with: .color(.white),
            style: StrokeStyle(lineWidth: SantaGeometry.brimLine, lineCap: .round)
        )
    }

    /// The lead reindeer's nose, glowing red.
    private func drawNose(at moment: Double, in context: inout GraphicsContext, size: CGSize, unit: Double) {
        guard let ahead = SantaFlight.pairs.last else { return }
        let phase = Double(SantaFlight.pairs.count - 1) * 1.9
        let lead = SantaFlight.placement(ahead: ahead, bob: 3, phase: phase, at: moment, in: size)
        let center = Self.point(SantaGeometry.nose, on: lead, unit: unit)
        let glow = 15 * unit
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - glow, y: center.y - glow, width: glow * 2, height: glow * 2)),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: ChristmasInk.nose, location: 0.18),
                    .init(color: ChristmasInk.nose.opacity(0.35), location: 0.45),
                    .init(color: ChristmasInk.nose.opacity(0), location: 1),
                ]),
                center: center, startRadius: 0, endRadius: glow
            )
        )
    }

    // MARK: - Wake

    private func drawWake(at moment: Double, in context: inout GraphicsContext, size: CGSize, unit: Double) {
        let points = SantaFlight.ribbon(at: moment, in: size)
        guard points.count > 1 else { return }
        context.drawLayer { soft in
            soft.addFilter(.blur(radius: 5 * unit))
            for index in 1..<points.count {
                let spent = Double(index) / Double(points.count)
                var piece = Path()
                piece.move(to: points[index - 1])
                piece.addLine(to: points[index])
                soft.stroke(
                    piece, with: .color(ChristmasInk.gold.opacity(0.6 * pow(1 - spent, 1.5))),
                    style: StrokeStyle(lineWidth: (16 - 12 * spent) * unit, lineCap: .round)
                )
            }
        }
    }

    private func drawDust(at moment: Double, in context: inout GraphicsContext, size: CGSize) {
        let tints = [ChristmasInk.paleGold, ChristmasInk.gold, Color.white]
        for spark in SantaFlight.sparks(at: moment, in: size) {
            let tint = tints[spark.tint % tints.count]
            guard spark.isStar else {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: spark.center.x - spark.radius, y: spark.center.y - spark.radius,
                        width: spark.radius * 2, height: spark.radius * 2
                    )),
                    with: .color(tint.opacity(spark.opacity))
                )
                continue
            }
            // A soft glow about each star, then the star.
            let reach = spark.radius * 1.5
            context.fill(
                Path(ellipseIn: CGRect(
                    x: spark.center.x - reach, y: spark.center.y - reach, width: reach * 2, height: reach * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [ChristmasInk.gold.opacity(spark.opacity * 0.4), ChristmasInk.gold.opacity(0)]),
                    center: spark.center, startRadius: 0, endRadius: reach
                )
            )
            var turned = context
            turned.translateBy(x: spark.center.x, y: spark.center.y)
            turned.rotate(by: .radians(spark.turn))
            turned.scaleBy(x: spark.radius, y: spark.radius)
            turned.fill(SantaGeometry.star, with: .color(tint.opacity(spark.opacity)))
        }
    }

    // MARK: - Placing

    /// A context whose origin, lean and size are a figure's own.
    private static func local(
        _ context: GraphicsContext, at placement: SantaFlight.Placement, unit: Double
    ) -> GraphicsContext {
        var local = context
        local.translateBy(x: placement.center.x, y: placement.center.y)
        local.rotate(by: .radians(placement.turn))
        local.scaleBy(x: unit, y: unit)
        return local
    }

    /// A figure's own point, on the page.
    private static func point(_ own: CGPoint, on placement: SantaFlight.Placement, unit: Double) -> CGPoint {
        let turned = CGPoint(
            x: own.x * cos(placement.turn) - own.y * sin(placement.turn),
            y: own.x * sin(placement.turn) + own.y * cos(placement.turn)
        )
        return CGPoint(x: placement.center.x + turned.x * unit, y: placement.center.y + turned.y * unit)
    }
}
