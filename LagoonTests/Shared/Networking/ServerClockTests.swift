import Foundation
import Testing
@testable import Lagoon

/// The arithmetic SyncPlay scheduling rests on. A group's command
/// says "unpause at 11:44:21.356 by my clock", so an offset that is wrong by
/// a tenth of a second is a tenth of a second of desync on every device.
@Suite("Server clock estimate")
struct ServerClockTests {
    /// A symmetric 100 ms round trip against a server five seconds ahead:
    /// the two halves cancel and the offset comes out exactly.
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

    /// Server-side processing is not wire time and must not be counted as
    /// latency: the same trip with 40 ms spent inside the server has the
    /// same offset and a shorter round trip.
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

    /// An asymmetric trip — 90 ms out, 10 ms back — misreads the offset by
    /// half the asymmetry. This is the error the estimate is built to
    /// avoid, and the reason it keeps the fastest sample instead of a mean.
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

    /// The window forgets a measurement taken before the network changed,
    /// however good it was.
    @Test func theWindowHoldsEightSamplesAndDropsTheOldest() {
        var estimate = ServerClockEstimate()
        estimate.record(sample(offset: 1, roundTrip: 0.001))
        for _ in 0..<ServerClockEstimate.capacity {
            estimate.record(sample(offset: 2, roundTrip: 0.5))
        }
        #expect(estimate.samples.count == ServerClockEstimate.capacity)
        #expect(abs((estimate.offset ?? 0) - 2) < 1e-9)
    }

    /// Builds a sample with a chosen offset and round trip, symmetric about
    /// the midpoint so the arithmetic above returns exactly those two.
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
