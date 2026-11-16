import SwiftUI

/// A snowy page's backdrop decoration: frost in the top corners and light
/// snow falling behind the content. The snow stands still under Reduce
/// Motion and while the player is up.
struct WinterDecoration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerCover) private var playerCover

    /// The moment the standing snow shows.
    static let stillMoment: TimeInterval = 100

    var body: some View {
        let ice = Theme.palette.snow
        ZStack(alignment: .top) {
            FrostCorners(color: ice)
            if isStill {
                SnowfallFrame(time: Self.stillMoment, color: ice)
            } else {
                SnowfallLayers(color: ice)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isStill: Bool {
        reduceMotion || playerCover?.isPlayerUp == true
    }
}

/// Frost in both top corners: a haze, ice crystals and specks, all fading
/// away from the corner. Drawn once.
struct FrostCorners: View {
    let color: Color

    private static let left = FrostGeometry.frost(size: Metrics.frostSize, seed: 3)
    private static let right = FrostGeometry.frost(size: Metrics.frostSize, seed: 11)
    /// The haze reaches a little past the last crystal.
    private static let haze = Metrics.frostSize * 1.4

    var body: some View {
        Canvas { context, size in
            Self.draw(Self.left, in: &context, color: color)
            var mirrored = context
            mirrored.translateBy(x: size.width, y: 0)
            mirrored.scaleBy(x: -1, y: 1)
            Self.draw(Self.right, in: &mirrored, color: color)
        }
        .frame(height: Self.haze)
    }

    private static func draw(_ frost: FrostGeometry.Frost, in context: inout GraphicsContext, color: Color) {
        let size = Metrics.frostSize
        context.fill(
            Path(CGRect(x: 0, y: 0, width: haze, height: haze)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(0.2), color.opacity(0.07), color.opacity(0)]),
                center: .zero, startRadius: 0, endRadius: haze
            )
        )
        for crystal in frost.crystals {
            var turned = context
            turned.translateBy(x: crystal.center.x, y: crystal.center.y)
            turned.rotate(by: .radians(crystal.turn))
            turned.stroke(
                SnowflakeGeometry.frostPath(radius: crystal.radius),
                with: .color(color.opacity(0.08 + 0.5 * FrostGeometry.strength(at: crystal.center, size: size))),
                // A big crystal is drawn a little heavier than a small one.
                style: StrokeStyle(
                    lineWidth: Metrics.frostLineWidth * (0.6 + crystal.radius / size),
                    lineCap: .round, lineJoin: .round
                )
            )
        }
        for speck in frost.specks {
            let radius = Metrics.frostLineWidth * 0.9 * speck.radius
            context.fill(
                Path(ellipseIn: CGRect(
                    x: speck.center.x - radius, y: speck.center.y - radius, width: radius * 2, height: radius * 2
                )),
                with: .color(color.opacity(0.55 * FrostGeometry.strength(at: speck.center, size: size)))
            )
        }
    }
}

/// The snow at one moment, drawn once: what stands under Reduce Motion, and
/// the picture the moving snow is checked against.
struct SnowfallFrame: View {
    let time: TimeInterval
    let color: Color

    static let flakes = Snowfall.flakes(count: Metrics.snowflakeCount, seed: 5)
    /// One crystal of radius 1, scaled to each flake.
    private static let crystal = SnowflakeGeometry.path(radius: 1)
    /// A soft flake fades out over this many times its radius.
    static let softness = 1.9
    /// A crystal's line, as a share of its radius.
    static let crystalLine = 0.13

    var body: some View {
        Canvas { context, size in
            for flake in Self.flakes {
                let pose = Snowfall.pose(
                    of: flake, at: time, in: size,
                    dot: Metrics.snowflakeRadius, crystal: Metrics.snowCrystalRadius
                )
                if pose.isCrystal {
                    var turned = context
                    turned.translateBy(x: pose.center.x, y: pose.center.y)
                    turned.rotate(by: .radians(pose.turn))
                    turned.scaleBy(x: pose.radius, y: pose.radius)
                    turned.stroke(
                        Self.crystal, with: .color(color.opacity(pose.opacity)),
                        style: StrokeStyle(lineWidth: Self.crystalLine, lineCap: .round, lineJoin: .round)
                    )
                } else {
                    let reach = pose.radius * Self.softness
                    let ink = color.opacity(pose.opacity)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: pose.center.x - reach, y: pose.center.y - reach, width: reach * 2, height: reach * 2
                        )),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: ink, location: 0),
                                .init(color: ink.opacity(0.55), location: 0.45),
                                .init(color: ink.opacity(0), location: 1),
                            ]),
                            center: pose.center, startRadius: 0, endRadius: reach
                        )
                    )
                }
            }
        }
    }
}

/// The moving snow, as Core Animation layers: one small layer a flake, moved
/// by the render server, so a page costs nothing to keep snowing. One canvas
/// redrawn thirty times a second took a third of a processor core on the
/// Apple TV.
struct SnowfallLayers: UIViewRepresentable {
    let color: Color

    func makeUIView(context: Context) -> SnowfallLayerView {
        SnowfallLayerView()
    }

    func updateUIView(_ view: SnowfallLayerView, context: Context) {
        view.ink = UIColor(color)
    }
}

final class SnowfallLayerView: UIView {
    var ink: UIColor = .white {
        didSet { if ink != oldValue { rebuild() } }
    }

    private(set) var flakeLayers: [CALayer] = []
    private var builtSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // Going to the background removes every animation.
        NotificationCenter.default.addObserver(
            self, selector: #selector(resume), name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != builtSize { rebuild() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Leaving a window removes them too.
        if window != nil { rebuild() }
    }

    @objc private func resume() {
        rebuild()
    }

    /// Lays every flake out where the clock has it and sets it falling. The
    /// clock is the wall's, so every page shows the same snow.
    func rebuild(now: TimeInterval = Date.now.timeIntervalSinceReferenceDate) {
        flakeLayers.forEach { $0.removeFromSuperlayer() }
        flakeLayers = []
        builtSize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for flake in SnowfallFrame.flakes {
            let pose = Snowfall.pose(
                of: flake, at: now, in: bounds.size,
                dot: Metrics.snowflakeRadius, crystal: Metrics.snowCrystalRadius
            )
            let flakeLayer = pose.isCrystal ? crystalLayer(pose) : dotLayer(pose)
            flakeLayer.position = pose.center
            flakeLayer.opacity = Float(pose.opacity)
            layer.addSublayer(flakeLayer)
            flakeLayers.append(flakeLayer)
            animate(flakeLayer, flake: flake, pose: pose, now: now)
        }
        CATransaction.commit()
    }

    private func crystalLayer(_ pose: Snowfall.Pose) -> CALayer {
        let crystal = CAShapeLayer()
        // The path is drawn about the origin, which the bounds put mid-layer.
        crystal.bounds = CGRect(x: -pose.radius, y: -pose.radius, width: pose.radius * 2, height: pose.radius * 2)
        crystal.path = SnowflakeGeometry.path(radius: pose.radius).cgPath
        crystal.strokeColor = ink.cgColor
        crystal.fillColor = nil
        crystal.lineWidth = pose.radius * SnowfallFrame.crystalLine
        crystal.lineCap = .round
        crystal.lineJoin = .round
        return crystal
    }

    private func dotLayer(_ pose: Snowfall.Pose) -> CALayer {
        let dot = CALayer()
        let reach = pose.radius * SnowfallFrame.softness
        dot.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)
        dot.contents = Self.softDot(ink)
        return dot
    }

    private func animate(_ flakeLayer: CALayer, flake: Snowfall.Flake, pose: Snowfall.Pose, now: TimeInterval) {
        let seconds = Snowfall.seconds(of: flake)
        let fall = CABasicAnimation(keyPath: "position.y")
        fall.fromValue = -pose.radius
        fall.toValue = bounds.height + pose.radius
        fall.duration = seconds
        fall.repeatCount = .infinity
        fall.timeOffset = Snowfall.progress(of: flake, at: now) * seconds
        flakeLayer.add(fall, forKey: Self.fallKey)

        let lane = flake.lane * bounds.width
        let reach = pose.radius * Snowfall.swing(isCrystal: pose.isCrystal)
        let sway = CABasicAnimation(keyPath: "position.x")
        sway.fromValue = lane - reach
        sway.toValue = lane + reach
        sway.duration = Snowfall.swayPeriod / 2
        sway.autoreverses = true
        sway.repeatCount = .infinity
        sway.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sway.timeOffset = flake.phase / (2 * .pi) * Snowfall.swayPeriod
        flakeLayer.add(sway, forKey: Self.swayKey)

        guard pose.isCrystal else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = pose.turn
        spin.toValue = pose.turn + 2 * .pi
        spin.duration = 2 * .pi / Snowfall.spin
        spin.repeatCount = .infinity
        flakeLayer.add(spin, forKey: Self.spinKey)
    }

    static let fallKey = "fall"
    static let swayKey = "sway"
    static let spinKey = "spin"

    private static var softDots: [UIColor: CGImage] = [:]

    /// A soft flake's picture in `ink`: full in the middle, gone at the edge.
    /// Stretched to each dot's size.
    private static func softDot(_ ink: UIColor) -> CGImage? {
        if let made = softDots[ink] { return made }
        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let colors = [ink.cgColor, ink.withAlphaComponent(0.55).cgColor, ink.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]
            ) else { return }
            let middle = CGPoint(x: side / 2, y: side / 2)
            context.cgContext.drawRadialGradient(
                gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: side / 2, options: []
            )
        }.cgImage
        softDots[ink] = image
        return image
    }
}
