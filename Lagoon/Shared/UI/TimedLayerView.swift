import UIKit

/// A picture made of Core Animation layers that play from a moment on the
/// layers' own clock. The render server moves them, so the app only lays
/// them out, and lays them out again whenever they were lost or no longer
/// fit.
class TimedLayerView: UIView {
    /// When its animations began, on the layers' own clock.
    let began: CFTimeInterval
    private var builtSize: CGSize = .zero

    init(startedAt: Date) {
        began = CACurrentMediaTime() - Date.now.timeIntervalSince(startedAt)
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

    /// Clears the layers and lays them out again from `began`, so a view
    /// rebuilt partway carries on from where the clock has it.
    final func rebuild() {
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        builtSize = bounds.size
        forgetLayers()
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addLayers()
        CATransaction.commit()
    }

    /// Lets go of what the last build kept hold of. Runs with no room too.
    func forgetLayers() {}

    /// Adds the layers for the view's size. Implicit animations are off.
    func addLayers() {}

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
}
