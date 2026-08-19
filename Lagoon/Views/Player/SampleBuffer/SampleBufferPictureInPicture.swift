import AVFoundation
import AVKit
import CoreMedia
import Observation
import SwiftUI

/// PiP adapter for the same AVSampleBufferDisplayLayer used on screen.
/// There is no AVPlayer or alternate decode path behind this controller.
@MainActor
@Observable
final class SampleBufferPictureInPicture: NSObject {
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var isTransitioning = false
    private(set) var errorMessage: String?

    @ObservationIgnored private weak var engine: (any PlayerEngine)?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibilityObservation: NSKeyValueObservation?

    func attach(displayLayer: AVSampleBufferDisplayLayer, engine: any PlayerEngine) {
        if controller?.contentSource?.sampleBufferDisplayLayer === displayLayer {
            // Episode handoff keeps the same display layer. Swap only the
            // transport delegate target so active PiP is not torn down and
            // recreated around the new engine.
            self.engine = engine
            invalidatePlaybackState()
            return
        }
        detach()
        self.engine = engine
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        self.controller = controller
        possibilityObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] controller, _ in
            // AVKit mutates PiP possibility on the main run loop; KVO is
            // delivered synchronously on that same thread.
            MainActor.assumeIsolated {
                self?.isPossible = controller.isPictureInPicturePossible
            }
        }
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive || isTransitioning {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            errorMessage = nil
            isTransitioning = true
            controller.startPictureInPicture()
        }
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    func detach() {
        possibilityObservation?.invalidate()
        possibilityObservation = nil
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller?.delegate = nil
        controller = nil
        engine = nil
        isPossible = false
        isActive = false
        isTransitioning = false
    }
}

extension SampleBufferPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
        invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let engine, engine.duration > 0 else { return .invalid }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: engine.duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        engine?.isPaused ?? true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        if skipInterval.isNumeric {
            engine?.seek(by: skipInterval.seconds)
        }
        invalidatePlaybackState()
        completion()
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

extension SampleBufferPictureInPicture: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isTransitioning = true
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isTransitioning = false
        isActive = true
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isTransitioning = false
        isActive = false
        errorMessage = error.localizedDescription
    }

    func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isTransitioning = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isTransitioning = false
        isActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

#if os(iOS)
/// Apple's standard route picker, hosted directly rather than imitating it
/// with a custom menu so route state and accessibility remain system-owned.
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
