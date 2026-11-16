import SwiftUI

/// How the Christmas figures are painted, each in its own units about its
/// own middle. The still picture draws with these, and the moving layers
/// take their pictures from them, so the two cannot drift apart.
enum SantaArt {
    // MARK: - Reindeer

    /// A leg's colour: the legs on the viewer's side, or the pair beyond the body.
    static func legColor(isFar: Bool, isBeyond: Bool) -> Color {
        switch (isFar, isBeyond) {
        case (false, false): ChristmasInk.gold.mix(with: ChristmasInk.deepGold, by: 0.32)
        case (false, true): ChristmasInk.shade
        case (true, false): farCoat
        case (true, true): ChristmasInk.shade.mix(with: .black, by: 0.18)
        }
    }

    /// The far reindeer of a pair is gold in shadow, and opaque: seen
    /// through, it read as a blur of the near one.
    private static let farCoat = ChristmasInk.gold.mix(with: ChristmasInk.shade, by: 0.72)

    private static func coat(isFar: Bool) -> GraphicsContext.Shading {
        isFar
            ? .color(farCoat)
            : .linearGradient(
                Gradient(colors: [
                    ChristmasInk.paleGold, ChristmasInk.gold,
                    ChristmasInk.gold.mix(with: ChristmasInk.deepGold, by: 0.5),
                ]),
                startPoint: CGPoint(x: 0, y: -62), endPoint: CGPoint(x: 0, y: 48)
            )
    }

    /// Two of a reindeer's legs: the pair beyond its body, or the pair on
    /// the viewer's side.
    static func drawLegs(_ legs: [SantaGeometry.Leg], isFar: Bool, isBeyond: Bool, in context: GraphicsContext) {
        let shading = GraphicsContext.Shading.color(legColor(isFar: isFar, isBeyond: isBeyond))
        for index in isBeyond ? [0, 2] : [1, 3] {
            let leg = legs[index]
            var upper = Path()
            upper.move(to: leg.hip)
            upper.addLine(to: leg.knee)
            context.stroke(upper, with: shading, style: StrokeStyle(lineWidth: leg.upper, lineCap: .round))
            var lower = Path()
            lower.move(to: leg.knee)
            lower.addLine(to: leg.hoof)
            context.stroke(lower, with: shading, style: StrokeStyle(lineWidth: leg.lower, lineCap: .round))
        }
    }

    /// Body, head and both antlers: everything that holds its shape.
    static func drawBody(isFar: Bool, in context: GraphicsContext) {
        let line = StrokeStyle(lineWidth: SantaGeometry.antlerLine, lineCap: .round, lineJoin: .round)
        var beyond = context
        beyond.translateBy(x: SantaGeometry.farAntler.x, y: SantaGeometry.farAntler.y)
        beyond.stroke(SantaGeometry.antler, with: .color(legColor(isFar: isFar, isBeyond: true)), style: line)
        context.fill(SantaGeometry.reindeer, with: coat(isFar: isFar))
        context.stroke(
            SantaGeometry.antler, with: isFar ? .color(farCoat) : .color(ChristmasInk.paleGold), style: line
        )
    }

    /// The near reindeer's harness and bell, over its legs.
    static func drawTack(in context: GraphicsContext) {
        context.stroke(
            SantaGeometry.harness, with: .color(ChristmasInk.red),
            style: StrokeStyle(lineWidth: SantaGeometry.harnessLine, lineCap: .round)
        )
        context.fill(Path(ellipseIn: SantaGeometry.bell), with: .color(ChristmasInk.paleGold))
    }

    /// The lead's nose, glowing red.
    static func drawNose(in context: GraphicsContext) {
        let center = SantaGeometry.nose
        let glow = SantaGeometry.noseGlow
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

    // MARK: - Sleigh

    static func drawSleigh(in context: GraphicsContext) {
        context.stroke(
            SantaGeometry.runner, with: .color(ChristmasInk.gold),
            style: StrokeStyle(lineWidth: SantaGeometry.runnerLine, lineCap: .round, lineJoin: .round)
        )
        context.fill(
            SantaGeometry.sack,
            with: .linearGradient(
                Gradient(colors: [ChristmasInk.sack.mix(with: .white, by: 0.25), ChristmasInk.sack]),
                startPoint: CGPoint(x: -30, y: -62), endPoint: CGPoint(x: -50, y: 0)
            )
        )
        context.fill(SantaGeometry.suit, with: .color(ChristmasInk.red))
        context.fill(SantaGeometry.face, with: .color(ChristmasInk.skin))
        context.fill(SantaGeometry.eye, with: .color(.black.opacity(0.75)))
        context.fill(
            SantaGeometry.sleigh,
            with: .linearGradient(
                Gradient(colors: [
                    ChristmasInk.paleGold, ChristmasInk.gold,
                    ChristmasInk.gold.mix(with: ChristmasInk.deepGold, by: 0.75),
                ]),
                startPoint: CGPoint(x: 0, y: -46), endPoint: CGPoint(x: 0, y: 30)
            )
        )
        context.stroke(
            SantaGeometry.arm, with: .color(ChristmasInk.red),
            style: StrokeStyle(lineWidth: SantaGeometry.armLine, lineCap: .round)
        )
        context.fill(SantaGeometry.fur, with: .color(.white))
        context.stroke(
            SantaGeometry.brim, with: .color(.white),
            style: StrokeStyle(lineWidth: SantaGeometry.brimLine, lineCap: .round)
        )
    }

    /// The bright streak straight behind the sleigh, fading away from it.
    static func drawWake(in context: GraphicsContext) {
        let wake = SantaGeometry.wake
        context.fill(
            Path(ellipseIn: wake),
            with: .linearGradient(
                Gradient(colors: [ChristmasInk.gold.opacity(0), ChristmasInk.gold.opacity(0.6)]),
                startPoint: CGPoint(x: wake.minX, y: wake.midY), endPoint: CGPoint(x: wake.maxX, y: wake.midY)
            )
        )
    }

    // MARK: - Dust

    static let dustTints = [ChristmasInk.paleGold, ChristmasInk.gold, Color.white]

    /// A mote of radius 1 about the origin: a star in a soft glow, or a dot.
    static func drawMote(isStar: Bool, tint: Color, opacity: Double, in context: GraphicsContext) {
        guard isStar else {
            context.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)), with: .color(tint.opacity(opacity)))
            return
        }
        let reach = SantaGeometry.starGlow
        context.fill(
            Path(ellipseIn: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
            with: .radialGradient(
                Gradient(colors: [ChristmasInk.gold.opacity(opacity * 0.4), ChristmasInk.gold.opacity(0)]),
                center: .zero, startRadius: 0, endRadius: reach
            )
        )
        context.fill(SantaGeometry.star, with: .color(tint.opacity(opacity)))
    }

    // MARK: - Glow

    /// A soft gold halo behind `art`, then `art` itself over a shadow, as
    /// the figures are always drawn. `context` is in points, and `unit` is
    /// points to one of the figures' units.
    static func drawGlowing(_ art: (GraphicsContext) -> Void, in context: GraphicsContext, unit: Double) {
        context.drawLayer { halo in
            halo.addFilter(.blur(radius: 9 * unit))
            halo.opacity = 0.55
            art(halo)
        }
        context.drawLayer { lit in
            lit.addFilter(.shadow(color: .black.opacity(0.6), radius: 5 * unit))
            art(lit)
        }
    }

    // MARK: - Pictures

    /// `context` with a figure's own units, where it was in points.
    static func inUnits(_ context: GraphicsContext, unit: Double) -> GraphicsContext {
        var local = context
        local.scaleBy(x: unit, y: unit)
        return local
    }

    /// A picture for a layer to carry, of the part of a figure's own space
    /// that `frame` names. `art` draws in points about the figure's middle.
    static func picture(
        of frame: CGRect, unit: Double, scale: Double, art: @escaping (GraphicsContext) -> Void
    ) -> CGImage? {
        let renderer = ImageRenderer(content: Canvas { context, _ in
            context.translateBy(x: -frame.minX * unit, y: -frame.minY * unit)
            art(context)
        }.frame(width: frame.width * unit, height: frame.height * unit))
        renderer.scale = scale
        return renderer.cgImage
    }

    /// A reindeer's body, glowing, with the lead's nose when it has one.
    static func bodyPicture(isFar: Bool, isLead: Bool, unit: Double, scale: Double) -> CGImage? {
        picture(of: SantaGeometry.bodyFrame, unit: unit, scale: scale) { context in
            drawGlowing({ drawBody(isFar: isFar, in: inUnits($0, unit: unit)) }, in: context, unit: unit)
            if isLead { drawNose(in: inUnits(context, unit: unit)) }
        }
    }

    static func sleighPicture(unit: Double, scale: Double) -> CGImage? {
        picture(of: SantaGeometry.sleighFrame, unit: unit, scale: scale) { context in
            context.drawLayer { soft in
                soft.addFilter(.blur(radius: 5 * unit))
                drawWake(in: inUnits(soft, unit: unit))
            }
            drawGlowing({ drawSleigh(in: inUnits($0, unit: unit)) }, in: context, unit: unit)
        }
    }

    /// A mote of radius 1 drawn `points` across, for a layer to stretch.
    static func motePicture(isStar: Bool, tint: Color, scale: Double) -> CGImage? {
        let reach = isStar ? SantaGeometry.starGlow : 1
        let unit = SantaGeometry.motePictureRadius
        return picture(
            of: CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2), unit: unit, scale: scale
        ) { context in
            drawMote(isStar: isStar, tint: tint, opacity: 1, in: inUnits(context, unit: unit))
        }
    }
}
