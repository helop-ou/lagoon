import SwiftUI
import UIKit

/// Hosts the CAMetalLayer mpv renders into and hands it to the engine once
/// the view exists — `wid` must be set before `mpv_initialize`, so the
/// engine can't spin up until this point.
struct MPVVideoSurface: UIViewControllerRepresentable {
    let engine: MPVPlayerEngine

    func makeUIViewController(context: Context) -> MPVSurfaceViewController {
        MPVSurfaceViewController(engine: engine)
    }

    func updateUIViewController(_ uiViewController: MPVSurfaceViewController, context: Context) {}
}

final class MPVSurfaceViewController: UIViewController {
    private let engine: MPVPlayerEngine
    private let videoLayer = MetalVideoLayer()

    init(engine: MPVPlayerEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        videoLayer.frame = view.bounds
        videoLayer.framebufferOnly = true
        videoLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(videoLayer)
        engine.attachAndPlay(layer: videoLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // No implicit animation: a lagging frame change letterboxes the video.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = view.bounds
        videoLayer.contentsScale = traitCollection.displayScale
        CATransaction.commit()
    }
}
