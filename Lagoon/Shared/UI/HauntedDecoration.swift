import SwiftUI

/// A haunted page's backdrop decoration: a cobweb in each top corner, a
/// spider sitting in one and another lowering itself from the other, and now
/// and then a ghost crossing behind the content. Nothing moves under Reduce
/// Motion or while the player is up.
struct HauntedDecoration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    /// The iOS player covers the pages without removing them.
    @Environment(PlayerPresentationHub.self) private var playerHub: PlayerPresentationHub?
    #endif

    var body: some View {
        let silk = Color.white.mix(with: Theme.accent, by: 0.2)
        ZStack(alignment: .top) {
            GhostFlyby(isStill: isStill, color: Theme.palette.ghost)
            HauntedCobwebs(isStill: isStill, silk: silk, accent: Theme.accent)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isStill: Bool {
        #if os(iOS)
        reduceMotion || playerHub?.request != nil
        #else
        reduceMotion
        #endif
    }
}

/// The two corner webs, drawn once, and the hanging spider, the only part
/// that redraws.
private struct HauntedCobwebs: View {
    let isStill: Bool
    let silk: Color
    let accent: Color

    private static let left = CobwebGeometry.web(size: Metrics.cobwebSize, seed: 3)
    private static let right = CobwebGeometry.web(size: Metrics.cobwebSize, seed: 11)
    private static let hang = right.onSteepRadial(Metrics.cobwebHangerShare)
    /// The longest the hanging spider's thread gets.
    private static let drop = Metrics.cobwebSize * Metrics.cobwebDropShare

    var body: some View {
        let spider = Metrics.cobwebSpiderSize
        ZStack(alignment: .topTrailing) {
            Canvas { context, size in
                Self.draw(Self.left, in: &context, silk: silk)
                Self.drawSpider(at: Self.left.onSteepRadial(Metrics.cobwebSitterShare), in: &context, silk: silk, accent: accent)
                var mirrored = context
                mirrored.translateBy(x: size.width, y: 0)
                mirrored.scaleBy(x: -1, y: 1)
                Self.draw(Self.right, in: &mirrored, silk: silk)
            }
            HangingSpider(isStill: isStill, silk: silk, accent: accent, drop: Self.drop)
                .frame(width: spider * 2, height: Self.drop + spider * 1.2)
                // Centred under the point it hangs from, which is measured
                // from the trailing edge.
                .offset(x: spider - Self.hang.x, y: Self.hang.y)
        }
        .frame(height: max(Metrics.cobwebSize, Self.hang.y + Self.drop + spider * 1.2))
    }

    /// One web, brightest at its hub.
    private static func draw(_ web: CobwebGeometry.Web, in context: inout GraphicsContext, silk: Color) {
        let line = Metrics.cobwebLineWidth
        let fade = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [silk.opacity(0.38), silk.opacity(0.1)]),
            center: web.hub, startRadius: 0, endRadius: Metrics.cobwebSize * 0.8
        )
        context.stroke(web.threads, with: fade, style: StrokeStyle(lineWidth: line, lineCap: .round))
        context.stroke(web.spiral, with: fade, style: StrokeStyle(lineWidth: line * 0.7, lineCap: .round))
    }

    /// A spider, head at `head`, pale with the accent's hourglass. Drawn in
    /// one layer so overlapping legs do not show through each other.
    static func drawSpider(at head: CGPoint, in context: inout GraphicsContext, silk: Color, accent: Color) {
        let size = Metrics.cobwebSpiderSize
        context.drawLayer { layer in
            layer.opacity = 0.6
            layer.stroke(
                SpiderGeometry.legs(at: head, size: size),
                with: .color(silk),
                style: StrokeStyle(lineWidth: max(1, size * 0.055), lineCap: .round, lineJoin: .round)
            )
            layer.fill(SpiderGeometry.body(at: head, size: size), with: .color(silk))
            layer.fill(SpiderGeometry.marking(at: head, size: size), with: .color(accent))
        }
    }
}

/// A spider head-down on its thread, slowly letting itself down and climbing
/// back up, swaying a little as it goes.
private struct HangingSpider: View {
    let isStill: Bool
    let silk: Color
    let accent: Color
    let drop: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: isStill)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let reach = isStill ? 0.5 : SpiderDrop.reach(at: time, period: Motion.spiderDrop)
            let sway = isStill ? 0 : SpiderDrop.sway(at: time, reach: reach)
            Canvas { context, size in
                let spider = Metrics.cobwebSpiderSize
                let length = drop * (0.15 + 0.85 * reach)
                context.translateBy(x: size.width / 2, y: 0)
                context.rotate(by: .radians(sway))
                var thread = Path()
                thread.move(to: .zero)
                thread.addLine(to: CGPoint(x: 0, y: length))
                context.stroke(thread, with: .color(silk.opacity(0.3)), lineWidth: Metrics.cobwebLineWidth * 0.7)
                // Hanging from the tip of its abdomen, so head-down.
                var hanging = context
                hanging.translateBy(x: 0, y: length + spider * 0.56)
                hanging.rotate(by: .radians(.pi))
                HauntedCobwebs.drawSpider(at: .zero, in: &hanging, silk: silk, accent: accent)
            }
        }
    }
}

/// Ghosts crossing the page now and then, on `GhostFlight`'s schedule. Only
/// redraws while one is in the air; a page left before the wait is over
/// never shows one.
private struct GhostFlyby: View {
    let isStill: Bool
    let color: Color
    @State private var flight: GhostFlight.Plan?
    @State private var takeoff = Date.distantPast

    var body: some View {
        ZStack {
            Color.clear
            if let flight, !isStill {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let elapsed = timeline.date.timeIntervalSince(takeoff)
                        for ghost in flight.ghosts {
                            draw(ghost, elapsed: elapsed, in: &context, size: size)
                        }
                    }
                }
            }
        }
        .task(id: isStill) {
            flight = nil
            guard !isStill else { return }
            var random = SystemRandomNumberGenerator()
            while !Task.isCancelled {
                let plan = GhostFlight.plan(at: .now, calendar: .current, using: &random)
                do {
                    try await Task.sleep(for: .seconds(plan.wait))
                    takeoff = .now
                    flight = plan
                    try await Task.sleep(for: .seconds(GhostFlight.duration(of: plan, crossing: Motion.ghostCrossing)))
                    flight = nil
                } catch {
                    return
                }
            }
        }
    }

    private func draw(_ ghost: GhostFlight.Ghost, elapsed: TimeInterval, in context: inout GraphicsContext, size: CGSize) {
        let height = Metrics.flyingGhostSize * ghost.scale
        guard let pose = GhostFlight.pose(
            of: ghost, elapsed: elapsed, crossing: Motion.ghostCrossing, in: size, height: Metrics.flyingGhostSize
        ) else { return }
        var drifter = context
        drifter.translateBy(x: pose.center.x, y: pose.center.y)
        drifter.rotate(by: .radians(pose.tilt))
        let width = height * GhostGeometry.aspect
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let shape = GhostGeometry.path(in: rect, wave: elapsed * 3 + ghost.phase)
        drifter.opacity = pose.opacity
        // A soft glow, then the body, fading out toward its hem.
        var glow = drifter
        glow.addFilter(.blur(radius: height * 0.12))
        glow.fill(shape, with: .color(color.opacity(0.22)), style: GhostGeometry.fillStyle)
        drifter.addFilter(.blur(radius: height * 0.012))
        drifter.fill(
            shape,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.5), color.opacity(0.3), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: rect.minY),
                endPoint: CGPoint(x: 0, y: rect.maxY)
            ),
            style: GhostGeometry.fillStyle
        )
    }
}
