import AVFoundation
import SwiftUI
import UIKit

/// Hosts the AVSampleBufferDisplayLayer the Lagoon engine renders into and
/// hands it to the engine once the view exists (mirrors MPVVideoSurface).
struct SampleBufferVideoSurface: UIViewRepresentable {
    let engine: SampleBufferPlayerEngine
    var onDisplayLayerReady: ((AVSampleBufferDisplayLayer) -> Void)?

    init(
        engine: SampleBufferPlayerEngine,
        onDisplayLayerReady: ((AVSampleBufferDisplayLayer) -> Void)? = nil
    ) {
        self.engine = engine
        self.onDisplayLayerReady = onDisplayLayerReady
    }

    final class Coordinator {
        weak var engine: SampleBufferPlayerEngine?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SampleBufferVideoView {
        let view = SampleBufferVideoView()
        engine.attach(displayLayer: view.displayLayer)
        context.coordinator.engine = engine
        onDisplayLayerReady?(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferVideoView, context: Context) {
        guard context.coordinator.engine !== engine else { return }
        // PlaybackController waits for the prior renderer set to detach
        // before publishing its successor, so this layer can survive an
        // episode boundary without belonging to two synchronizers at once.
        engine.attach(displayLayer: uiView.displayLayer)
        context.coordinator.engine = engine
        onDisplayLayerReady?(uiView.displayLayer)
    }
}

final class SampleBufferVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
