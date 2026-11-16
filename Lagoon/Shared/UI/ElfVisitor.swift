import SwiftUI

/// An elf coming down a rope at the side of a snowy page now and then, on
/// `ElfVisit`'s schedule, while the elves are about. Only redraws while one
/// is on the page. A page left before the wait is over never shows one, and
/// nothing comes under Reduce Motion or while the player is up.
struct ElfVisitor: View {
    let isStill: Bool
    @State private var plan: ElfVisit.Plan?
    @State private var arrived = Date.distantPast

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let plan, !isStill {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    if let pose = ElfVisit.pose(at: timeline.date.timeIntervalSince(arrived)) {
                        ElfFrame(pose: pose, depth: plan.depth, isMirrored: !plan.onLeading)
                    }
                }
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

/// The elf at one moment, on its rope from the top of the page.
struct ElfFrame: View {
    let pose: ElfVisit.Pose
    /// How far down it comes, as a share of the longest rope.
    let depth: Double
    /// Turned to face the other way, so it waves toward the page.
    var isMirrored = false

    static var size: CGSize {
        CGSize(width: Metrics.elfSize * 1.16, height: Metrics.elfDrop + Metrics.elfSize * 1.45)
    }

    private static let rope = Color(red: 0xDD / 255, green: 0xB8 / 255, blue: 0x72 / 255)
    private static let twist = Color(red: 0x8A / 255, green: 0x62 / 255, blue: 0x2A / 255)
    private static let tunic = Color(red: 0x2F / 255, green: 0xA0 / 255, blue: 0x5E / 255)
    private static let tunicShade = Color(red: 0x1E / 255, green: 0x74 / 255, blue: 0x45 / 255)
    private static let shoe = Color(red: 0x17 / 255, green: 0x5A / 255, blue: 0x38 / 255)
    private static let leather = Color(red: 0x3A / 255, green: 0x24 / 255, blue: 0x18 / 255)
    private static let cheek = Color(red: 0xF2 / 255, green: 0x7E / 255, blue: 0x86 / 255)

    var body: some View {
        Canvas { context, size in
            let unit = Metrics.elfSize / 100
            // Out of sight above the page at no reach, at the rope's end at full.
            let hidden = -(ElfGeometry.bottom + 6) * unit
            let grip = hidden + (depth * Metrics.elfDrop - hidden) * pose.reach
            // The rope is tied well above the page, and swings from there.
            let knot = -Metrics.elfSize * 1.5
            context.translateBy(x: size.width / 2, y: knot)
            context.rotate(by: .radians(-asin(pose.sway * Metrics.elfSize / max(grip - knot, Metrics.elfSize))))
            context.translateBy(x: 0, y: grip - knot)
            if isMirrored { context.scaleBy(x: -1, y: 1) }
            context.scaleBy(x: unit, y: unit)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.45), radius: 2.5 * unit))
                Self.drawRope(from: (knot - grip) / unit, in: layer)
                Self.drawElf(pose, in: layer)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private static func drawRope(from top: Double, in context: GraphicsContext) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: top))
        line.addLine(to: CGPoint(x: 0, y: ElfGeometry.ropeTail))
        context.stroke(line, with: .color(rope), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        context.stroke(
            line, with: .color(twist.opacity(0.55)),
            style: StrokeStyle(lineWidth: 3, lineCap: .butt, dash: [1.6, 3.4])
        )
        context.fill(
            Path(ellipseIn: CGRect(x: -3, y: ElfGeometry.ropeTail - 3, width: 6, height: 6)), with: .color(rope)
        )
    }

    private static func drawElf(_ pose: ElfVisit.Pose, in context: GraphicsContext) {
        let red = ChristmasInk.red
        let skin = ChristmasInk.skin
        let legStyle = StrokeStyle(lineWidth: ElfGeometry.legLine, lineCap: .round, lineJoin: .round)
        for (leg, side) in zip(ElfGeometry.legs(kick: pose.kick), [-1.0, 1.0]) {
            var limb = Path()
            limb.move(to: leg.hip)
            limb.addLine(to: leg.knee)
            limb.addLine(to: leg.ankle)
            context.stroke(limb, with: .color(red), style: legStyle)
            context.fill(ElfGeometry.shoe(of: leg, side: side), with: .color(shoe))
            context.fill(
                Path(ellipseIn: CGRect(x: leg.toe.x + side * 2 - 2.3, y: leg.toe.y - 7.3, width: 4.6, height: 4.6)),
                with: .color(ChristmasInk.gold)
            )
        }
        let sleeve = StrokeStyle(lineWidth: ElfGeometry.armLine, lineCap: .round)
        context.stroke(ElfGeometry.holdingArm, with: .color(tunicShade), style: sleeve)
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
        // The free arm and both hands, over the rope.
        context.stroke(
            ElfGeometry.freeArm(raise: pose.raise, wave: pose.wave), with: .color(tunic), style: sleeve
        )
        let radius = ElfGeometry.handRadius
        for hand in [ElfGeometry.lowerHand, ElfGeometry.freeHand(raise: pose.raise, wave: pose.wave)] {
            context.fill(
                Path(ellipseIn: CGRect(x: hand.x - radius, y: hand.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(skin)
            )
        }
    }
}
