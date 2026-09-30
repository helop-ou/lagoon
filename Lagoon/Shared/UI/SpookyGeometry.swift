import SwiftUI

/// The spooky theme's ghost: a dome over a scalloped hem, with two eyes and a
/// small round mouth cut out, so it reads over any backdrop with an even-odd
/// fill. Drawn in a rect five units wide and six tall.
nonisolated enum GhostGeometry {
    /// Width to height.
    static let aspect: Double = 5.0 / 6.0

    /// `wave` moves the hem, in radians; animate it for a ghost that floats.
    static func path(in rect: CGRect, wave: Double = 0) -> Path {
        let w = rect.width, h = rect.height
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        // Dome and sides.
        path.move(to: point(0, 0.42))
        path.addArc(
            center: point(0.5, 0.42), radius: w / 2,
            startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: point(1, 0.9))
        // Hem: three scallops, right to left, swaying with `wave`.
        let scallops = 3
        for index in 0..<scallops {
            let right = 1 - Double(index) / Double(scallops)
            let left = 1 - Double(index + 1) / Double(scallops)
            let middle = (right + left) / 2
            let dip = 0.9 + 0.08 + 0.03 * sin(wave + Double(index) * 1.7)
            path.addQuadCurve(to: point(left, 0.9), control: point(middle, dip + 0.04))
        }
        path.addLine(to: point(0, 0.42))
        path.closeSubpath()
        // Features, cut out by the even-odd fill.
        path.addEllipse(in: CGRect(origin: point(0.24, 0.3), size: CGSize(width: w * 0.16, height: h * 0.2)))
        path.addEllipse(in: CGRect(origin: point(0.6, 0.3), size: CGSize(width: w * 0.16, height: h * 0.2)))
        path.addEllipse(in: CGRect(origin: point(0.44, 0.58), size: CGSize(width: w * 0.12, height: h * 0.11)))
        return path
    }

    static let fillStyle = FillStyle(eoFill: true)
}

/// A cobweb in the top-left corner of a square: a hub set out from the
/// corner, radials running to a frame thread tied to both screen edges (or
/// tying off on an edge themselves), and a capture spiral that follows the
/// frame and droops between radials, with a few strands broken. `seed` makes
/// each corner's web its own.
nonisolated enum CobwebGeometry {
    struct Web {
        let threads: Path
        let spiral: Path
        /// The hub, where the web is brightest.
        let hub: CGPoint
        /// Where the steepest radial pointing down and out meets the frame.
        let steep: CGPoint

        /// A point `share` of the way down the steepest radial, for a spider
        /// to sit on or hang from, clear of controls near the corner.
        func onSteepRadial(_ share: Double) -> CGPoint { hub.mix(steep, share) }
    }

    static func web(size: Double, seed: UInt64) -> Web {
        var random = SeededGenerator(seed: seed)
        func jitter(_ range: ClosedRange<Double>) -> Double { .random(in: range, using: &random) }
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * size, y: y * size) }

        // The frame: tied to the top edge, down to a low corner, back to the
        // side edge.
        let top = point(jitter(0.88...0.98), 0)
        let low = point(jitter(0.58...0.68), jitter(0.52...0.62))
        let side = point(0, jitter(0.86...0.96))
        let hub = point(jitter(0.22...0.27), jitter(0.19...0.24))
        let boundary: [(CGPoint, CGPoint)] = [(.zero, top), (top, low), (low, side), (side, .zero)]

        let count = 12
        let offset = jitter(0...30)
        let ends: [CGPoint] = (0..<count).map { index in
            let degrees = offset + 360 * Double(index) / Double(count) + jitter(-8...8)
            let direction = CGVector(dx: cos(degrees * .pi / 180), dy: sin(degrees * .pi / 180))
            return boundary.compactMap { hit(from: hub, direction, $0.0, $0.1) }.min { hub.distance(to: $0) < hub.distance(to: $1) } ?? hub
        }

        var threads = Path()
        threads.move(to: top)
        threads.addLine(to: low)
        threads.addLine(to: side)
        for end in ends {
            threads.move(to: hub)
            threads.addLine(to: end)
        }

        var spiral = Path()
        var ring = 0.14
        while ring < 0.94 {
            for index in 0..<count {
                let next = (index + 1) % count
                guard jitter(0...1) > 0.08 else { continue }
                let near = hub.mix(ends[index], ring * jitter(0.97...1.03))
                let far = hub.mix(ends[next], ring * jitter(0.97...1.03))
                let length = near.distance(to: far)
                // Where two radials run close, a ring would be a smudge.
                guard length > size * 0.02 else { continue }
                spiral.move(to: near)
                spiral.addQuadCurve(to: far, control: near.mix(far, 0.5).moved(by: 0, length * jitter(0.08...0.2)))
            }
            ring += 0.05 + ring * 0.12
        }

        let steep = ends.max { ($0.y - hub.y) - abs($0.x - hub.x) < ($1.y - hub.y) - abs($1.x - hub.x) } ?? low
        return Web(threads: threads, spiral: spiral, hub: hub, steep: steep)
    }

    /// Where a ray from `origin` first meets the segment `a`–`b`.
    private static func hit(from origin: CGPoint, _ direction: CGVector, _ a: CGPoint, _ b: CGPoint) -> CGPoint? {
        let edge = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let denominator = direction.dx * edge.dy - direction.dy * edge.dx
        guard abs(denominator) > 1e-9 else { return nil }
        let t = ((a.x - origin.x) * edge.dy - (a.y - origin.y) * edge.dx) / denominator
        let u = ((a.x - origin.x) * direction.dy - (a.y - origin.y) * direction.dx) / denominator
        guard t > 0, (0...1).contains(u) else { return nil }
        return CGPoint(x: origin.x + direction.dx * t, y: origin.y + direction.dy * t)
    }
}

/// A spider seen from above, head up: a small head with palps, a round
/// abdomen, and four jointed legs a side, the front pairs reaching forward and
/// the back pairs trailing. Drawn about the head, in units of `size`; it
/// spans about 1.25 across and 1.15 from palps to feet.
nonisolated enum SpiderGeometry {
    static func body(at center: CGPoint, size: Double) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - size * 0.12, y: center.y - size * 0.13, width: size * 0.24, height: size * 0.26))
        // Abdomen: round in front, drawn to a blunt point behind.
        let front = center.moved(by: 0, size * 0.1)
        let back = center.moved(by: 0, size * 0.56)
        path.move(to: front)
        path.addCurve(to: back, control1: front.moved(by: size * 0.27, 0), control2: back.moved(by: size * 0.14, -size * 0.1))
        path.addCurve(to: front, control1: back.moved(by: -size * 0.14, -size * 0.1), control2: front.moved(by: -size * 0.27, 0))
        path.closeSubpath()
        return path
    }

    static func legs(at center: CGPoint, size: Double) -> Path {
        // Each pair's hip, and its femur, tibia and tarsus angles in degrees
        // below the horizontal.
        let joints: [(hip: Double, femur: Double, tibia: Double, tarsus: Double)] = [
            (-0.07, -40, -72, -95), (-0.025, -18, -36, -50), (0.025, 12, 38, 55), (0.07, 34, 70, 88),
        ]
        var path = Path()
        for side in [-1.0, 1.0] {
            for joint in joints {
                let hip = CGPoint(x: center.x + side * size * 0.08, y: center.y + size * joint.hip)
                let knee = hip.moved(by: side * size * 0.3 * cos(joint.femur * .pi / 180), size * 0.3 * sin(joint.femur * .pi / 180))
                let ankle = knee.moved(by: side * size * 0.24 * cos(joint.tibia * .pi / 180), size * 0.24 * sin(joint.tibia * .pi / 180))
                let foot = ankle.moved(by: side * size * 0.1 * cos(joint.tarsus * .pi / 180), size * 0.1 * sin(joint.tarsus * .pi / 180))
                path.move(to: hip)
                path.addLine(to: knee)
                path.addLine(to: ankle)
                path.addLine(to: foot)
            }
            // Palps.
            path.move(to: center.moved(by: side * size * 0.04, -size * 0.11))
            path.addLine(to: center.moved(by: side * size * 0.07, -size * 0.2))
        }
        return path
    }

    /// An hourglass on the abdomen, for the accent.
    static func marking(at center: CGPoint, size: Double) -> Path {
        let middle = center.moved(by: 0, size * 0.3)
        var path = Path()
        path.move(to: middle.moved(by: -size * 0.05, -size * 0.08))
        path.addLine(to: middle.moved(by: size * 0.05, -size * 0.08))
        path.addLine(to: middle)
        path.closeSubpath()
        path.move(to: middle.moved(by: -size * 0.05, size * 0.08))
        path.addLine(to: middle.moved(by: size * 0.05, size * 0.08))
        path.addLine(to: middle)
        path.closeSubpath()
        return path
    }
}

/// How far a hanging spider has let itself down, from 0 (tucked under its
/// web) to 1, through one cycle of `period`: a rest, a slow descent, a pause
/// at the bottom, and a climb back up.
nonisolated enum SpiderDrop {
    static func reach(at time: TimeInterval, period: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let t = phase < 0 ? phase + 1 : phase
        switch t {
        case ..<0.25: return 0
        case ..<0.5: return smooth((t - 0.25) / 0.25)
        case ..<0.65: return 1
        case ..<0.95: return 1 - smooth((t - 0.65) / 0.3)
        default: return 0
        }
    }

    /// A slow sway on the thread, in radians, wider the further down it is.
    static func sway(at time: TimeInterval, reach: Double) -> Double {
        0.02 + 0.05 * reach * sin(time * 2 * .pi / 3.4)
    }

    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

/// Ghosts crossing a haunted page's background now and then: one every few
/// minutes, more often after dark, and a little flock on Halloween night.
nonisolated enum GhostFlight {
    struct Ghost: Equatable {
        /// Height of the flight path, as a share of the page.
        let lane: Double
        let leftward: Bool
        /// Seconds after the flight sets off that this ghost appears.
        let start: TimeInterval
        let scale: Double
        /// Offsets the bob and the hem, so a flock does not move in step.
        let phase: Double
    }

    struct Plan: Equatable {
        /// Seconds to wait before setting off.
        let wait: TimeInterval
        let ghosts: [Ghost]
    }

    struct Pose {
        let center: CGPoint
        let tilt: Double
        let opacity: Double
    }

    static let dayWait: ClosedRange<TimeInterval> = 120...240
    static let nightWait: ClosedRange<TimeInterval> = 60...150
    static let halloweenWait: ClosedRange<TimeInterval> = 45...90

    /// From 19:00 to 06:00 on the viewer's clock.
    static func isAfterDark(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 19 || hour < 6
    }

    /// From 17:00 on 31 October until morning.
    static func isHalloweenNight(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day, .hour], from: date)
        guard let month = parts.month, let day = parts.day, let hour = parts.hour else { return false }
        return (month == 10 && day == 31 && hour >= 17) || (month == 11 && day == 1 && hour < 6)
    }

    static func plan(at date: Date, calendar: Calendar, using random: inout some RandomNumberGenerator) -> Plan {
        let halloween = isHalloweenNight(date, calendar: calendar)
        let wait = halloween ? halloweenWait : isAfterDark(date, calendar: calendar) ? nightWait : dayWait
        let leftward = Bool.random(using: &random)
        // Mostly high on the page, where a Home hero leaves the backdrop open.
        let lane = Double.random(in: 0.06...0.5, using: &random)
        var ghosts = [Ghost(lane: lane, leftward: leftward, start: 0, scale: 1, phase: .random(in: 0...6, using: &random))]
        if halloween {
            // Two smaller ones trailing the first, above and below its path.
            for (index, scale) in [0.78, 0.62].enumerated() {
                let side: Double = index == 0 ? -1 : 1
                ghosts.append(Ghost(
                    lane: max(0.04, lane + side * .random(in: 0.07...0.12, using: &random)),
                    leftward: leftward,
                    start: Double(index + 1) * .random(in: 1.2...2, using: &random),
                    scale: scale,
                    phase: .random(in: 0...6, using: &random)
                ))
            }
        }
        return Plan(wait: .random(in: wait, using: &random), ghosts: ghosts)
    }

    /// How long a plan's flight lasts once it sets off.
    static func duration(of plan: Plan, crossing: TimeInterval) -> TimeInterval {
        (plan.ghosts.map(\.start).max() ?? 0) + crossing
    }

    /// Where `ghost` is, `elapsed` seconds into the flight, on a page `size`
    /// for a ghost `height` tall; nil before it sets off and after it leaves.
    /// It enters and leaves wholly off the page, bobbing and rising a little.
    static func pose(of ghost: Ghost, elapsed: TimeInterval, crossing: TimeInterval, in size: CGSize, height: Double) -> Pose? {
        let progress = (elapsed - ghost.start) / crossing
        guard (0...1).contains(progress) else { return nil }
        let half = height * ghost.scale * 0.6
        let travel = ghost.leftward ? 1 - progress : progress
        let x = -half + travel * (size.width + 2 * half)
        let bob = sin(progress * 4 * .pi + ghost.phase)
        let y = (ghost.lane - 0.06 * progress) * size.height + bob * 0.03 * size.height
        let lean = ghost.leftward ? -0.12 : 0.12
        let fade = min(1, progress / 0.08, (1 - progress) / 0.08)
        return Pose(center: CGPoint(x: x, y: y), tilt: lean + 0.08 * cos(progress * 4 * .pi + ghost.phase), opacity: fade)
    }
}

private extension CGPoint {
    nonisolated func mix(_ other: CGPoint, _ amount: Double) -> CGPoint {
        CGPoint(x: x + (other.x - x) * amount, y: y + (other.y - y) * amount)
    }
    nonisolated func moved(by dx: Double, _ dy: Double) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
    nonisolated func distance(to other: CGPoint) -> Double { hypot(other.x - x, other.y - y) }
}
