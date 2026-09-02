import Foundation
import Testing
@testable import Lagoon

/// HEL-137: the GPU output stage delivers frames from Metal's completion
/// threads, which promise no order, into a renderer that needs decode
/// order. The sequencer is the whole guarantee, so it is pinned here.
struct GPUDeliverySequencerTests {
    @Test func completionsAreDeliveredInReservationOrderWhateverOrderTheyArrive() {
        let sequencer = GPUDeliverySequencer(capacity: 3)
        let first = sequencer.reserve()
        let second = sequencer.reserve()
        let third = sequencer.reserve()
        let delivered = Delivered()

        sequencer.complete(third) { delivered.append(third) }
        #expect(delivered.values.isEmpty, "a frame ahead of its predecessors must wait")
        sequencer.complete(first) { delivered.append(first) }
        #expect(delivered.values == [first])
        sequencer.complete(second) { delivered.append(second) }
        #expect(delivered.values == [first, second, third])
        #expect(sequencer.pendingCount == 0)
    }

    @Test func capacityBlocksReservationsUntilAFrameIsDelivered() {
        let sequencer = GPUDeliverySequencer(capacity: 2)
        let first = sequencer.reserve()
        _ = sequencer.reserve()
        #expect(sequencer.pendingCount == 2)

        let reserved = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = sequencer.reserve()
            reserved.signal()
        }
        #expect(reserved.wait(timeout: .now() + 0.3) == .timedOut, "a third frame must wait for capacity")
        sequencer.complete(first) {}
        #expect(reserved.wait(timeout: .now() + 2) == .success, "delivering a frame frees a slot")
        #expect(sequencer.pendingCount == 2)
    }

    @Test func drainingWaitsForEveryOutstandingFrameAndGivesUpOnTime() {
        let sequencer = GPUDeliverySequencer(capacity: 3)
        let only = sequencer.reserve()
        #expect(sequencer.waitUntilDrained(timeout: 0.2) == false)

        let started = Date()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.1)
            sequencer.complete(only) {}
        }
        #expect(sequencer.waitUntilDrained(timeout: 2))
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(sequencer.pendingCount == 0)
    }

    @Test func aFailedSubmissionCompletesEmptyAndLaterFramesStillFlow() {
        let sequencer = GPUDeliverySequencer(capacity: 3)
        let failed = sequencer.reserve()
        let next = sequencer.reserve()
        let delivered = Delivered()

        sequencer.complete(next) { delivered.append(next) }
        #expect(delivered.values.isEmpty)
        sequencer.complete(failed) {}
        #expect(delivered.values == [next])
        #expect(sequencer.pendingCount == 0)
    }

    private final class Delivered: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt64] = []
        var values: [UInt64] { lock.withLock { storage } }
        func append(_ value: UInt64) { lock.withLock { storage.append(value) } }
    }
}
