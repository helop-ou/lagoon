import Foundation

/// Keeps GPU-converted frames in decode order and bounds how many are in
/// flight (HEL-137).
///
/// The decode queue reserves a slot per frame before it submits the kernel
/// and moves on; the GPU's completions arrive on their own threads and in
/// no promised order. `complete` runs each frame's delivery only once every
/// earlier frame has been delivered, holding the early ones, so the renderer
/// sees frames in the order libavcodec produced them. `reserve` blocks once
/// `capacity` frames are outstanding, which is the only backpressure the GPU
/// stage needs: a slow GPU stalls the decode queue instead of piling up
/// pictures.
nonisolated final class GPUDeliverySequencer: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var inFlight = 0
    private var nextToReserve: UInt64 = 0
    private var nextToDeliver: UInt64 = 0
    private var held: [UInt64: () -> Void] = [:]

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    /// Frames reserved and not yet delivered.
    var pendingCount: Int {
        condition.withLock { inFlight }
    }

    /// Blocks while `capacity` frames are outstanding, then returns the
    /// sequence number the caller must complete.
    func reserve() -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        while inFlight >= capacity {
            condition.wait()
        }
        inFlight += 1
        let sequence = nextToReserve
        nextToReserve += 1
        return sequence
    }

    /// Delivers `sequence` in order: runs `body` now if every earlier frame
    /// has been delivered, otherwise holds it until they have. A reservation
    /// that never reached the GPU completes with an empty body, so a failed
    /// submission cannot hold every later frame hostage.
    func complete(_ sequence: UInt64, _ body: @escaping () -> Void) {
        condition.lock()
        held[sequence] = body
        var ready: [() -> Void] = []
        while let next = held.removeValue(forKey: nextToDeliver) {
            ready.append(next)
            nextToDeliver += 1
        }
        condition.unlock()
        for deliver in ready {
            deliver()
        }
        condition.withLock {
            inFlight -= ready.count
            condition.broadcast()
        }
    }

    /// Waits until nothing is outstanding. Bounded, because a GPU that never
    /// answers must not wedge a seek or a teardown; returns whether it did
    /// drain.
    @discardableResult
    func waitUntilDrained(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while inFlight > 0 {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}
