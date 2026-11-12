import LagoonEngine
import Testing
@testable import Lagoon

/// The regression journeys read the cache off the probe's value. The probe
/// reads it from the engine itself, so the player never redraws with it.
@Suite("Player regression probe")
struct PlayerRegressionProbeTests {
    @Test func theCacheFieldsReportTheEnginesBuffer() {
        let fields = PlayerRegressionValue.cacheFields(PlaybackBufferState(
            isActive: true,
            bufferedFraction: 0.25,
            bufferedRanges: [
                PlaybackBufferedRange(lowerFraction: 0, upperFraction: 0.1),
                PlaybackBufferedRange(lowerFraction: 0.3, upperFraction: 0.45),
            ],
            playheadPrefetchCount: 3
        ))
        #expect(fields == ["cache=1", "buffered=0.250", "bufferRanges=2", "playheadPrefetches=3"])
    }

    @Test func anUncachedPlaybackSaysSo() {
        #expect(PlayerRegressionValue.cacheFields(.empty)
            == ["cache=0", "buffered=-1.000", "bufferRanges=0", "playheadPrefetches=0"])
    }
}
