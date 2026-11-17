import UIKit

/// A moving picture that plays once, from a moment on the layers' own clock.
/// One laid out again partway carries on from where that clock has it.
class TimedLayerView: MovingLayerView {
    /// When its animations began, on the layers' own clock.
    let began: CFTimeInterval

    static let dimKey = "dim"
    private static let scrimName = "scrim"

    init(startedAt: Date) {
        began = CACurrentMediaTime() - Date.now.timeIntervalSince(startedAt)
        super.init(frame: .zero)
    }

    /// `began` in this view's own layer time.
    var start: CFTimeInterval { layer.convertTime(began, from: nil) }

    /// Plays `values` evenly over `duration`, from `began`.
    func animate(_ target: CALayer, _ keyPath: String, _ values: [Any], over duration: Double, key: String) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = start
        target.add(animation, forKey: key)
    }

    /// The layer dimming the page behind the picture, where it has one.
    var scrimLayer: CALayer? {
        layer.sublayers?.first { $0.name == Self.scrimName }
    }

    /// Dims the page to `strength` over `fadeIn`, holds it, and lets it go
    /// over the last `fadeOut` of `duration`.
    func addScrim(strength: Double, fadeIn: Double, fadeOut: Double, over duration: Double) {
        let scrim = CALayer()
        scrim.name = Self.scrimName
        scrim.frame = bounds
        scrim.backgroundColor = UIColor.black.cgColor
        scrim.opacity = 0
        let dim = CAKeyframeAnimation(keyPath: "opacity")
        let strengths: [Double] = [0, strength, strength, 0]
        dim.values = strengths
        dim.keyTimes = [0, NSNumber(value: fadeIn / duration), NSNumber(value: 1 - fadeOut / duration), 1]
        dim.duration = duration
        dim.beginTime = start
        scrim.add(dim, forKey: Self.dimKey)
        layer.addSublayer(scrim)
    }
}
