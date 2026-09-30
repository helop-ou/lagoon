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

/// A corner cobweb: threads fanning from the top-left corner of a square,
/// joined by rings that sag toward it. Mirror it for the top-right corner.
nonisolated enum CobwebGeometry {
    /// Angles of the threads from the top edge toward the left edge. None
    /// lies on an edge, where it would read as a border.
    private static let threadAngles: [Double] = [7, 26, 45, 64, 83]
    /// Where the rings cross each thread, as shares of the web's size.
    private static let ringRadii: [Double] = [0.2, 0.38, 0.56, 0.74]
    /// How far each ring segment sags toward the corner.
    private static let sag = 0.14

    static func path(size: Double) -> Path {
        func point(angle: Double, radius: Double) -> CGPoint {
            let radians = angle * .pi / 180
            return CGPoint(x: cos(radians) * radius * size, y: sin(radians) * radius * size)
        }
        var path = Path()
        for (index, angle) in threadAngles.enumerated() {
            // Outer threads run the full size, inner ones a little short.
            let length = index == 0 || index == threadAngles.count - 1 ? 1.0 : 0.9
            path.move(to: .zero)
            path.addLine(to: point(angle: angle, radius: length))
        }
        for radius in ringRadii {
            for (from, to) in zip(threadAngles, threadAngles.dropFirst()) {
                let start = point(angle: from, radius: radius)
                let end = point(angle: to, radius: radius)
                let middle = point(angle: (from + to) / 2, radius: radius * (1 - sag))
                path.move(to: start)
                path.addQuadCurve(to: end, control: middle)
            }
        }
        return path
    }
}
