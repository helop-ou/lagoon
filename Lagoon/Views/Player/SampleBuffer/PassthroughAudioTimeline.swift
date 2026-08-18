import CoreMedia

/// Rewrites container timestamps on compressed passthrough audio into a
/// sample-exact timeline (HEL-64).
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
/// `framesPerPacket` samples per packet, re-anchoring only when the
/// container disagrees by more than the gap tolerance (a seek landed
/// mid-stream, or a genuine gap in the source). Codecs whose frame duration
/// is already whole-millisecond (ac3/eac3 at 48 kHz: 32 ms) produce
/// identical timestamps either way, so the rewrite is a no-op for them by
/// construction. If the frames-per-packet assumption is ever wrong for a
/// stream (variable packet durations), the container drifts past the
/// tolerance after the very first packet and every packet re-anchors —
/// i.e. behavior degrades to exactly what shipped before, never worse.
nonisolated struct PassthroughAudioTimeline {
    private let sampleRate: Int32
    private let framesPerPacket: Int64
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

    init(sampleRate: Int32, framesPerPacket: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.framesPerPacket = Int64(max(framesPerPacket, 1))
        gapTolerance = Double(self.framesPerPacket) / Double(self.sampleRate) / 2
    }

    /// Forget the chain (seek/flush) — the next packet re-anchors to its
    /// container pts.
    mutating func reset() {
        nextSampleTime = nil
    }

    /// Sample-exact timing for the next packet, whose container pts is
    /// `containerSeconds` (nil when the packet carries no timestamp:
    /// mid-chain those continue the chain; before any anchor exists they
    /// return nil and the caller keeps its container-derived fallback).
    mutating func timing(containerSeconds: Double?) -> CMSampleTimingInfo? {
        var sampleTime: Int64
        if let expected = nextSampleTime {
            sampleTime = expected
            if let containerSeconds,
               abs(containerSeconds - Double(expected) / Double(sampleRate)) > gapTolerance {
                sampleTime = Int64((containerSeconds * Double(sampleRate)).rounded())
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
