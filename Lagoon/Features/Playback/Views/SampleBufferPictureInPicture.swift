import AVFoundation
import AVKit
import CoreMedia
import LagoonEngine
import Observation
import SwiftUI

/// PiP over the same display layer used on screen. No AVPlayer path.
@MainActor
@Observable
final class SampleBufferPictureInPicture: NSObject {
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var isTransitioning = false

    @ObservationIgnored var onStarted: (() -> Void)?
    @ObservationIgnored var onStopped: (() -> Void)?
    @ObservationIgnored var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    /// How the engine should draw subtitles into the frames while the
    /// window shows, where the player's own overlay is gone. Nil draws none.
    @ObservationIgnored var subtitleStyle: (() -> BurnedInSubtitleStyle?)?

    @ObservationIgnored private weak var engine: (any PlayerEngine)?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibilityObservation: NSKeyValueObservation?

    func attach(displayLayer: AVSampleBufferDisplayLayer, engine: any PlayerEngine) {
        if controller?.contentSource?.sampleBufferDisplayLayer === displayLayer {
            // Handoff keeps the layer. Swap only the engine so active PiP
            // survives.
            handOff(to: engine)
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
        // Regression hook: without automatic PiP, leaving the app acts like
        // locking it, so the simulator can exercise background audio.
        controller.canStartPictureInPictureAutomaticallyFromInline =
            !UserDefaults.standard.bool(forKey: "debug.regressionNoAutomaticPiP")
        #endif
        self.controller = controller
        possibilityObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] controller, _ in
            // AVKit posts this KVO synchronously on the main thread.
            MainActor.assumeIsolated {
                self?.isPossible = controller.isPictureInPicturePossible
            }
        }
    }

    /// The next engine takes the same window: the outgoing one stops drawing
    /// subtitles and the incoming one starts.
    func handOff(to engine: any PlayerEngine) {
        self.engine?.setPictureInPictureSubtitles(nil)
        self.engine = engine
        if isActive {
            engine.setPictureInPictureSubtitles(subtitleStyle?() ?? nil)
        }
        invalidatePlaybackState()
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive || isTransitioning {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            isTransitioning = true
            controller.startPictureInPicture()
        }
    }

    func invalidatePlaybackState() {
        controller?.invalidatePlaybackState()
    }

    func detach() {
        engine?.setPictureInPictureSubtitles(nil)
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

    /// Detaches and drops the player's callbacks, for when the player goes.
    func reset() {
        onStarted = nil
        onStopped = nil
        onRestore = nil
        subtitleStyle = nil
        detach()
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
        engine?.setPictureInPictureSubtitles(subtitleStyle?() ?? nil)
        onStarted?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isTransitioning = false
        isActive = false
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
        engine?.setPictureInPictureSubtitles(nil)
        onStopped?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        if let onRestore { onRestore(completionHandler) }
        else { completionHandler(true) }
    }
}

#if os(iOS)
/// The system route picker, so route state and accessibility stay native.
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
