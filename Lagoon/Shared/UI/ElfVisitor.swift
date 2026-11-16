import SwiftUI

/// An elf coming down a rope at the side of a snowy page now and then, on
/// `ElfVisit`'s schedule, while the elves are about. Its layers exist only
/// while one is on the page. A page left before the wait is over never
/// shows one, and nothing comes under Reduce Motion or while the player is
/// up.
struct ElfVisitor: View {
    let isStill: Bool
    @State private var plan: ElfVisit.Plan?
    @State private var arrived = Date.distantPast

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let plan, !isStill {
                ElfVisitLayers(depth: plan.depth, isMirrored: !plan.onLeading, arrived: arrived)
                    .frame(width: ElfFrame.size.width, height: ElfFrame.size.height)
                // Beside the content, where a page leaves its backdrop open.
                .padding(.horizontal, Metrics.elfSize * (0.04 + 0.16 * plan.lane))
                .frame(maxWidth: .infinity, alignment: plan.onLeading ? .topLeading : .topTrailing)
            }
        }
        .task(id: isStill) {
            plan = nil
            guard !isStill else { return }
            var random = SystemRandomNumberGenerator()
            var isFirst = true
            while !Task.isCancelled {
                guard var next = Self.nextVisit(isFirst: isFirst, using: &random) else { return }
                do {
                    try await Task.sleep(for: .seconds(next.wait))
                    arrived = .now
                    next = ElfVisit.Plan(wait: 0, onLeading: next.onLeading, lane: next.lane, depth: next.depth)
                    plan = next
                    try await Task.sleep(for: .seconds(ElfVisit.duration))
                    plan = nil
                } catch {
                    return
                }
                isFirst = false
            }
        }
    }

    /// Nil when no elves are about.
    private static func nextVisit(isFirst: Bool, using random: inout some RandomNumberGenerator) -> ElfVisit.Plan? {
        let planned = ElfVisit.plan(isFirst: isFirst, using: &random)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.elfVisit") {
            return ElfVisit.Plan(
                wait: isFirst ? 3 : 5, onLeading: planned.onLeading, lane: planned.lane, depth: planned.depth
            )
        }
        #endif
        return ElfVisit.isSeason(on: .now) ? planned : nil
    }
}

/// The elf at one moment, on its rope from the top of the page, drawn once:
/// the picture the moving layers are checked against.
struct ElfFrame: View {
    let pose: ElfVisit.Pose
    /// How far down it comes, as a share of the longest rope.
    let depth: Double
    /// Turned to face the other way, so it waves toward the page.
    var isMirrored = false

    static var size: CGSize {
        CGSize(width: Metrics.elfSize * 1.16, height: Metrics.elfDrop + Metrics.elfSize * 1.45)
    }

    var body: some View {
        Canvas { context, size in
            let unit = ElfVisit.unit
            let grip = ElfVisit.grip(of: pose, depth: depth)
            let knot = ElfVisit.knot
            // The rope swings from its knot, and the elf with it.
            context.translateBy(x: size.width / 2, y: knot)
            context.rotate(by: .radians(ElfVisit.lean(of: pose, depth: depth)))
            context.translateBy(x: 0, y: grip - knot)
            if isMirrored { context.scaleBy(x: -1, y: 1) }
            context.scaleBy(x: unit, y: unit)
            ElfArt.drawRope(from: (knot - grip) / unit, in: context)
            for side in [-1.0, 1.0] {
                var leg = context
                let hip = ElfGeometry.restingLeg(side: side).hip
                leg.translateBy(x: hip.x, y: hip.y)
                leg.rotate(by: .radians(ElfGeometry.legTurn(side: side, kick: pose.kick)))
                leg.translateBy(x: -hip.x, y: -hip.y)
                ElfArt.drawLeg(side: side, in: leg)
            }
            ElfArt.drawBody(in: context, unit: unit)
            ElfArt.drawFreeArm(raise: pose.raise, wave: pose.wave, in: context)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// How the elf is painted, in its own units about its upper hand. The still
/// picture draws with these, and the moving layers take their pictures from
/// them, so the two cannot drift apart.
enum ElfArt {
    static let rope = Color(red: 0xDD / 255, green: 0xB8 / 255, blue: 0x72 / 255)
    private static let twist = Color(red: 0x8A / 255, green: 0x62 / 255, blue: 0x2A / 255)
    static let tunic = Color(red: 0x2F / 255, green: 0xA0 / 255, blue: 0x5E / 255)
    private static let tunicShade = Color(red: 0x1E / 255, green: 0x74 / 255, blue: 0x45 / 255)
    private static let shoe = Color(red: 0x17 / 255, green: 0x5A / 255, blue: 0x38 / 255)
    private static let leather = Color(red: 0x3A / 255, green: 0x24 / 255, blue: 0x18 / 255)
    private static let cheek = Color(red: 0xF2 / 255, green: 0x7E / 255, blue: 0x86 / 255)

    static let ropeLine: Double = 3

    /// The rope from `top`, above the elf, to its loose end below.
    static func drawRope(from top: Double, in context: GraphicsContext) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: top))
        line.addLine(to: CGPoint(x: 0, y: ElfGeometry.ropeTail))
        context.stroke(line, with: .color(rope), style: StrokeStyle(lineWidth: ropeLine, lineCap: .round))
        context.stroke(
            line, with: .color(twist.opacity(0.55)),
            style: StrokeStyle(lineWidth: ropeLine, lineCap: .butt, dash: [1.6, 3.4])
        )
        context.fill(
            Path(ellipseIn: CGRect(x: -3, y: ElfGeometry.ropeTail - 3, width: 6, height: 6)), with: .color(rope)
        )
    }

    /// A leg hanging straight, with its shoe and the bell on its toe.
    static func drawLeg(side: Double, in context: GraphicsContext) {
        let leg = ElfGeometry.restingLeg(side: side)
        var limb = Path()
        limb.move(to: leg.hip)
        limb.addLine(to: leg.knee)
        limb.addLine(to: leg.ankle)
        context.stroke(
            limb, with: .color(ChristmasInk.red),
            style: StrokeStyle(lineWidth: ElfGeometry.legLine, lineCap: .round, lineJoin: .round)
        )
        context.fill(ElfGeometry.shoe(of: leg, side: side), with: .color(shoe))
        context.fill(
            Path(ellipseIn: CGRect(x: leg.toe.x + side * 2 - 2.3, y: leg.toe.y - 7.3, width: 4.6, height: 4.6)),
            with: .color(ChristmasInk.gold)
        )
    }

    /// Everything that holds its shape: the arm on the rope, tunic, head and
    /// cap, over a soft shadow. `unit` is points to one of its units.
    static func drawBody(in context: GraphicsContext, unit: Double) {
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 2.5 * unit))
            drawBodyParts(in: layer)
        }
    }

    private static func drawBodyParts(in context: GraphicsContext) {
        let red = ChristmasInk.red
        let skin = ChristmasInk.skin
        context.stroke(
            ElfGeometry.holdingArm, with: .color(tunicShade),
            style: StrokeStyle(lineWidth: ElfGeometry.armLine, lineCap: .round)
        )
        context.fill(
            ElfGeometry.tunic,
            with: .linearGradient(
                Gradient(colors: [tunic, tunicShade]),
                startPoint: CGPoint(x: 0, y: 56), endPoint: CGPoint(x: 0, y: 94)
            )
        )
        context.stroke(
            ElfGeometry.belt, with: .color(leather),
            style: StrokeStyle(lineWidth: ElfGeometry.beltLine, lineCap: .butt)
        )
        context.fill(Path(roundedRect: ElfGeometry.buckle, cornerRadius: 1.4), with: .color(ChristmasInk.gold))
        context.fill(ElfGeometry.collar, with: .color(red))
        context.fill(ElfGeometry.ears, with: .color(skin))
        context.fill(ElfGeometry.head, with: .color(skin))
        context.fill(ElfGeometry.cheeks, with: .color(cheek.opacity(0.75)))
        context.fill(ElfGeometry.eyes, with: .color(leather))
        context.stroke(
            ElfGeometry.smile, with: .color(leather), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
        context.fill(ElfGeometry.cap, with: .color(red))
        context.stroke(
            ElfGeometry.band, with: .color(.white),
            style: StrokeStyle(lineWidth: ElfGeometry.bandLine, lineCap: .round)
        )
        context.fill(ElfGeometry.bobble, with: .color(.white))
        drawHand(at: ElfGeometry.lowerHand, in: context)
    }

    /// The arm that waves, and its hand, over the rope.
    static func drawFreeArm(raise: Double, wave: Double, in context: GraphicsContext) {
        context.stroke(
            ElfGeometry.freeArm(raise: raise, wave: wave), with: .color(tunic),
            style: StrokeStyle(lineWidth: ElfGeometry.armLine, lineCap: .round)
        )
        drawHand(at: ElfGeometry.freeHand(raise: raise, wave: wave), in: context)
    }

    private static func drawHand(at hand: CGPoint, in context: GraphicsContext) {
        let radius = ElfGeometry.handRadius
        context.fill(
            Path(ellipseIn: CGRect(x: hand.x - radius, y: hand.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(ChristmasInk.skin)
        )
    }

    // MARK: - Pictures

    /// A picture for a layer to carry, of the part of the elf's own space
    /// that `frame` names, at `unit` points to one of its units.
    static func picture(
        of frame: CGRect, unit: Double, scale: Double, art: @escaping (GraphicsContext) -> Void
    ) -> CGImage? {
        let renderer = ImageRenderer(content: Canvas { context, _ in
            context.translateBy(x: -frame.minX * unit, y: -frame.minY * unit)
            context.scaleBy(x: unit, y: unit)
            art(context)
        }.frame(width: frame.width * unit, height: frame.height * unit))
        renderer.scale = scale
        return renderer.cgImage
    }
}
