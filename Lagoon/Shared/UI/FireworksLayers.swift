import SwiftUI

/// The show in motion, as Core Animation layers: one small picture a spark,
/// a rocket or a flash, moved by the render server, so the page keeps its
/// frame rate.
struct FireworksLayers: UIViewRepresentable {
    let startedAt: Date
    let palette: ThemePalette

    func makeUIView(context: Context) -> FireworksLayerView {
        FireworksLayerView(startedAt: startedAt, tints: tints)
    }

    func updateUIView(_ view: FireworksLayerView, context: Context) {
        view.tints = tints
    }

    private var tints: [UIColor] {
        FireworksFrame.tints(for: palette).map { UIColor($0) }
    }
}

final class FireworksLayerView: TimedLayerView {
    var tints: [UIColor] {
        didSet { if tints != oldValue { rebuild() } }
    }

    /// One layer a shell that is on the page or about to be, by its place in
    /// the show.
    private(set) var shellLayers: [Int: CALayer] = [:]
    /// Bumped by every rebuild, so a shell waiting to be added to an older
    /// build is not.
    private var build = 0

    /// How often a spark's path is sampled. The render server draws the
    /// frames between.
    static let samplesPerSecond: Double = 20
    /// A glittering spark's brightness is sampled at twice the rate it
    /// blinks.
    static let blinksPerSecond: Double = Fireworks.glitterRate * 2
    /// A shell's layers are made this long before it leaves the ground, and
    /// dropped this long after it burns out.
    static let lead: Double = 0.3

    static let flyKey = "fly"

    init(startedAt: Date, tints: [UIColor]) {
        self.tints = tints
        super.init(startedAt: startedAt)
    }

    override func forgetLayers() {
        build &+= 1
        shellLayers = [:]
    }

    /// Each shell's layers are made just before it flies and dropped once
    /// it has burnt out, so only a few shells' worth are ever alive.
    override func addLayers() {
        let elapsed = CACurrentMediaTime() - began
        addScrim(
            strength: Fireworks.scrim, fadeIn: Fireworks.fadeIn, fadeOut: Fireworks.fadeOut, over: Fireworks.duration
        )
        let build = build
        for (index, shell) in FireworksFrame.shells.enumerated() {
            let ends = shell.launch + Fireworks.climb + shell.kind.burn
            guard ends > elapsed else { continue }
            let wait = shell.launch - Self.lead - elapsed
            if wait <= 0 {
                addShell(index)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self, self.build == build else { return }
                    self.addShell(index)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ends + Self.lead - elapsed) { [weak self] in
                guard let self, self.build == build else { return }
                self.shellLayers.removeValue(forKey: index)?.removeFromSuperlayer()
            }
        }
    }

    // MARK: - Shells

    /// One shell: its rocket, its flash and every spark of its burst.
    func addShell(_ index: Int) {
        let shell = FireworksFrame.shells[index]
        let page = bounds.size
        let tint = tints[shell.tint % max(1, tints.count)]
        let scale = max(1, traitCollection.displayScale)
        let container = CALayer()
        container.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.addSublayer(rocketLayer(of: shell, page: page, scale: scale))
        container.addSublayer(flashLayer(of: shell, tint: tint, page: page, scale: scale))
        let streak = Self.streakPicture(tint, scale: scale)
        for spark in shell.sparks {
            container.addSublayer(sparkLayer(spark, of: shell, picture: streak, page: page))
        }
        layer.addSublayer(container)
        CATransaction.commit()
        shellLayers[index] = container
    }

    /// A streak laid from `tail` to `head`: where its leading edge sits,
    /// how it turns and how wide its layer is.
    struct Lay: Equatable {
        let edge: CGPoint
        let turn: Double
        let width: Double
    }

    static func lay(head: CGPoint, tail: CGPoint) -> Lay {
        let length = hypot(head.x - tail.x, head.y - tail.y)
        // A streak too short to have a direction keeps pointing up.
        let turn = length > 0.01 ? atan2(head.y - tail.y, head.x - tail.x) : -.pi / 2
        return Lay(
            // The picture runs half its height past the head, for the glow.
            edge: CGPoint(x: head.x + cos(turn) * streakHeight / 2, y: head.y + sin(turn) * streakHeight / 2),
            turn: turn,
            // Only the tail stretches. The head and its glow keep their shape,
            // so the layer is never narrower than the two ends.
            width: max(streakTail + length + streakHeight / 2, streakTail + streakHeight + 1)
        )
    }

    /// A streak layer following `lays`, one for each of `count` even steps
    /// over `seconds`, beginning `after` the show does.
    private func streakLayer(
        picture: CGImage?, lays: [Lay], brightness: [Double], blinks: Bool, seconds: Double, after: Double
    ) -> CALayer {
        let streak = CALayer()
        streak.bounds = CGRect(x: 0, y: 0, width: Self.streakLength, height: Self.streakHeight)
        // It is placed by its leading edge, and grows back from there.
        streak.anchorPoint = CGPoint(x: 1, y: 0.5)
        streak.contents = picture
        // The picture's middle stretches. Its tail's end and its head do not.
        streak.contentsCenter = CGRect(
            x: Self.streakTail / Self.streakLength, y: 0,
            width: 1 - (Self.streakTail + Self.streakHeight) / Self.streakLength, height: 1
        )
        // Out of sight until its moment, and again once it has burnt out.
        streak.opacity = 0
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = lays.map { NSValue(cgPoint: $0.edge) }
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = Self.unwound(lays.map(\.turn))
        let stretch = CAKeyframeAnimation(keyPath: "bounds.size.width")
        stretch.values = lays.map(\.width)
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = brightness
        if blinks { glow.calculationMode = .discrete }
        let flight = CAAnimationGroup()
        flight.animations = [move, turn, stretch, glow]
        for part in [move, turn, stretch, glow] { part.duration = seconds }
        flight.duration = seconds
        flight.beginTime = start + after
        streak.add(flight, forKey: Self.flyKey)
        return streak
    }

    /// Turns a little at a time, never the long way round.
    private static func unwound(_ turns: [Double]) -> [Double] {
        var result: [Double] = []
        for turn in turns {
            guard let last = result.last else {
                result.append(turn)
                continue
            }
            var next = turn
            while next - last > .pi { next -= 2 * .pi }
            while next - last < -.pi { next += 2 * .pi }
            result.append(next)
        }
        return result
    }

    private func rocketLayer(of shell: Fireworks.Shell, page: CGSize, scale: CGFloat) -> CALayer {
        let steps = max(2, Int((Fireworks.climb * Self.samplesPerSecond * 2).rounded()))
        let lays = (0...steps).map { step in
            let age = Double(step) / Double(steps) * Fireworks.climb
            return Self.lay(
                head: Fireworks.rocketPoint(of: shell, aged: age, in: page),
                tail: Fireworks.rocketPoint(of: shell, aged: age - Fireworks.rocketTail, in: page)
            )
        }
        return streakLayer(
            picture: Self.rocketPicture(scale: scale), lays: lays,
            brightness: lays.map { _ in 1 }, blinks: false, seconds: Fireworks.climb, after: shell.launch
        )
    }

    private func sparkLayer(
        _ spark: Fireworks.Spark, of shell: Fireworks.Shell, picture: CGImage?, page: CGSize
    ) -> CALayer {
        let burn = shell.kind.burn
        let bursts = shell.launch + Fireworks.climb
        let steps = max(2, Int((burn * Self.samplesPerSecond).rounded()))
        let lays = (0...steps).map { step in
            let age = Double(step) / Double(steps) * burn
            return Self.lay(
                head: Fireworks.point(of: spark, in: shell, aged: age, in: page),
                tail: Fireworks.point(of: spark, in: shell, aged: age - shell.kind.tail, in: page)
            )
        }
        // Its brightness is held for each blink, since glitter is on or off.
        let blinks = max(2, Int((burn * Self.blinksPerSecond).rounded()))
        let brightness = (0..<blinks).map { blink in
            let age = (Double(blink) + 0.5) / Double(blinks) * burn
            let share = age / burn
            let lit = share < Fireworks.glitterFrom || Fireworks.isLit(spark, at: bursts + age)
            return lit ? Fireworks.strength(burnt: share) : 0
        }
        return streakLayer(
            picture: picture, lays: lays, brightness: brightness, blinks: true, seconds: burn, after: bursts
        )
    }

    private func flashLayer(of shell: Fireworks.Shell, tint: UIColor, page: CGSize, scale: CGFloat) -> CALayer {
        let bursts = shell.launch + Fireworks.climb
        let steps = 8
        let flashes = (0...steps).compactMap { step in
            // Just inside its life at both ends.
            let age = min(max(Double(step) / Double(steps) * Fireworks.flashTime, 0.0001), Fireworks.flashTime - 0.0001)
            return Fireworks.flash(of: shell, at: bursts + age, in: page)
        }
        let widest = flashes.map(\.radius).max() ?? 1
        let flash = CALayer()
        flash.bounds = CGRect(x: 0, y: 0, width: widest * 2, height: widest * 2)
        flash.position = flashes.first?.center ?? .zero
        flash.contents = Self.flashPicture(tint, scale: scale)
        flash.opacity = 0
        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = flashes.map { $0.radius / widest }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = flashes.map(\.opacity)
        let life = CAAnimationGroup()
        life.animations = [swell, fade]
        for part in [swell, fade] { part.duration = Fireworks.flashTime }
        life.duration = Fireworks.flashTime
        life.beginTime = start + bursts
        flash.add(life, forKey: Self.flyKey)
        return flash
    }

    // MARK: - Pictures

    /// A streak's picture is this long from its tail's end to its head, and
    /// tall enough for the glow about it.
    static let streakLength: Double = 96
    static var streakHeight: Double { Metrics.fireworkLineWidth * Fireworks.glowWidth }
    /// Where the tail's end and the head sit along the picture.
    static var streakTail: Double { Metrics.fireworkLineWidth }
    private static var streakHead: Double { streakLength - streakHeight / 2 }

    private static var pictures: [String: CGImage] = [:]

    private static func picture(_ key: String, size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> CGImage? {
        let key = "\(key)@\(scale)x\(size.width)x\(size.height)"
        if let made = pictures[key] { return made }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }.cgImage
        pictures[key] = image
        return image
    }

    /// A spark with its tail: fainter and thinner toward the tail's end, a
    /// soft glow about the brightest piece, and a white-hot head.
    private static func streakPicture(_ tint: UIColor, scale: CGFloat) -> CGImage? {
        let line = Metrics.fireworkLineWidth
        let height = streakHeight
        return picture(tint.description, size: CGSize(width: streakLength, height: height), scale: scale) { pen in
            // Lighter where the pieces overlap, as sparks are.
            pen.setBlendMode(.plusLighter)
            pen.setLineCap(.round)
            let middle = height / 2
            let head = streakHead
            let tail = streakTail
            let looks: [(opacity: Double, width: Double)] = [(0.2, 0.5), (0.5, 0.78), (0.95, 1)]
            for (index, look) in looks.enumerated() {
                let from = tail + (head - tail) * Double(index) / Double(looks.count)
                let to = tail + (head - tail) * Double(index + 1) / Double(looks.count)
                pen.setStrokeColor(tint.withAlphaComponent(look.opacity).cgColor)
                pen.setLineWidth(line * look.width)
                pen.move(to: CGPoint(x: from, y: middle))
                pen.addLine(to: CGPoint(x: to, y: middle))
                pen.strokePath()
            }
            pen.setStrokeColor(tint.withAlphaComponent(0.15).cgColor)
            pen.setLineWidth(line * Fireworks.glowWidth)
            pen.move(to: CGPoint(x: tail + (head - tail) * 2 / 3 + line * 1.4, y: middle))
            pen.addLine(to: CGPoint(x: head, y: middle))
            pen.strokePath()
            pen.setFillColor(UIColor.white.withAlphaComponent(0.95).cgColor)
            let dot = line * 1.05
            pen.fillEllipse(in: CGRect(x: head - dot / 2, y: middle - dot / 2, width: dot, height: dot))
        }
    }

    /// A rocket's tail: one white line.
    private static func rocketPicture(scale: CGFloat) -> CGImage? {
        let height = streakHeight
        return picture("rocket", size: CGSize(width: streakLength, height: height), scale: scale) { pen in
            pen.setLineCap(.round)
            pen.setStrokeColor(UIColor.white.withAlphaComponent(Fireworks.rocketOpacity).cgColor)
            pen.setLineWidth(Metrics.fireworkLineWidth * 0.8)
            pen.move(to: CGPoint(x: streakTail, y: height / 2))
            pen.addLine(to: CGPoint(x: streakHead, y: height / 2))
            pen.strokePath()
        }
    }

    /// A burst's flash: white at its heart, the shell's colour about it.
    private static func flashPicture(_ tint: UIColor, scale: CGFloat) -> CGImage? {
        let side: CGFloat = 256
        return picture("flash-\(tint.description)", size: CGSize(width: side, height: side), scale: 1) { pen in
            let colors = [
                UIColor.white.withAlphaComponent(0.9).cgColor, tint.withAlphaComponent(0.45).cgColor,
                tint.withAlphaComponent(0).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]
            ) else { return }
            let middle = CGPoint(x: side / 2, y: side / 2)
            pen.drawRadialGradient(
                gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: side / 2, options: []
            )
        }
    }
}
