import CoreMedia

/// Rewrites container timestamps on compressed passthrough audio into a
/// sample-exact timeline.
///
/// Matroska stamps packets at 1 ms precision, but a compressed audio frame
/// is an exact number of samples. AAC is 1024 samples — 21.33 ms at 48 kHz,
/// unrepresentable in whole milliseconds — so trusting each packet's pts
/// hands the renderer a discontinuity on almost every buffer (measured on a
/// real mux: deltas of 21/22/23 ms, up to 1.67 ms off the sample-exact
/// timeline, ~47 packets/s). The renderer aligns its decoded output to
/// those stamps, and every mismatch is a dropped or doubled sliver of
/// samples — audible as steady crackle. `AudioDecoder` fixes exactly this
/// for decoded LPCM; this is the passthrough side of the same fix.
///
/// The chain anchors to the container once, then advances by exactly
/// `framesPerPacket` samples per packet. Forward discontinuities re-anchor
/// the chain, while packets that overlap audio already queued are rejected;
/// an explicit seek or flush resets the chain before its new anchor. Codecs
/// whose frame duration
/// is already whole-millisecond (ac3/eac3 at 48 kHz: 32 ms) produce
/// identical timestamps either way, so the rewrite is a no-op for them by
/// construction. If a stream advances faster than its declared packet size,
/// the container crosses the tolerance and re-anchors rather than accumulating
/// drift; the supported passthrough codecs otherwise have fixed packet sizes.
nonisolated struct PassthroughAudioTimeline {
    let sampleRate: Int32
    let framesPerPacket: Int64
    /// Half a packet: quantization error (≤ ~2 ms measured) sits far
    /// below it, while a genuinely missing packet — one full duration —
    /// sits far above and must re-anchor, or every later buffer would be
    /// early by a packet and audio would hold a permanent desync the
    /// renderer can't hear its way out of. (The LPCM path's fixed 50 ms
    /// would swallow exactly that case for every passthrough codec.)
    private let gapTolerance: Double
    /// Position of the next packet in samples at `sampleRate`; nil before
    /// the first packet and after `reset()`.
    private var nextSampleTime: Int64?
    /// Lets the demuxer distinguish an intentionally rejected overlapping
    /// packet from the ordinary nil result before the first timestamp.
    private(set) var lastPacketWasOverlapping = false
    /// How far behind the chain the last rejected packet sat, in seconds.
    /// The guard exists for boundary repeats a fraction of a packet wide, so
    /// this is what separates that from a real backward discontinuity the
    /// guard is muting instead of re-anchoring.
    private(set) var lastOverlapSeconds: Double = 0

    /// One packet's duration — the unit both the tolerance and any reported
    /// overlap are worth reading in.
    var packetSeconds: Double { Double(framesPerPacket) / Double(sampleRate) }

    init(sampleRate: Int32, framesPerPacket: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.framesPerPacket = Int64(max(framesPerPacket, 1))
        gapTolerance = Double(self.framesPerPacket) / Double(self.sampleRate) / 2
    }

    /// Forget the chain (seek/flush) — the next packet re-anchors to its
    /// container pts.
    mutating func reset() {
        nextSampleTime = nil
        lastPacketWasOverlapping = false
    }

    /// Sample-exact timing for the next packet, whose container pts is
    /// `containerSeconds` (nil when the packet carries no timestamp:
    /// mid-chain those continue the chain; before any anchor exists they
    /// return nil and the caller keeps its container-derived fallback).
    mutating func timing(containerSeconds: Double?) -> CMSampleTimingInfo? {
        lastPacketWasOverlapping = false
        var sampleTime: Int64
        if let expected = nextSampleTime {
            sampleTime = expected
            if let containerSeconds {
                let delta = containerSeconds - Double(expected) / Double(sampleRate)
                if delta < -gapTolerance {
                    // Some segmented AAC sources repeat boundary/preroll
                    // packets with timestamps that sit inside the packet
                    // already queued. Re-anchoring backward enqueues the
                    // overlap and produces an audible cut on tvOS. Keep the
                    // expected position fixed until a non-overlapping packet
                    // arrives; a real seek has already called reset().
                    lastPacketWasOverlapping = true
                    lastOverlapSeconds = -delta
                    return nil
                }
                if delta > gapTolerance {
                    sampleTime = Int64((containerSeconds * Double(sampleRate)).rounded())
                }
            }
        } else if let containerSeconds {
            sampleTime = Int64((containerSeconds * Double(sampleRate)).rounded())
        } else {
            return nil
        }
        nextSampleTime = sampleTime + framesPerPacket
        return CMSampleTimingInfo(
            duration: CMTime(value: framesPerPacket, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: sampleTime, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
    }
}
