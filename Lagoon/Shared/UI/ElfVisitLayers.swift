import SwiftUI

/// The elf's visit in motion, as Core Animation layers: a picture for its
/// body, one for each leg and one for the rope, moved by the render server,
/// so the app does nothing while it is on the page. Drawn in a canvas thirty
/// times a second it took 15 % of a processor core on the Apple TV.
struct ElfVisitLayers: UIViewRepresentable {
    /// How far down it comes, as a share of the longest rope.
    let depth: Double
    /// Turned to face the other way, so it waves toward the page.
    let isMirrored: Bool
    let arrived: Date

    func makeUIView(context: Context) -> ElfVisitLayerView {
        ElfVisitLayerView(depth: depth, isMirrored: isMirrored, arrived: arrived)
    }

    func updateUIView(_ view: ElfVisitLayerView, context: Context) {}
}

final class ElfVisitLayerView: TimedLayerView {
    let depth: Double
    let isMirrored: Bool

    /// The rope from its knot, which leans, and the elf on it, which slides.
    private(set) var ropeLayer: CALayer?
    private(set) var elfLayer: CALayer?
    private(set) var legLayers: [CALayer] = []
    private(set) var armLayer: CAShapeLayer?
    private(set) var handLayer: CALayer?

    /// How often the visit is sampled. The render server draws the frames
    /// between.
    static let samplesPerSecond: Double = 30

    static let leanKey = "lean"
    static let slideKey = "slide"
    static let kickKey = "kick"
    static let waveKey = "wave"

    init(depth: Double, isMirrored: Bool, arrived: Date) {
        self.depth = depth
        self.isMirrored = isMirrored
        super.init(startedAt: arrived)
    }

    /// Every moment the visit is worked out for, and the elf at each.
    static var samples: [(time: Double, pose: ElfVisit.Pose)] {
        let count = Int((ElfVisit.duration * samplesPerSecond).rounded())
        return (0...count).compactMap { step in
            // Just inside the visit at its far end.
            let time = min(Double(step) / Double(count) * ElfVisit.duration, ElfVisit.duration - 0.0001)
            return ElfVisit.pose(at: time).map { (time, $0) }
        }
    }

    override func forgetLayers() {
        ropeLayer = nil
        elfLayer = nil
        legLayers = []
        armLayer = nil
        handLayer = nil
    }

    /// The visit, set going from `began`. Outside it the elf rests out of
    /// sight above the page.
    override func addLayers() {
        let unit = ElfVisit.unit
        let scale = max(1, traitCollection.displayScale)
        let samples = Self.samples
        guard let rest = ElfVisit.pose(at: 0) else { return }

        // The rope hangs from its knot and leans to carry the elf's sway.
        let rope = CALayer()
        rope.position = CGPoint(x: bounds.width / 2, y: ElfVisit.knot)
        animate(rope, "transform.rotation.z", samples.map { ElfVisit.lean(of: $0.pose, depth: depth) }, Self.leanKey)

        // The elf slides along it, in its own units.
        let elf = CALayer()
        elf.setAffineTransform(CGAffineTransform(scaleX: isMirrored ? -unit : unit, y: unit))
        elf.position = CGPoint(x: 0, y: ElfVisit.grip(of: rest, depth: depth) - ElfVisit.knot)
        animate(
            elf, "position",
            samples.map { NSValue(cgPoint: CGPoint(x: 0, y: ElfVisit.grip(of: $0.pose, depth: depth) - ElfVisit.knot)) },
            Self.slideKey
        )

        // The rope is one long picture that goes with the elf, so its upper
        // end is always above the knot.
        let above = -(Metrics.elfDrop / unit + 320)
        let ropeFrame = CGRect(x: -5, y: above, width: 10, height: ElfGeometry.ropeTail + 5 - above)
        elf.addSublayer(Self.pictureLayer(
            ElfArt.picture(of: ropeFrame, unit: unit, scale: scale) { ElfArt.drawRope(from: above + 2, in: $0) },
            frame: ropeFrame
        ))
        for side in [-1.0, 1.0] {
            let leg = Self.pictureLayer(
                ElfArt.picture(of: ElfGeometry.legFrame, unit: unit, scale: scale) { ElfArt.drawLeg(side: side, in: $0) },
                frame: ElfGeometry.legFrame
            )
            // It turns about its hip.
            let hip = ElfGeometry.restingLeg(side: side).hip
            leg.anchorPoint = CGPoint(
                x: (hip.x - ElfGeometry.legFrame.minX) / ElfGeometry.legFrame.width,
                y: (hip.y - ElfGeometry.legFrame.minY) / ElfGeometry.legFrame.height
            )
            leg.position = hip
            animate(
                leg, "transform.rotation.z",
                samples.map { ElfGeometry.legTurn(side: side, kick: $0.pose.kick) }, Self.kickKey
            )
            elf.addSublayer(leg)
            legLayers.append(leg)
        }
        elf.addSublayer(Self.pictureLayer(
            ElfArt.picture(of: ElfGeometry.bodyFrame, unit: unit, scale: scale) { ElfArt.drawBody(in: $0, unit: unit) },
            frame: ElfGeometry.bodyFrame
        ))

        // The arm that waves is a line whose far end moves, and its hand.
        let arm = CAShapeLayer()
        arm.strokeColor = UIColor(ElfArt.tunic).cgColor
        arm.fillColor = nil
        arm.lineWidth = ElfGeometry.armLine
        arm.lineCap = .round
        arm.path = ElfGeometry.freeArm(raise: rest.raise, wave: rest.wave).cgPath
        animate(
            arm, "path", samples.map { ElfGeometry.freeArm(raise: $0.pose.raise, wave: $0.pose.wave).cgPath },
            Self.waveKey
        )
        elf.addSublayer(arm)
        let hand = CALayer()
        let radius = ElfGeometry.handRadius
        hand.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        hand.cornerRadius = radius
        hand.backgroundColor = UIColor(ChristmasInk.skin).cgColor
        hand.position = ElfGeometry.freeHand(raise: rest.raise, wave: rest.wave)
        animate(
            hand, "position",
            samples.map { NSValue(cgPoint: ElfGeometry.freeHand(raise: $0.pose.raise, wave: $0.pose.wave)) },
            Self.waveKey
        )
        elf.addSublayer(hand)

        rope.addSublayer(elf)
        layer.addSublayer(rope)
        ropeLayer = rope
        elfLayer = elf
        armLayer = arm
        handLayer = hand
    }

    private func animate(_ target: CALayer, _ keyPath: String, _ values: [Any], _ key: String) {
        animate(target, keyPath, values, over: ElfVisit.duration, key: key)
    }

    /// A layer carrying a picture of part of the elf, placed in its own space.
    private static func pictureLayer(_ picture: CGImage?, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contents = picture
        return layer
    }
}
