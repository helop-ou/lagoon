import Foundation
import Testing
@testable import Lagoon

/// SyncPlay commands name server-clock instants, so any offset error is desync.
@Suite("Server clock estimate")
struct ServerClockTests {
    /// A symmetric 100 ms round trip against a server five seconds ahead.
    @Test func aSymmetricRoundTripRecoversTheOffsetExactly() {
        let sample = ServerClockSample(
            requestSent: 1_000.0,
            requestReceived: 1_005.05,
            responseSent: 1_005.05,
            responseReceived: 1_000.1
        )
        #expect(abs(sample.offset - 5) < 1e-9)
        #expect(abs(sample.roundTrip - 0.1) < 1e-9)
    }

    /// 40 ms spent inside the server: same offset, shorter round trip.
    @Test func theServersOwnProcessingIsNotLatency() {
        let sample = ServerClockSample(
            requestSent: 1_000.0,
            requestReceived: 1_005.03,
            responseSent: 1_005.07,
            responseReceived: 1_000.1
        )
        #expect(abs(sample.offset - 5) < 1e-9)
        #expect(abs(sample.roundTrip - 0.06) < 1e-9)
    }

    /// 90 ms out, 10 ms back. This error is why the estimate keeps the
    /// fastest sample, not a mean.
    @Test func anAsymmetricTripMisreadsTheOffsetByHalfTheAsymmetry() {
        let sample = ServerClockSample(
            requestSent: 1_000.0,
            requestReceived: 1_005.09,
            responseSent: 1_005.09,
            responseReceived: 1_000.1
        )
        #expect(abs(sample.offset - 5.04) < 1e-9)
    }

    @Test func theBestSampleIsTheFastestOneNotTheAverage() {
        var estimate = ServerClockEstimate()
        estimate.record(sample(offset: 5.04, roundTrip: 0.9))
        estimate.record(sample(offset: 5.00, roundTrip: 0.05))
        estimate.record(sample(offset: 4.90, roundTrip: 0.4))

        let best = estimate.best
        #expect(abs((best?.roundTrip ?? 0) - 0.05) < 1e-9)
        #expect(abs((estimate.offset ?? 0) - 5.00) < 1e-9)
        #expect(abs((estimate.ping ?? 0) - 0.025) < 1e-9)
    }

    @Test func thereIsNoEstimateBeforeTheFirstSample() {
        let estimate = ServerClockEstimate()
        #expect(estimate.best == nil)
        #expect(estimate.offset == nil)
        #expect(estimate.ping == nil)
    }

    @Test func theWindowHoldsEightSamplesAndDropsTheOldest() {
        var estimate = ServerClockEstimate()
        estimate.record(sample(offset: 1, roundTrip: 0.001))
        for _ in 0..<ServerClockEstimate.capacity {
            estimate.record(sample(offset: 2, roundTrip: 0.5))
        }
        #expect(estimate.samples.count == ServerClockEstimate.capacity)
        #expect(abs((estimate.offset ?? 0) - 2) < 1e-9)
    }

    /// A symmetric sample with exactly this offset and round trip.
    private func sample(offset: Double, roundTrip: Double) -> ServerClockSample {
        let sent = 1_000.0
        let received = sent + roundTrip
        let atServer = sent + roundTrip / 2 + offset
        return ServerClockSample(
            requestSent: sent,
            requestReceived: atServer,
            responseSent: atServer,
            responseReceived: received
        )
    }
}
