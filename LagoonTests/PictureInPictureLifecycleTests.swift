import AVKit
import AVFoundation
import Testing
@testable import Lagoon

@Suite("Picture in Picture lifecycle")
@MainActor
struct PictureInPictureLifecycleTests {
    @Test func delegatesDeliverLifecycleWithoutMountedSwiftUIView() {
        let adapter = SampleBufferPictureInPicture()
        let system = AVPictureInPictureController(contentSource: .init(
            sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(), playbackDelegate: adapter))
        var starts = 0
        var stops = 0
        adapter.onStarted = { starts += 1 }
        adapter.onStopped = { stops += 1 }
        adapter.pictureInPictureControllerWillStartPictureInPicture(system)
        #expect(adapter.isTransitioning)
        adapter.pictureInPictureControllerDidStartPictureInPicture(system)
        #expect(adapter.isActive)
        #expect(!adapter.isTransitioning)
        #expect(starts == 1)
        adapter.pictureInPictureControllerDidStopPictureInPicture(system)
        #expect(!adapter.isActive)
        #expect(stops == 1)
    }

    @Test func restorationReportsPresentationFailureHonestly() {
        let adapter = SampleBufferPictureInPicture()
        let system = AVPictureInPictureController(contentSource: .init(
            sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(), playbackDelegate: adapter))
        var restored: Bool?
        adapter.onRestore = { completion in completion(false) }
        adapter.pictureInPictureController(system,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 })
        #expect(restored == false)
    }
}
