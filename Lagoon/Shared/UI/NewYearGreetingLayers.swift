import SwiftUI

/// The greeting in motion, as Core Animation layers: a picture for the line,
/// one for each numeral and one for each star, moved by the render server.
/// Drawn again every frame, the greeting alone took a quarter of a processor
/// core on the Apple TV and lost one frame in fourteen.
struct NewYearGreetingLayers: UIViewRepresentable {
    let startedAt: Date
    let year: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeUIView(context: Context) -> NewYearGreetingLayerView {
        NewYearGreetingLayerView(startedAt: startedAt, year: year, dynamicTypeSize: dynamicTypeSize)
    }

    func updateUIView(_ view: NewYearGreetingLayerView, context: Context) {}
}

final class NewYearGreetingLayerView: UIView {
    let year: Int
    /// When the show began, on the layers' own clock.
    let began: CFTimeInterval
    private let dynamicTypeSize: DynamicTypeSize

    private(set) var greetingLayer: CALayer?
    private(set) var titleLayer: CALayer?
    private(set) var numeralLayers: [CALayer] = []
    private(set) var shineLayer: CALayer?
    private(set) var starLayers: [CALayer] = []
    private var builtSize: CGSize = .zero

    /// How often the greeting is sampled. The render server draws the
    /// frames between.
    static let samplesPerSecond: Double = 30
    /// Room about a picture for its glow and shadow.
    static var margin: Double { Metrics.Space.xl * 3 }

    static let fadeKey = "fade"
    static let popKey = "pop"
    static let crossKey = "cross"

    init(
        startedAt: Date, year: Int, dynamicTypeSize: DynamicTypeSize = .large,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        self.year = year
        self.dynamicTypeSize = dynamicTypeSize
        began = now - Date.now.timeIntervalSince(startedAt)
        super.init(frame: .zero)
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

    /// Every moment the greeting is worked out for.
    static var sampleTimes: [Double] {
        let count = Int((Fireworks.duration * samplesPerSecond).rounded())
        return (0...count).map { Double($0) / Double(count) * Fireworks.duration }
    }

    /// Lays the greeting out as the still picture has it and sets it going
    /// from `began`, so one rebuilt partway carries on from where the clock
    /// has it. Outside the show it is out of sight.
    func rebuild() {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        greetingLayer = nil
        titleLayer = nil
        numeralLayers = []
        shineLayer = nil
        starLayers = []
        builtSize = bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }
        let page = bounds.size
        let times = Self.sampleTimes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let greeting = CALayer()
        greeting.frame = bounds
        greeting.opacity = 0
        animate(greeting, "opacity", times.map(NewYearGreeting.presence), Self.fadeKey)
        addStars(to: greeting, page: page, times: times)
        addWords(to: greeting, page: page, times: times)
        layer.addSublayer(greeting)
        CATransaction.commit()
        greetingLayer = greeting
    }

    private func animate(_ target: CALayer, _ keyPath: String, _ values: [Any], _ key: String) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.calculationMode = .linear
        animation.duration = Fireworks.duration
        animation.beginTime = layer.convertTime(began, from: nil)
        target.add(animation, forKey: key)
    }

    // MARK: - Stars

    private func addStars(to greeting: CALayer, page: CGSize, times: [Double]) {
        let center = CGPoint(x: page.width / 2, y: page.height * NewYearGreeting.height)
        let spread = Metrics.newYearNumeralSize
        let picture = Self.picture(of: Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            context.fill(
                NewYearGreeting.star(at: CGPoint(x: radius, y: radius), radius: radius),
                with: .color(NewYearGreeting.paleGold)
            )
        }.frame(width: 64, height: 64), scale: scale)?.image
        for star in NewYearGreeting.stars {
            let radius = spread * star.size
            let layer = CALayer()
            layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            layer.position = CGPoint(x: center.x + star.offset.x * spread, y: center.y + star.offset.y * spread)
            layer.contents = picture
            layer.opacity = 0
            animate(layer, "opacity", times.map { NewYearGreeting.brightness(of: star, at: $0) }, Self.fadeKey)
            greeting.addSublayer(layer)
            starLayers.append(layer)
        }
    }

    // MARK: - Words

    /// The line and the numerals, laid out as the still picture's stack: the
    /// line over the numerals, the pair about the greeting's middle.
    private func addWords(to greeting: CALayer, page: CGSize, times: [Double]) {
        let margin = Self.margin
        let room = page.width - Metrics.Space.l * 2
        let digits = NewYearGreeting.digits(of: year)
        // Numerals that would not fit shrink together, to half at most. A
        // smaller size is not exactly as much narrower, so it takes a try or two.
        let full = Metrics.newYearNumeralSize
        var size = full
        var widths = digits.map { Self.width(of: $0, size: size, scale: scale) }
        for _ in 0..<3 {
            let width = widths.reduce(0, +)
            guard width > room, width > 0, size > full / 2 else { break }
            size = max(full / 2, size * room / width * 0.995)
            widths = digits.map { Self.width(of: $0, size: size, scale: scale) }
        }
        let numerals = digits.map { digit in
            (
                lit: Self.picture(of: NewYearGreeting.numeral(digit, size: size)
                    .foregroundStyle(NewYearGreeting.numeralFill)
                    .shadow(color: NewYearGreeting.numeralGlow, radius: Metrics.Space.xl)
                    .shadow(color: NewYearGreeting.shadow, radius: Metrics.Space.l)
                    .padding(margin), scale: scale),
                plain: Self.picture(of: NewYearGreeting.numeral(digit, size: size)
                    .foregroundStyle(.white)
                    .padding(margin), scale: scale)
            )
        }
        let title = Self.picture(of: NewYearGreeting.title
            .shadow(color: NewYearGreeting.shadow, radius: Metrics.Space.l)
            .frame(maxWidth: room)
            .padding(margin)
            .environment(\.dynamicTypeSize, dynamicTypeSize), scale: scale)
        let titleHeight = (title?.size.height ?? margin * 2) - margin * 2
        let rowHeight = (numerals.compactMap(\.lit?.size.height).max() ?? margin * 2) - margin * 2
        let rowWidth = widths.reduce(0, +)
        let top = page.height * NewYearGreeting.height - (titleHeight + Metrics.Space.s + rowHeight) / 2

        if let title {
            let layer = Self.pictureLayer(title, center: CGPoint(x: page.width / 2, y: top + titleHeight / 2))
            layer.opacity = 0
            animate(layer, "opacity", times.map {
                NewYearGreeting.rise(since: NewYearGreeting.titleArrives, at: $0, over: NewYearGreeting.titleRise)
            }, Self.fadeKey)
            greeting.addSublayer(layer)
            titleLayer = layer
        }

        let row = CGRect(
            x: (page.width - rowWidth) / 2, y: top + titleHeight + Metrics.Space.s, width: rowWidth, height: rowHeight
        )
        // The band of light shows only where the numerals are.
        let shine = CALayer()
        shine.frame = row
        let mask = CALayer()
        mask.frame = shine.bounds
        var leading = 0.0
        for (index, numeral) in numerals.enumerated() {
            let middle = CGPoint(x: leading + widths[index] / 2, y: rowHeight / 2)
            leading += widths[index]
            if let lit = numeral.lit {
                let layer = Self.pictureLayer(lit, center: CGPoint(x: row.minX + middle.x, y: row.minY + middle.y))
                let since = NewYearGreeting.arrival(ofNumeral: index)
                layer.opacity = 0
                animate(layer, "opacity", times.map {
                    NewYearGreeting.rise(since: since, at: $0, over: NewYearGreeting.numeralRise)
                }, Self.fadeKey)
                animate(layer, "transform.scale", times.map { NewYearGreeting.pop(since: since, at: $0) }, Self.popKey)
                greeting.addSublayer(layer)
                numeralLayers.append(layer)
            }
            if let plain = numeral.plain {
                mask.addSublayer(Self.pictureLayer(plain, center: middle))
            }
        }
        let band = CALayer()
        band.bounds = CGRect(x: 0, y: 0, width: rowWidth * NewYearGreeting.shineWidth, height: rowHeight)
        band.contents = Self.bandPicture()
        let crossing = times.map { NewYearGreeting.shinePosition(at: $0) }
        band.position = CGPoint(x: rowWidth * (crossing.first ?? -1), y: rowHeight / 2)
        animate(
            band, "position",
            crossing.map { NSValue(cgPoint: CGPoint(x: rowWidth * $0, y: rowHeight / 2)) }, Self.crossKey
        )
        shine.addSublayer(band)
        shine.mask = mask
        greeting.addSublayer(shine)
        shineLayer = shine
    }

    private var scale: Double { max(1, traitCollection.displayScale) }

    // MARK: - Pictures

    /// A SwiftUI view drawn once, and its size in points.
    private static func picture(of view: some View, scale: Double) -> (image: CGImage, size: CGSize)? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return (image, CGSize(width: Double(image.width) / scale, height: Double(image.height) / scale))
    }

    /// How wide a numeral stands, without anything about it.
    private static func width(of digit: Character, size: Double, scale: Double) -> Double {
        Double(picture(of: NewYearGreeting.numeral(digit, size: size), scale: scale)?.size.width ?? 0)
    }

    private static func pictureLayer(_ picture: (image: CGImage, size: CGSize), center: CGPoint) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: picture.size)
        layer.position = center
        layer.contents = picture.image
        return layer
    }

    private static var band: CGImage?

    /// The band of light: clear at both edges, white in the middle.
    private static func bandPicture() -> CGImage? {
        if let band { return band }
        let size = CGSize(width: 128, height: 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [
                UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.withAlphaComponent(0.9).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: size.width, y: 0), options: []
            )
        }.cgImage
        band = image
        return image
    }
}
