import SwiftUI

/// The flight in motion, as Core Animation layers: a picture a figure and a
/// small layer a mote, moved by the render server, so the page keeps its
/// frame rate.
struct SantaFlightLayers: UIViewRepresentable {
    let startedAt: Date

    func makeUIView(context: Context) -> SantaFlightLayerView {
        SantaFlightLayerView(startedAt: startedAt)
    }

    func updateUIView(_ view: SantaFlightLayerView, context: Context) {}
}

final class SantaFlightLayerView: TimedLayerView {
    private(set) var memberLayers: [CALayer] = []
    private(set) var legLayers: [CAShapeLayer] = []
    private(set) var reinsLayer: CAShapeLayer?
    private(set) var moteLayers: [CALayer] = []

    /// How often the team's path is sampled. The render server draws the
    /// frames between.
    static let samplesPerSecond: Double = 30

    static let moveKey = "move"
    static let leanKey = "lean"
    static let gallopKey = "gallop"
    static let reinsKey = "reins"
    static let driftKey = "drift"

    override func forgetLayers() {
        memberLayers = []
        legLayers = []
        reinsLayer = nil
        moteLayers = []
    }

    /// The whole flight, set going from `began`.
    override func addLayers() {
        let size = bounds.size
        let unit = SantaFlight.scale(in: size)
        let start = start
        addScrim(
            strength: SantaFlight.scrim, fadeIn: SantaFlight.dimIn, fadeOut: SantaFlight.dimOut,
            over: SantaFlight.duration
        )
        addDust(size: size, unit: unit, start: start)
        addTeam(size: size, unit: unit, start: start)
    }

    // MARK: - Team

    private func addTeam(size: CGSize, unit: Double, start: CFTimeInterval) {
        let scale = traitCollection.displayScale
        let times = Self.sampleTimes
        for member in SantaFlight.team {
            let figure = CALayer()
            switch member.kind {
            case .sleigh:
                addReins(times: times, size: size, unit: unit, start: start)
                figure.addSublayer(Self.pictureLayer(
                    SantaArt.sleighPicture(unit: unit, scale: scale), frame: SantaGeometry.sleighFrame, unit: unit
                ))
            case .near, .far:
                let isFar = member.kind == .far
                addLegs(to: figure, member: member, isBeyond: true, unit: unit, start: start)
                figure.addSublayer(Self.pictureLayer(
                    SantaArt.bodyPicture(isFar: isFar, isLead: member.isLead, unit: unit, scale: scale),
                    frame: SantaGeometry.bodyFrame, unit: unit
                ))
                addLegs(to: figure, member: member, isBeyond: false, unit: unit, start: start)
                if !isFar { figure.addSublayer(Self.tackLayer(unit: unit)) }
            }
            follow(figure, member: member, times: times, size: size, start: start)
            layer.addSublayer(figure)
            memberLayers.append(figure)
        }
    }

    /// Moves a figure along the flight and leans it with the arc. It rests
    /// off the page, where the flight leaves it.
    private func follow(
        _ figure: CALayer, member: SantaFlight.Member, times: [Double], size: CGSize, start: CFTimeInterval
    ) {
        let placements = times.map { SantaFlight.placement(of: member, at: $0, in: size) }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = placements.map { NSValue(cgPoint: $0.center) }
        let lean = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        lean.values = placements.map(\.turn)
        for (animation, key) in [(move, Self.moveKey), (lean, Self.leanKey)] {
            Self.pace(animation, start: start)
            figure.add(animation, forKey: key)
        }
        if let last = placements.last {
            figure.position = last.center
            figure.setValue(last.turn, forKeyPath: "transform.rotation.z")
        }
    }

    private static func pace(_ animation: CAKeyframeAnimation, start: CFTimeInterval) {
        animation.calculationMode = .linear
        animation.duration = SantaFlight.crossing
        animation.beginTime = start
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
    }

    /// Every moment the team's path is worked out for.
    static var sampleTimes: [Double] {
        let count = Int((SantaFlight.crossing * samplesPerSecond).rounded())
        return (0...count).map { Double($0) / Double(count) * SantaFlight.crossing }
    }

    /// Two of a reindeer's legs, each in two pieces that swing between
    /// stretched out and gathered under it.
    private func addLegs(
        to figure: CALayer, member: SantaFlight.Member, isBeyond: Bool, unit: Double, start: CFTimeInterval
    ) {
        let stretched = SantaGeometry.legs(stride: 0)
        let gathered = SantaGeometry.legs(stride: 1)
        let color = UIColor(SantaArt.legColor(isFar: member.kind == .far, isBeyond: isBeyond)).cgColor
        let period = 1 / SantaFlight.gallop
        for index in isBeyond ? [0, 2] : [1, 3] {
            let out = stretched[index]
            let under = gathered[index]
            let pieces: [(from: [CGPoint], to: [CGPoint], width: Double)] = [
                ([out.hip, out.knee], [under.hip, under.knee], out.upper),
                ([out.knee, out.hoof], [under.knee, under.hoof], out.lower),
            ]
            for piece in pieces {
                let leg = CAShapeLayer()
                leg.strokeColor = color
                leg.fillColor = nil
                leg.lineWidth = piece.width * unit
                leg.lineCap = .round
                leg.path = Self.line(piece.from, unit: unit)
                let swing = CABasicAnimation(keyPath: "path")
                swing.fromValue = Self.line(piece.from, unit: unit)
                swing.toValue = Self.line(piece.to, unit: unit)
                // Out and back is one stride, eased like the stride itself.
                swing.duration = period / 2
                swing.autoreverses = true
                swing.repeatCount = .infinity
                swing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                swing.beginTime = start
                swing.timeOffset = (member.phase / (2 * .pi) * period).truncatingRemainder(dividingBy: period)
                leg.add(swing, forKey: Self.gallopKey)
                figure.addSublayer(leg)
                legLayers.append(leg)
            }
        }
    }

    private static func line(_ points: [CGPoint], unit: Double) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x * unit, y: $0.y * unit) })
        return path
    }

    private static func tackLayer(unit: Double) -> CALayer {
        let tack = CALayer()
        let harness = CAShapeLayer()
        harness.path = SantaGeometry.harness.cgPath
        harness.strokeColor = UIColor(ChristmasInk.red).cgColor
        harness.fillColor = nil
        harness.lineWidth = SantaGeometry.harnessLine
        harness.lineCap = .round
        let bell = CAShapeLayer()
        bell.path = CGPath(ellipseIn: SantaGeometry.bell, transform: nil)
        bell.fillColor = UIColor(ChristmasInk.paleGold).cgColor
        tack.addSublayer(harness)
        tack.addSublayer(bell)
        tack.setAffineTransform(CGAffineTransform(scaleX: unit, y: unit))
        return tack
    }

    /// A layer carrying a figure's picture, placed about the figure's middle.
    private static func pictureLayer(_ picture: CGImage?, frame: CGRect, unit: Double) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(
            x: frame.minX * unit, y: frame.minY * unit, width: frame.width * unit, height: frame.height * unit
        )
        layer.contents = picture
        return layer
    }

    private func addReins(times: [Double], size: CGSize, unit: Double, start: CFTimeInterval) {
        let reins = CAShapeLayer()
        reins.strokeColor = UIColor(ChristmasInk.gold).withAlphaComponent(SantaFlight.reinsOpacity).cgColor
        reins.fillColor = nil
        reins.lineWidth = SantaFlight.reinsLine * unit
        reins.lineCap = .round
        reins.lineJoin = .round
        let paths = times.map { SantaFlight.reins(at: $0, in: size).cgPath }
        let follow = CAKeyframeAnimation(keyPath: "path")
        follow.values = paths
        Self.pace(follow, start: start)
        reins.path = paths.last
        reins.add(follow, forKey: Self.reinsKey)
        layer.addSublayer(reins)
        reinsLayer = reins
    }

    // MARK: - Dust

    private func addDust(size: CGSize, unit: Double, start: CFTimeInterval) {
        let scale = traitCollection.displayScale
        var pictures: [String: CGImage] = [:]
        for mote in SantaFlight.dust {
            let tint = mote.tint % SantaArt.dustTints.count
            let key = "\(mote.isStar)-\(tint)"
            if pictures[key] == nil {
                pictures[key] = SantaArt.motePicture(isStar: mote.isStar, tint: SantaArt.dustTints[tint], scale: scale)
            }
            guard let born = SantaFlight.spark(of: mote, aged: 0.0001, in: size) else { continue }
            let reach = born.radius * (mote.isStar ? SantaGeometry.starGlow : 1)
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
            layer.position = born.center
            layer.contents = pictures[key]
            // Out of sight until its moment, and again once it has burnt out.
            layer.opacity = 0
            layer.add(Self.drift(of: mote, size: size, start: start), forKey: Self.driftKey)
            self.layer.addSublayer(layer)
            moteLayers.append(layer)
        }
    }

    /// A mote's whole life: falling behind the sleigh, twinkling, shrinking
    /// and, for a star, turning.
    private static func drift(of mote: SantaFlight.Mote, size: CGSize, start: CFTimeInterval) -> CAAnimationGroup {
        let steps = max(2, Int((mote.life * samplesPerSecond / 2).rounded()))
        let sparks = (0...steps).compactMap { step in
            // Just inside its life at both ends.
            let age = min(max(Double(step) / Double(steps) * mote.life, 0.0001), mote.life - 0.0001)
            return SantaFlight.spark(of: mote, aged: age, in: size)
        }
        let fall = CAKeyframeAnimation(keyPath: "position")
        fall.values = sparks.map { NSValue(cgPoint: $0.center) }
        let twinkle = CAKeyframeAnimation(keyPath: "opacity")
        twinkle.values = sparks.map(\.opacity)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1
        shrink.toValue = 1 - SantaFlight.moteShrink
        var parts: [CAAnimation] = [fall, twinkle, shrink]
        if mote.isStar {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = mote.phase
            turn.toValue = mote.phase + SantaFlight.moteSpin * mote.life
            parts.append(turn)
        }
        let life = CAAnimationGroup()
        life.animations = parts
        for part in parts { part.duration = mote.life }
        life.duration = mote.life
        life.beginTime = start + mote.born
        return life
    }
}
