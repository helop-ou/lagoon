import UIKit

/// A picture made of Core Animation layers that the render server moves, so
/// the app only lays them out. It lays them out again whenever they were
/// lost or no longer fit: on a new size, in a new window and when the app
/// comes back to the front.
class MovingLayerView: UIView {
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

    /// Clears the layers and lays them out again.
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
}
