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
                Group {
                    if reduceMotion {
                        SantaFlightFrame(time: 0, isStill: true)
                    } else {
                        SantaFlightLayers(startedAt: startedAt)
                    }
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

/// The flight at one moment, drawn once: the page dimmed a little, the dust,
/// and the team in gold. It is what stands under Reduce Motion, and the
/// picture the moving layers are checked against.
struct SantaFlightFrame: View {
    let time: TimeInterval
    /// One full moment at full strength, whatever `time` is.
    var isStill = false

    var body: some View {
        let moment = isStill ? SantaFlight.stillMoment : time
        ZStack {
            Color.black.opacity(SantaFlight.scrim * (isStill ? 1 : SantaFlight.presence(at: time)))
            Canvas { context, size in
                let unit = SantaFlight.scale(in: size)
                var light = context
                light.blendMode = .plusLighter
                Self.drawDust(at: moment, in: light, size: size)
                let sleigh = SantaFlight.placement(of: SantaFlight.team[SantaFlight.team.count - 1], at: moment, in: size)
                context.drawLayer { soft in
                    soft.addFilter(.blur(radius: 5 * unit))
                    SantaArt.drawWake(in: Self.local(soft, at: sleigh, unit: unit))
                }
                SantaArt.drawGlowing({ Self.drawTeam(at: moment, in: $0, size: size, unit: unit) }, in: context, unit: unit)
                if let lead = SantaFlight.team.first(where: \.isLead) {
                    let placement = SantaFlight.placement(of: lead, at: moment, in: size)
                    SantaArt.drawNose(in: Self.local(light, at: placement, unit: unit))
                }
            }
        }
    }

    private static func drawTeam(at moment: Double, in context: GraphicsContext, size: CGSize, unit: Double) {
        for member in SantaFlight.team {
            let placement = SantaFlight.placement(of: member, at: moment, in: size)
            let local = local(context, at: placement, unit: unit)
            switch member.kind {
            case .sleigh:
                // The reins run under the sleigh and over the reindeer.
                context.stroke(
                    SantaFlight.reins(at: moment, in: size), with: .color(ChristmasInk.gold.opacity(SantaFlight.reinsOpacity)),
                    style: StrokeStyle(lineWidth: SantaFlight.reinsLine * unit, lineCap: .round, lineJoin: .round)
                )
                SantaArt.drawSleigh(in: local)
            case .near, .far:
                let isFar = member.kind == .far
                let legs = SantaGeometry.legs(stride: SantaFlight.stride(at: moment, phase: member.phase))
                SantaArt.drawLegs(legs, isFar: isFar, isBeyond: true, in: local)
                SantaArt.drawBody(isFar: isFar, in: local)
                SantaArt.drawLegs(legs, isFar: isFar, isBeyond: false, in: local)
                if !isFar { SantaArt.drawTack(in: local) }
            }
        }
    }

    private static func drawDust(at moment: Double, in context: GraphicsContext, size: CGSize) {
        for spark in SantaFlight.sparks(at: moment, in: size) {
            var turned = context
            turned.translateBy(x: spark.center.x, y: spark.center.y)
            turned.rotate(by: .radians(spark.turn))
            turned.scaleBy(x: spark.radius, y: spark.radius)
            SantaArt.drawMote(
                isStar: spark.isStar, tint: SantaArt.dustTints[spark.tint % SantaArt.dustTints.count],
                opacity: spark.opacity, in: turned
            )
        }
    }

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
}
