import CoreMedia
import Foundation
import Libavcodec
import Libavutil

/// One compressed video access unit, detached from the demuxer's reusable
/// packet so it can outlive the read that produced it.
///
/// `av_packet_clone` shares FFmpeg's existing reference-counted buffer rather
/// than copying the payload, so handing a 4K access unit to another thread
/// costs an atomic increment and one small allocation.
nonisolated final class SoftwareVideoPacket: @unchecked Sendable {
    let packet: UnsafeMutablePointer<AVPacket>
    /// Container time (already origin-corrected) of this access unit, and
    /// where it ends. The demux loop keeps the same stall/end bookkeeping it
    /// kept when it held the decoded frame itself; decoded output carries its
    /// own grid-snapped stamps and never consults these.
    let presentationSeconds: Double?
    let endSeconds: Double?

    init?(cloning source: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) {
        guard let clone = av_packet_clone(source) else { return nil }
        packet = clone
        let scale = Double(timeBase.num) / Double(max(timeBase.den, 1))
        let stamp = clone.pointee.pts != Int64.min ? clone.pointee.pts : clone.pointee.dts
        if stamp != Int64.min {
            let seconds = Double(stamp) * scale
            presentationSeconds = seconds
            endSeconds = clone.pointee.duration > 0
                ? seconds + Double(clone.pointee.duration) * scale
                : seconds
        } else {
            presentationSeconds = nil
            endSeconds = nil
        }
    }

    deinit {
        var pointer: UnsafeMutablePointer<AVPacket>? = packet
        av_packet_free(&pointer)
    }
}

/// Runs `SoftwareVideoDecoder` on a queue of its own so reading and decoding
/// overlap (HEL-137).
///
/// Until this existed, `FFmpegDemuxer.readNext()` called the software decoder
/// inline, which meant the demux loop stopped reading for as long as a frame
/// took to decode — reading and decoding took turns instead of running
/// together, and both queues drained while a frame was in libavcodec. That
/// never mattered while the software path carried only SD and HD MPEG-2, VC-1
/// and MPEG-4: those decode in a fraction of a frame period, so the
/// serialisation cost nothing visible. 4K AV1 is the first content expensive
/// enough for the serialisation itself to be the problem.
///
/// The shape is deliberately the one `VideoToolboxDecoder` already has: the
/// demux loop submits work and moves on, decoded frames arrive through an
/// output handler, and failures arrive through an error handler. Backpressure
/// stays with the demux loop, which counts `pendingCount` as part of the video
/// it has already asked for (see `DemuxBackpressurePolicy`).
nonisolated final class SoftwareVideoDecodeStage: @unchecked Sendable {
    typealias OutputHandler = @Sendable (CMSampleBuffer) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    private let decoder: SoftwareVideoDecoder
    private let queue = DispatchQueue(
        label: "ee.helop.lagoon.videodecode",
        qos: .userInitiated
    )
    private let outputHandler: OutputHandler
    private let errorHandler: ErrorHandler
    /// Called after every packet leaves the stage, so whoever is blocked on
    /// the combined "video already asked for" count can re-evaluate it.
    private let packetCompletionHandler: @Sendable () -> Void

    /// A condition rather than a plain lock: priming has to be able to wait
    /// for the decoder to catch up, and teardown has to be able to end that
    /// wait.
    private let condition = NSCondition()
    private var mailbox: [SoftwareVideoPacket] = []
    private var inFlight = false
    /// Bumped by every seek and by teardown. Work dispatched before the bump
    /// discards itself rather than publishing frames from the old position.
    private var generation: UInt64 = 0
    private var accepting = true
    private var failed = false

    var decodedFrameBytes: Int64 { decoder.decodedFrameBytes }
    var resolvedThreadCount: Int32 { decoder.resolvedThreadCount }
    var outputsToneMappedSDR: Bool { decoder.outputsToneMappedSDR }
    var gridDescription: String? { decoder.gridDescription }
    var profile: SoftwareVideoDecoder.Profile { decoder.profile }

    /// Packets submitted but not yet decoded, including the one in the
    /// decoder right now. The demux loop adds this to the decoded queue's
    /// depth: both are video it has read and the renderer has not shown.
    var pendingCount: Int {
        condition.withLock { mailbox.count + (inFlight ? 1 : 0) }
    }

    /// Blocks until fewer than `target` packets are outstanding, or until the
    /// stage can no longer make progress (a decode failure, or teardown).
    /// Only the priming pass uses this: it may not start playback on an empty
    /// renderer, and with decode running off the demux queue the cushion it
    /// is waiting for can be entirely inside the decoder.
    func waitUntilPendingBelow(_ target: Int) {
        condition.lock()
        while mailbox.count + (inFlight ? 1 : 0) >= target, accepting, !failed {
            condition.wait()
        }
        condition.unlock()
    }

    init(
        decoder: SoftwareVideoDecoder,
        outputHandler: @escaping OutputHandler,
        errorHandler: @escaping ErrorHandler,
        packetCompletionHandler: @escaping @Sendable () -> Void
    ) {
        self.decoder = decoder
        self.outputHandler = outputHandler
        self.errorHandler = errorHandler
        self.packetCompletionHandler = packetCompletionHandler
    }

    /// Hands one access unit to the decode queue and returns immediately.
    func submit(_ packet: SoftwareVideoPacket) {
        let generation: UInt64? = condition.withLock {
            guard accepting, !failed else { return nil }
            mailbox.append(packet)
            condition.broadcast()
            return self.generation
        }
        guard let generation else { return }
        queue.async { [weak self] in
            self?.decodeNext(generation: generation)
        }
    }

    /// A seek discards everything queued and resets libavcodec's reference
    /// frames, so the next keyframe starts a clean dependency chain. Returns
    /// once the decoder is quiet, which is what lets the caller flush the
    /// render queues behind it without racing a frame still in flight.
    func reset() {
        condition.withLock {
            generation &+= 1
            mailbox.removeAll(keepingCapacity: true)
            failed = false
            condition.broadcast()
        }
        queue.sync { decoder.flush() }
    }

    /// End of file: everything submitted has to be decoded, and then the
    /// frames libavcodec is still holding (frame threading always retains
    /// some) have to come out, before the video queue may be declared
    /// finished.
    func finish() throws {
        var thrown: Error?
        queue.sync {
            guard condition.withLock({ !failed && accepting }) else { return }
            do {
                for buffer in try decoder.drain() {
                    outputHandler(buffer)
                }
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    /// Teardown. Stops accepting work and waits out the frame being decoded,
    /// so the decoder is not released underneath it.
    func invalidate() {
        condition.withLock {
            accepting = false
            generation &+= 1
            mailbox.removeAll(keepingCapacity: true)
            condition.broadcast()
        }
        queue.sync {}
    }

    private func decodeNext(generation: UInt64) {
        let packet: SoftwareVideoPacket? = condition.withLock {
            guard generation == self.generation, !failed, !mailbox.isEmpty else { return nil }
            inFlight = true
            condition.broadcast()
            return mailbox.removeFirst()
        }
        guard let packet else { return }
        // The queue is long-lived, so per-frame Core Media temporaries need
        // an inner pool for the same reason the demux loop's step does.
        autoreleasepool {
            do {
                let frames = try decoder.decode(packet: packet.packet)
                // A seek that landed while this frame was in libavcodec
                // makes it the old position's picture. Drop it.
                if condition.withLock({ generation == self.generation }) {
                    for frame in frames {
                        outputHandler(frame)
                    }
                }
            } catch {
                let alreadyFailed = condition.withLock { () -> Bool in
                    let previous = failed
                    failed = true
                    condition.broadcast()
                    return previous
                }
                if !alreadyFailed {
                    errorHandler(error)
                }
            }
        }
        condition.withLock {
            inFlight = false
            condition.broadcast()
        }
        packetCompletionHandler()
    }
}
