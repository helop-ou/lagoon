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

/// A corner cobweb, fanning from the top-left corner of a square: uneven
/// threads, and a capture spiral whose rings widen outward and sag toward the
/// corner, with a few broken. `seed` makes each corner's web its own.
nonisolated enum CobwebGeometry {
    struct Web {
        let threads: Path
        let spiral: Path
        /// A point on the web, for a spider to sit on or hang from.
        let perch: CGPoint
    }

    static func web(size: Double, seed: UInt64) -> Web {
        var random = SeededGenerator(seed: seed)
        let count = 9
        // Kept off the screen edges, where a thread reads as a border.
        let angles = (0..<count).map { index in
            6 + 78 * Double(index) / Double(count - 1) + .random(in: -3...3, using: &random)
        }
        let lengths = angles.map { _ in Double.random(in: 0.75...1, using: &random) }
        func point(_ angle: Double, _ radius: Double) -> CGPoint {
            let radians = angle * .pi / 180
            return CGPoint(x: cos(radians) * radius * size, y: sin(radians) * radius * size)
        }

        var threads = Path()
        for (angle, length) in zip(angles, lengths) {
            threads.move(to: .zero)
            threads.addLine(to: point(angle, length))
        }
        var spiral = Path()
        var radius = 0.08
        while radius < 0.95 {
            for index in 0..<(count - 1) {
                let near = radius * .random(in: 0.96...1.04, using: &random)
                let far = radius * .random(in: 0.96...1.04, using: &random)
                let broken = Double.random(in: 0...1, using: &random) < 0.07
                guard !broken, near < lengths[index], far < lengths[index + 1] else { continue }
                let sag = Double.random(in: 0.04...0.13, using: &random)
                spiral.move(to: point(angles[index], near))
                spiral.addQuadCurve(
                    to: point(angles[index + 1], far),
                    control: point((angles[index] + angles[index + 1]) / 2, (near + far) / 2 * (1 - sag))
                )
            }
            radius += 0.04 + radius * 0.1
        }
        // Low on a steep thread: out of the way of controls near the corner.
        return Web(threads: threads, spiral: spiral, perch: point(angles[count - 2], 0.55))
    }
}

/// A small spider: a round abdomen, a head, and four bent legs a side, drawn
/// about `center` in a box `size` across.
nonisolated enum SpiderGeometry {
    static func body(at center: CGPoint, size: Double) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - size * 0.22, y: center.y - size * 0.05, width: size * 0.44, height: size * 0.52))
        path.addEllipse(in: CGRect(x: center.x - size * 0.14, y: center.y - size * 0.3, width: size * 0.28, height: size * 0.28))
        return path
    }

    static func legs(at center: CGPoint, size: Double) -> Path {
        var path = Path()
        for side in [-1.0, 1.0] {
            for index in 0..<4 {
                let row = Double(index)
                let hip = CGPoint(x: center.x + side * size * 0.1, y: center.y - size * (0.12 - row * 0.07))
                let knee = CGPoint(x: center.x + side * size * (0.38 + row * 0.03), y: hip.y - size * (0.2 - row * 0.1))
                let foot = CGPoint(x: center.x + side * size * (0.5 + row * 0.02), y: hip.y + size * (0.12 + row * 0.1))
                path.move(to: hip)
                path.addLine(to: knee)
                path.addLine(to: foot)
            }
        }
        return path
    }
}
