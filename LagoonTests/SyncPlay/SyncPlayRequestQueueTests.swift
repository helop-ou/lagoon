import Foundation
import Testing
@testable import Lagoon

@Suite("SyncPlay request ownership")
@MainActor
struct SyncPlayRequestQueueTests {
    @Test func requestsPreserveSeekThenPlayOrder() async {
        let queue = SyncPlayRequestQueue()
        let started = Gate()
        let release = Gate()
        var events: [String] = []
        queue.enqueue {
            events.append("seek")
            started.open()
            await release.wait()
        }
        let play = queue.enqueue { events.append("play") }
        await started.wait()
        #expect(events == ["seek"])
        release.open()
        await play.value
        #expect(events == ["seek", "play"])
    }

    @Test func detachingCancelsEveryQueuedCommandAndAllowsNewAttachment() async {
        let queue = SyncPlayRequestQueue()
        let started = Gate()
        let release = Gate()
        var events: [String] = []
        let first = queue.enqueue {
            started.open()
            // Ignores cancellation; pending successors must still stop.
            await release.wait()
            #expect(Task.isCancelled)
        }
        queue.enqueue { events.append("stale pause") }
        let last = queue.enqueue { events.append("stale play") }
        await started.wait()
        queue.cancel()
        let replacement = queue.enqueue { events.append("new seek") }
        await replacement.value
        #expect(events == ["new seek"])
        release.open()
        await first.value
        await last.value
        #expect(events == ["new seek"])
    }

    @Test func failedRequestDoesNotBlockLaterCommands() async {
        let queue = SyncPlayRequestQueue()
        var nextRan = false
        var attempts = 0
        queue.enqueue {
            attempts += 1
            throw URLError(.cannotConnectToHost)
        }
        let next = queue.enqueue { nextRan = true }
        await next.value
        #expect(nextRan)
        #expect(attempts == 1)
    }

    @Test func failureIsReportedButCancellationIsQuiet() async {
        let queue = SyncPlayRequestQueue()
        var failures = 0
        let failed = queue.enqueue({ throw URLError(.cannotConnectToHost) }, onFailure: { failures += 1 })
        await failed.value
        #expect(failures == 1)
        let cancelled = queue.enqueue({ throw CancellationError() }, onFailure: { failures += 1 })
        queue.cancel()
        await cancelled.value
        #expect(failures == 1)
    }

    @Test func cancellingBeforeExecutionSendsNothing() async {
        let queue = SyncPlayRequestQueue()
        var sent = false
        let request = queue.enqueue { sent = true }
        queue.cancel()
        await request.value
        #expect(!sent)
    }

    @Test func readinessRetriesOnceAndThenReleasesTheQueue() async {
        let queue = SyncPlayRequestQueue()
        var attempts = 0
        var failures = 0
        var followerRan = false
        queue.enqueue({
            attempts += 1
            throw URLError(.networkConnectionLost)
        }, retryDelay: .zero, onFailure: { failures += 1 })
        let follower = queue.enqueue { followerRan = true }
        await follower.value
        #expect(attempts == 2)
        #expect(failures == 1)
        #expect(followerRan)
    }

    @Test func readinessCanRecoverOnItsSingleRetry() async {
        let queue = SyncPlayRequestQueue()
        var attempts = 0
        var failures = 0
        let request = queue.enqueue({
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
        }, retryDelay: .zero, onFailure: { failures += 1 })
        await request.value
        #expect(attempts == 2)
        #expect(failures == 0)
    }

    @Test func detachingPreventsAReadinessRetry() async {
        let queue = SyncPlayRequestQueue()
        let started = Gate()
        let release = Gate()
        var attempts = 0
        var failures = 0
        let request = queue.enqueue({
            attempts += 1
            started.open()
            await release.wait()
            throw URLError(.networkConnectionLost)
        }, retryDelay: .zero, onFailure: { failures += 1 })
        await started.wait()
        queue.cancel()
        release.open()
        await request.value
        #expect(attempts == 1)
        #expect(failures == 0)
    }

    private final class Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            let continuations = waiting
            waiting.removeAll()
            continuations.forEach { $0.resume() }
        }
    }
}
