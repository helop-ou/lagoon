import CoreMedia

/// Rewrites container timestamps on video packets onto an exact frame
/// grid, removing mux quantization before decode and scheduling.
///
/// Matroska stamps video packets at 1 ms precision, but a 23.976 fps
/// frame lasts 1001/24000 s = 41.708 ms — unrepresentable in whole
/// milliseconds — so every pts reaches the renderer up to ~0.5 ms (and
/// measured muxes a further ms) off the true frame grid. At 60 Hz output
/// the 16.7 ms vsync bins swallow that. On a display *matched* to the
/// content rate there is exactly one vsync per frame and little scheduling
/// slack. Hardware A/Bs later proved this quantization was not the cause of
/// the measured 10% loss, but retaining exact stamps avoids adding jitter
/// to either the compressed H.264 or decoded HEVC presentation path.
///
/// Video needs a different chaining shape than audio: packets arrive in
/// decode order, so presentation stamps step backwards and forwards by
/// whole frames (B-frame reordering). Each stamp is therefore snapped to
/// the nearest whole-frame step from the previous snapped stamp — exact
/// integer arithmetic in the frame rate's own timescale, so consecutive
/// steps can never drift — and a stamp that lands farther than the
/// tolerance from its snapped position (variable frame rate, broken mux)
/// passes through untouched and re-anchors the chain, degrading to
/// exactly the behavior that shipped before, never worse.
nonisolated struct VideoFrameTimeline {
    /// Comfortably above measured mux sloppiness (≤ ~2 ms) and far below
    /// half a frame period (≥ 8 ms at 60 fps): inside is quantization,
    /// outside is a genuinely off-grid stamp.
    static let tolerance = 0.005

    /// Frame rate as the exact rational fps = num/den — the timescale is
    /// `num` so one frame duration is exactly `den` ticks.
    private let num: Int32
    private let den: Int64
    /// The previous frame's snapped pts in ticks at timescale `num`; nil
    /// before the first frame and after `reset()`.
    private var previousTicks: Int64?

    /// nil when the rate can't form a usable grid.
    init?(frameRateNum: Int32, frameRateDen: Int32) {
        guard frameRateNum > 0, frameRateDen > 0 else { return nil }
        let fps = Double(frameRateNum) / Double(frameRateDen)
        guard fps >= 1, fps <= 240 else { return nil }
        num = frameRateNum
        den = Int64(frameRateDen)
    }

    /// One frame, exactly, in the grid's timescale.
    var frameDuration: CMTime {
        CMTime(value: den, timescale: num)
    }

    /// For the HUD's gate check: which grid is in force.
    var gridDescription: String {
        "\(num)/\(den)"
    }

    /// Forget the chain (seek/flush) — the next frame re-anchors.
    mutating func reset() {
        previousTicks = nil
    }

    /// The container pts snapped onto the frame grid, or nil for a stamp
    /// too far off it (the caller keeps the container timing for that
    /// frame). Packets arrive in decode order; steps are signed whole
    /// frames from the previous snapped stamp.
    mutating func snapped(containerSeconds: Double) -> CMTime? {
        let rawTicks = (containerSeconds * Double(num)).rounded()
        guard let previous = previousTicks else {
            let anchor = Int64(rawTicks)
            previousTicks = anchor
            return CMTime(value: anchor, timescale: num)
        }
        let steps = ((rawTicks - Double(previous)) / Double(den)).rounded()
        let candidate = previous + Int64(steps) * den
        let error = abs(Double(candidate) / Double(num) - containerSeconds)
        guard error <= Self.tolerance, candidate != previous else {
            // Off the grid (VFR, duplicate stamp, broken mux): pass this
            // frame through and re-anchor the chain on its position.
            previousTicks = Int64(rawTicks)
            return nil
        }
        previousTicks = candidate
        return CMTime(value: candidate, timescale: num)
    }
}
