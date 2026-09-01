import Foundation
import Testing
@testable import Lagoon

/// HEL-137: 4K AV1 plays on the software path but does not hold frame rate.
///
/// The structural half of that ticket — decode moved off the demux queue —
/// is a threading change that only a device can score. What is pinnable here
/// is the arithmetic that came with it: how many decoded 4K frames the app
/// may hold, and what libavcodec is told about threads.
struct SoftwareDecodePipelineTests {
    /// A 4:2:0 P010 surface at 3840x2160: luma plus half as many chroma
    /// samples, each in a 16-bit word (HEL-109's figure, restated here so the
    /// limit below is anchored to something rather than to itself).
    private let fourKP010Bytes: Int64 = 3840 * 2160 * 3

    @Test func decodedQueueLimitFallsBackToBytesWhenFramesAreHuge() {
        #expect(fourKP010Bytes == 24_883_200)

        // What the software path was allowed before the byte cap: 42 frames,
        // which at this size is 1.05 GB of surfaces in a process jetsam has
        // killed at 2.1 GB.
        let byCountOnly = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true
        )
        #expect(byCountOnly == 42)
        #expect(Int64(byCountOnly) * fourKP010Bytes > 1_000_000_000)

        let capped = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            decodedFrameBytes: fourKP010Bytes
        )
        #expect(capped == 30)
        #expect(Int64(capped) * fourKP010Bytes == DemuxBackpressurePolicy.decodedQueueByteBudget)
    }

    @Test func smallerFramesKeepTheLimitTheyWereMeasuredWith() {
        // 1080p 10-bit is 6.2 MB a frame: 42 of them is 250 MB, comfortably
        // inside the budget, so the count stays the binding limit and every
        // configuration measured before HEL-137 keeps its behavior.
        let hd10Bit: Int64 = 1920 * 1080 * 3
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            decodedFrameBytes: hd10Bit
        ) == 42)

        // The hardware-decoded path was already inside the budget at 4K,
        // which is where the budget came from — it must not move.
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            decodedFrameBytes: fourKP010Bytes
        ) == 30)

        // Compressed samples are not surfaces and are not bounded by this.
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: false) == 120)
    }

    @Test func decodedQueueKeepsAFloorHoweverLargeAFrameGets() {
        // 8K is outside the advertised profile, but the limit still has to
        // leave room for a reorder ladder rather than collapsing toward one.
        let eightKP010: Int64 = 7680 * 4320 * 3
        #expect(DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            decodedFrameBytes: eightKP010
        ) == 8)
    }

    @Test func packetsInsideTheDecoderCountAsVideoAlreadyRead() {
        // The demux loop passes queue depth *plus* what the decode stage
        // still owes. Six decoded frames with 25 packets in the decoder is a
        // queue that looks nearly empty and a pipeline that is full: reading
        // further would be reading a decoder backlog ahead of itself.
        let frameBytes = fourKP010Bytes
        let queuedOnly = DemuxBackpressurePolicy.decision(
            videoCount: 6,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: false,
            decodedFrameBytes: frameBytes
        )
        #expect(queuedOnly == .read)

        let queuedPlusPending = DemuxBackpressurePolicy.decision(
            videoCount: 6 + 25,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: false,
            decodedFrameBytes: frameBytes
        )
        #expect(queuedPlusPending == .waitForVideo(below: 23))
    }

    @Test func softwareDecodeThreadsStayAutomaticUnlessTheToggleIsOn() {
        // Auto is what HEL-103 measured (1.66 s for 30 s of 4K AV1 against
        // 13.26 s single-threaded), so it stays the default and the
        // alternative only exists to be A/B'd on hardware.
        #expect(SoftwareDecodeThreadPolicy.threadCount(
            performanceCores: 2,
            activeProcessors: 6,
            boundToPerformanceCores: false
        ) == 0)

        // An A15: two performance cores against four efficiency ones.
        #expect(SoftwareDecodeThreadPolicy.threadCount(
            performanceCores: 2,
            activeProcessors: 6,
            boundToPerformanceCores: true
        ) == 2)
    }

    @Test func boundedThreadCountNeverCollapsesToSingleThreaded() {
        // One thread is the configuration that took 13.26 s of CPU for 30 s
        // of video. A device reporting one performance core is not a reason
        // to go back to it.
        #expect(SoftwareDecodeThreadPolicy.threadCount(
            performanceCores: 1,
            activeProcessors: 4,
            boundToPerformanceCores: true
        ) == 2)

        // Never more threads than there are cores to run them on.
        #expect(SoftwareDecodeThreadPolicy.threadCount(
            performanceCores: 8,
            activeProcessors: 4,
            boundToPerformanceCores: true
        ) == 4)

        // A platform that cannot report its clusters gets libavcodec's own
        // answer rather than a guess.
        #expect(SoftwareDecodeThreadPolicy.threadCount(
            performanceCores: 0,
            activeProcessors: 6,
            boundToPerformanceCores: true
        ) == 0)
    }

    @Test func costPerFrameSurvivesThrottlingWhereARateDoesNot() {
        // The lesson of two HEL-137 builds. Once the queues fill, backpressure
        // holds the decoder at playback rate, so a decoder with headroom and
        // one with none report the same frames per second. Cost per frame is
        // what separates them, and the budget at 23.976 fps is 41.7 ms.
        let comfortable = SoftwareVideoDecoder.Profile(
            frames: 24, packets: 24, decodeSeconds: 24 * 0.020,
            conversionSeconds: 24 * 0.001, elapsedSeconds: 1
        )
        let struggling = SoftwareVideoDecoder.Profile(
            frames: 24, packets: 24, decodeSeconds: 24 * 0.055,
            conversionSeconds: 24 * 0.001, elapsedSeconds: 1
        )

        // Identical rates, opposite verdicts.
        #expect(comfortable.framesPerSecond == struggling.framesPerSecond)
        #expect(abs(comfortable.decodeMilliseconds - 20) < 0.001)
        #expect(abs(struggling.decodeMilliseconds - 55) < 0.001)
        #expect(comfortable.decodeBudgetUsed(frameRate: 23.976) < 1)
        #expect(struggling.decodeBudgetUsed(frameRate: 23.976) > 1)

        // Nothing decoded yet must not read as a free decoder.
        #expect(SoftwareVideoDecoder.Profile().decodeMilliseconds == 0)
        #expect(SoftwareVideoDecoder.Profile().decodeBudgetUsed(frameRate: 24) == 0)
    }

    @Test func frameDelayAndPriorityStayOffUntilAskedFor() {
        #expect(SoftwareDecodeThreadPolicy.maxFrameDelay(
            enabled: false, activeProcessors: 6
        ) == 0)
        #expect(SoftwareDecodeThreadPolicy.maxFrameDelay(
            enabled: true, activeProcessors: 6
        ) == 6)
        // Every frame in flight is another 4K surface held inside dav1d, on
        // top of the queue the engine already bounds.
        #expect(SoftwareDecodeThreadPolicy.maxFrameDelay(
            enabled: true, activeProcessors: 32
        ) == 8)
        #expect(SoftwareDecodeThreadPolicy.decodeQueueQoS(highPriority: false) == .userInitiated)
        #expect(SoftwareDecodeThreadPolicy.decodeQueueQoS(highPriority: true) == .userInteractive)
    }

    @Test func decodeProfileSeparatesTheThreeCostsAsSharesOfOneCore() {
        // 24 frames in one second of wall time, 0.44 s of it inside
        // libavcodec and 0.12 s converting: the shape HEL-137 is asking the
        // device to report, and the fractions are per-stage shares of a core
        // rather than a split of the whole.
        let profile = SoftwareVideoDecoder.Profile(
            frames: 24,
            packets: 24,
            decodeSeconds: 0.44,
            conversionSeconds: 0.12,
            elapsedSeconds: 1
        )
        #expect(profile.framesPerSecond == 24)
        #expect(abs(profile.decodeFraction - 0.44) < 0.0001)
        #expect(abs(profile.conversionFraction - 0.12) < 0.0001)

        // Nothing measured yet must not read as a stage taking no time.
        let empty = SoftwareVideoDecoder.Profile()
        #expect(empty.framesPerSecond == 0)
        #expect(empty.decodeFraction == 0)
        #expect(empty.conversionFraction == 0)
    }
}
