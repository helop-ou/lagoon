import SwiftUI

/// The colours the Christmas figures are drawn in, shared so the sleigh's
/// driver and a visiting elf wear the same red.
nonisolated enum ChristmasInk {
    static let gold = Color(red: 1, green: 0xD7 / 255, blue: 0x78 / 255)
    static let paleGold = Color(red: 1, green: 0xF6 / 255, blue: 0xD6 / 255)
    static let deepGold = Color(red: 0xF0 / 255, green: 0xA6 / 255, blue: 0x30 / 255)
    /// Gold in shadow: the far reindeer of a pair.
    static let shade = Color(red: 0xB4 / 255, green: 0x76 / 255, blue: 0x22 / 255)
    static let red = Color(red: 0xDE / 255, green: 0x2F / 255, blue: 0x3A / 255)
    static let nose = Color(red: 1, green: 0x3B / 255, blue: 0x30 / 255)
    static let skin = Color(red: 0xF6 / 255, green: 0xC9 / 255, blue: 0xA4 / 255)
    static let sack = Color(red: 0x2F / 255, green: 0x93 / 255, blue: 0x5C / 255)
}

/// The shapes of the Christmas surprise, each about its own middle, facing
/// the trailing edge, in units where a reindeer's body is 100 long.
nonisolated enum SantaGeometry {
    // MARK: - Reindeer

    /// Body, neck, head, ear and tail as one silhouette.
    static let reindeer: Path = {
        var path = Path()
        // Body: rump, back, shoulder, chest, belly, haunch.
        path.move(to: CGPoint(x: -47, y: -7))
        path.addCurve(to: CGPoint(x: 28, y: -17), control1: CGPoint(x: -28, y: -19), control2: CGPoint(x: 4, y: -13))
        path.addCurve(to: CGPoint(x: 47, y: -3), control1: CGPoint(x: 37, y: -19), control2: CGPoint(x: 47, y: -13))
        path.addCurve(to: CGPoint(x: 37, y: 14), control1: CGPoint(x: 48, y: 6), control2: CGPoint(x: 45, y: 13))
        path.addCurve(to: CGPoint(x: -28, y: 11), control1: CGPoint(x: 16, y: 21), control2: CGPoint(x: -8, y: 8))
        path.addCurve(to: CGPoint(x: -50, y: 2), control1: CGPoint(x: -40, y: 15), control2: CGPoint(x: -52, y: 11))
        path.addCurve(to: CGPoint(x: -47, y: -7), control1: CGPoint(x: -51, y: -3), control2: CGPoint(x: -50, y: -6))
        path.closeSubpath()
        // Neck and head: up the back of the neck, over the crown, down the
        // face to the nose, back along the jaw and down the throat.
        path.move(to: CGPoint(x: 22, y: -15))
        path.addCurve(to: CGPoint(x: 49, y: -47), control1: CGPoint(x: 33, y: -26), control2: CGPoint(x: 42, y: -37))
        path.addCurve(to: CGPoint(x: 67, y: -43), control1: CGPoint(x: 54, y: -51), control2: CGPoint(x: 61, y: -47))
        path.addCurve(to: CGPoint(x: 80, y: -35), control1: CGPoint(x: 72, y: -41), control2: CGPoint(x: 79, y: -39))
        path.addCurve(to: CGPoint(x: 66, y: -30), control1: CGPoint(x: 80, y: -31), control2: CGPoint(x: 72, y: -30))
        path.addCurve(to: CGPoint(x: 56, y: -24), control1: CGPoint(x: 61, y: -30), control2: CGPoint(x: 58, y: -28))
        path.addCurve(to: CGPoint(x: 46, y: 2), control1: CGPoint(x: 53, y: -16), control2: CGPoint(x: 51, y: -6))
        path.closeSubpath()
        // Ear, laid back.
        path.move(to: CGPoint(x: 49, y: -46))
        path.addQuadCurve(to: CGPoint(x: 38, y: -53), control: CGPoint(x: 42, y: -45))
        path.addQuadCurve(to: CGPoint(x: 49, y: -46), control: CGPoint(x: 46, y: -53))
        path.closeSubpath()
        // Tail, a short tuft.
        path.move(to: CGPoint(x: -47, y: -7))
        path.addQuadCurve(to: CGPoint(x: -59, y: -13), control: CGPoint(x: -55, y: -6))
        path.addQuadCurve(to: CGPoint(x: -50, y: 0), control: CGPoint(x: -57, y: -3))
        path.closeSubpath()
        return path
    }()

    /// One antler: a beam sweeping up and forward, with three tines. Stroked.
    static let antler: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 52, y: -47))
        path.addCurve(to: CGPoint(x: 57, y: -86), control1: CGPoint(x: 43, y: -58), control2: CGPoint(x: 44, y: -78))
        // Brow tine, forward over the face.
        path.move(to: CGPoint(x: 50, y: -53))
        path.addQuadCurve(to: CGPoint(x: 64, y: -62), control: CGPoint(x: 58, y: -53))
        // Back tine.
        path.move(to: CGPoint(x: 46.5, y: -65))
        path.addQuadCurve(to: CGPoint(x: 35, y: -76), control: CGPoint(x: 39, y: -67))
        // Top tine.
        path.move(to: CGPoint(x: 49, y: -77))
        path.addQuadCurve(to: CGPoint(x: 43, y: -90), control: CGPoint(x: 43, y: -82))
        return path
    }()

    /// How far the far antler sits from the near one.
    static let farAntler = CGPoint(x: 5, y: -1)
    static let antlerLine: Double = 2.7

    /// The lead reindeer's nose.
    static let nose = CGPoint(x: 79.5, y: -35)

    /// Where the traces meet a reindeer, at its shoulder.
    static let collar = CGPoint(x: 30, y: -16)

    /// A leg as its three joints.
    struct Leg: Equatable {
        let hip: CGPoint
        let knee: CGPoint
        let hoof: CGPoint
        /// The line it is drawn with, above and below the knee.
        let upper: Double
        let lower: Double
    }

    private static let stretched: [Leg] = [
        Leg(hip: CGPoint(x: 30, y: 8), knee: CGPoint(x: 52, y: 22), hoof: CGPoint(x: 77, y: 27), upper: 6, lower: 3.2),
        Leg(hip: CGPoint(x: 34, y: 8), knee: CGPoint(x: 60, y: 16), hoof: CGPoint(x: 88, y: 12), upper: 6.6, lower: 3.4),
        Leg(hip: CGPoint(x: -34, y: 6), knee: CGPoint(x: -57, y: 21), hoof: CGPoint(x: -84, y: 27), upper: 8, lower: 3.4),
        Leg(hip: CGPoint(x: -38, y: 4), knee: CGPoint(x: -65, y: 15), hoof: CGPoint(x: -95, y: 12), upper: 9, lower: 3.6),
    ]

    private static let gathered: [Leg] = [
        Leg(hip: CGPoint(x: 30, y: 8), knee: CGPoint(x: 40, y: 33), hoof: CGPoint(x: 22, y: 50), upper: 6, lower: 3.2),
        Leg(hip: CGPoint(x: 34, y: 8), knee: CGPoint(x: 47, y: 31), hoof: CGPoint(x: 30, y: 47), upper: 6.6, lower: 3.4),
        Leg(hip: CGPoint(x: -34, y: 6), knee: CGPoint(x: -24, y: 31), hoof: CGPoint(x: -2, y: 46), upper: 8, lower: 3.4),
        Leg(hip: CGPoint(x: -38, y: 4), knee: CGPoint(x: -28, y: 29), hoof: CGPoint(x: -7, y: 43), upper: 9, lower: 3.6),
    ]

    /// The harness band across a reindeer's shoulder. Stroked.
    static let harness: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 26, y: -17))
        path.addQuadCurve(to: CGPoint(x: 43, y: 9), control: CGPoint(x: 40, y: -6))
        return path
    }()

    static let harnessLine: Double = 4.4

    /// The bell hanging from the harness.
    static let bell = CGRect(x: 39.5, y: 7, width: 8, height: 8)

    /// The four legs partway through a stride: 0 stretched out, 1 gathered.
    /// Far legs first, so the near ones are drawn over them.
    static func legs(stride: Double) -> [Leg] {
        zip(stretched, gathered).map { out, under in
            Leg(
                hip: out.hip,
                knee: mix(out.knee, under.knee, stride),
                hoof: mix(out.hoof, under.hoof, stride),
                upper: out.upper,
                lower: out.lower
            )
        }
    }

    private static func mix(_ from: CGPoint, _ to: CGPoint, _ share: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share)
    }

    // MARK: - Sleigh

    /// The sleigh's body: a high curled back, a low side and a swept-up dash.
    static let sleigh: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -60, y: 27))
        path.addCurve(to: CGPoint(x: -75, y: -32), control1: CGPoint(x: -75, y: 20), control2: CGPoint(x: -84, y: -8))
        path.addCurve(to: CGPoint(x: -60, y: -38), control1: CGPoint(x: -73, y: -42), control2: CGPoint(x: -62, y: -44))
        path.addCurve(to: CGPoint(x: -64, y: -29), control1: CGPoint(x: -57, y: -33), control2: CGPoint(x: -60, y: -29))
        path.addCurve(to: CGPoint(x: -22, y: 3), control1: CGPoint(x: -59, y: -10), control2: CGPoint(x: -44, y: 1))
        path.addLine(to: CGPoint(x: 34, y: 3))
        path.addCurve(to: CGPoint(x: 62, y: -23), control1: CGPoint(x: 50, y: 3), control2: CGPoint(x: 60, y: -8))
        path.addCurve(to: CGPoint(x: 76, y: -27), control1: CGPoint(x: 63, y: -33), control2: CGPoint(x: 74, y: -35))
        path.addCurve(to: CGPoint(x: 69, y: -18), control1: CGPoint(x: 78, y: -21), control2: CGPoint(x: 73, y: -17))
        path.addCurve(to: CGPoint(x: 44, y: 27), control1: CGPoint(x: 73, y: 6), control2: CGPoint(x: 62, y: 27))
        path.closeSubpath()
        return path
    }()

    /// The runner, curling up at both ends, and the struts that carry the
    /// body on it. Stroked.
    static let runner: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -86, y: 30))
        path.addQuadCurve(to: CGPoint(x: -74, y: 42), control: CGPoint(x: -86, y: 42))
        path.addLine(to: CGPoint(x: 58, y: 42))
        path.addCurve(to: CGPoint(x: 93, y: 14), control1: CGPoint(x: 83, y: 42), control2: CGPoint(x: 97, y: 31))
        path.addCurve(to: CGPoint(x: 77, y: 5), control1: CGPoint(x: 90, y: 2), control2: CGPoint(x: 79, y: -2))
        path.addCurve(to: CGPoint(x: 82, y: 16), control1: CGPoint(x: 75, y: 11), control2: CGPoint(x: 77, y: 16))
        for strut in [-48.0, -4, 40] {
            path.move(to: CGPoint(x: strut, y: 42))
            path.addLine(to: CGPoint(x: strut, y: 26))
        }
        return path
    }()

    static let runnerLine: Double = 4.2

    /// The sack of presents behind the driver, tied at the top.
    static let sack: Path = {
        var path = Path()
        path.addEllipse(in: CGRect(x: -64, y: -56, width: 50, height: 60))
        path.move(to: CGPoint(x: -46, y: -55))
        path.addQuadCurve(to: CGPoint(x: -30, y: -66), control: CGPoint(x: -44, y: -66))
        path.addQuadCurve(to: CGPoint(x: -28, y: -53), control: CGPoint(x: -22, y: -62))
        path.closeSubpath()
        return path
    }()

    /// The driver's coat, and the cap whose tip trails behind him.
    static let suit: Path = {
        var path = Path()
        path.addEllipse(in: CGRect(x: -16, y: -35, width: 35, height: 42))
        // Cap: from the brow, a crown arcing back to the tip.
        path.move(to: CGPoint(x: -3, y: -46))
        path.addLine(to: CGPoint(x: 21, y: -49))
        path.addCurve(to: CGPoint(x: -23, y: -52), control1: CGPoint(x: 17, y: -71), control2: CGPoint(x: -9, y: -72))
        path.addCurve(to: CGPoint(x: -3, y: -46), control1: CGPoint(x: -13, y: -52), control2: CGPoint(x: -8, y: -50))
        path.closeSubpath()
        return path
    }()

    static let face = Path(ellipseIn: CGRect(x: -1, y: -53, width: 22, height: 22))

    static let eye = Path(ellipseIn: CGRect(x: 12.4, y: -45.2, width: 2.8, height: 2.8))

    /// Beard, the cap's bobble and the cuff at the driver's hand.
    static let fur: Path = {
        var path = Path()
        // The beard hangs from the cheek, under the nose, to the chest.
        path.move(to: CGPoint(x: 0, y: -41))
        path.addCurve(to: CGPoint(x: 15, y: -15), control1: CGPoint(x: -2, y: -26), control2: CGPoint(x: 6, y: -15))
        path.addCurve(to: CGPoint(x: 24, y: -40), control1: CGPoint(x: 25, y: -15), control2: CGPoint(x: 28, y: -30))
        path.addQuadCurve(to: CGPoint(x: 0, y: -41), control: CGPoint(x: 12, y: -34))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: -30, y: -57, width: 10, height: 10))
        path.addEllipse(in: CGRect(x: hand.x - 5, y: hand.y - 5, width: 10, height: 10))
        return path
    }()

    /// The cap's fur band across the brow. Stroked.
    static let brim: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -2, y: -47))
        path.addLine(to: CGPoint(x: 21, y: -50))
        return path
    }()

    static let brimLine: Double = 6

    /// The driver's arm, out to the reins. Stroked.
    static let arm: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 8, y: -22))
        path.addQuadCurve(to: hand, control: CGPoint(x: 22, y: -8))
        return path
    }()

    static let armLine: Double = 8

    /// Where the reins leave the driver's hand.
    static let hand = CGPoint(x: 38, y: -15)

    // MARK: - Dust

    /// A four-pointed star of radius 1 about the origin.
    static let star: Path = {
        var path = Path()
        let waist = 0.16
        path.move(to: CGPoint(x: 0, y: -1))
        path.addLine(to: CGPoint(x: waist, y: -waist))
        path.addLine(to: CGPoint(x: 1, y: 0))
        path.addLine(to: CGPoint(x: waist, y: waist))
        path.addLine(to: CGPoint(x: 0, y: 1))
        path.addLine(to: CGPoint(x: -waist, y: waist))
        path.addLine(to: CGPoint(x: -1, y: 0))
        path.addLine(to: CGPoint(x: -waist, y: -waist))
        path.closeSubpath()
        return path
    }()
}
