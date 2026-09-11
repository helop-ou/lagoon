import Foundation
import Testing
@testable import Lagoon

@Suite("Playback successor preparation", .timeLimit(.minutes(1)))
@MainActor
struct PlaybackSuccessorPreparationTests {
    @Test func completedPreparationIsReusedAfterItsTaskFinishes() async throws {
        let expected = try prepared(sourceID: "ready")
        var negotiations = 0
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in negotiations += 1; return expected },
            warm: { _, _ in }
        )
        let cache = makeCache()
        defer { subject.cancel(); cache.discardAll() }
        subject.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"), cache: cache,
                        allowsWarming: true, playbackState: { nil })
        await waitUntil { !subject.isPreparing }
        let staged = try #require(cache.next)
        #expect(subject.hasPreparation)

        let result = try #require(await subject.preparedForHandoff())
        #expect(result.source.id == "ready")
        #expect(negotiations == 1)
        #expect(!subject.hasPreparation)
        #expect(cache.activate(itemID: result.mediaID, url: result.streamURL,
                               method: result.method, expectedLength: result.source.size) === staged)
    }

    @Test func handoffCancelsWarmingWithoutCancellingNegotiation() async throws {
        let expected = try prepared(sourceID: "warming")
        let enteredWarm = SuccessorTestGate()
        var cancelledWarm = false
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in expected },
            warm: { _, _ in
                enteredWarm.open()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelledWarm = Task.isCancelled }
            }
        )
        let cache = makeCache()
        defer { subject.cancel(); cache.discardAll() }
        subject.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"), cache: cache,
                        allowsWarming: true, playbackState: { nil })
        await enteredWarm.wait()

        let result = await subject.preparedForHandoff()
        #expect(result?.source.id == "warming")
        #expect(cancelledWarm)
        #expect(cache.next != nil)
    }

    @Test func forcedPreparationSkipsWarming() async throws {
        let expected = try prepared(sourceID: "forced")
        var warms = 0
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in expected },
            warm: { _, _ in warms += 1 }
        )
        let cache = makeCache()
        defer { subject.cancel(); cache.discardAll() }
        subject.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"), cache: cache,
                        allowsWarming: false, playbackState: { nil })
        #expect(await subject.preparedForHandoff()?.source.id == "forced")
        #expect(warms == 0)
    }

    @Test func cancelledNegotiationCannotClearItsReplacement() async throws {
        let old = try prepared(sourceID: "old")
        let replacement = try prepared(sourceID: "replacement")
        let oldStarted = SuccessorTestGate()
        let oldRelease = SuccessorTestGate()
        let newStarted = SuccessorTestGate()
        let newRelease = SuccessorTestGate()
        var negotiations = 0
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in
                negotiations += 1
                if negotiations == 1 {
                    oldStarted.open()
                    await oldRelease.wait() // Deliberately ignores cancellation.
                    return old
                }
                newStarted.open()
                await newRelease.wait()
                return replacement
            },
            warm: { _, _ in }
        )
        let cache = makeCache()
        defer { subject.cancel(); cache.discardAll() }
        let client = JellyfinClient(deviceId: "successor-tests")
        subject.prepare(itemID: old.mediaID, client: client, cache: cache,
                        allowsWarming: false, playbackState: { nil })
        await oldStarted.wait()
        let handoffStarted = SuccessorTestGate()
        let oldHandoff = Task {
            handoffStarted.open()
            return await subject.preparedForHandoff()
        }
        await handoffStarted.wait()
        subject.cancel()
        subject.prepare(itemID: replacement.mediaID, client: client, cache: cache,
                        allowsWarming: false, playbackState: { nil })
        await newStarted.wait()
        oldRelease.open()
        #expect(await oldHandoff.value == nil)
        #expect(subject.isPreparing)
        #expect(cache.next == nil)
        newRelease.open()
        #expect(await subject.preparedForHandoff()?.source.id == "replacement")
        #expect(cache.next?.sourceURL == replacement.streamURL)
    }

    @Test func lateWarmCompletionCannotDiscardSameItemReplacementScope() async throws {
        let old = try prepared(sourceID: "old")
        let replacement = try prepared(sourceID: "replacement")
        let oldStarted = SuccessorTestGate()
        let oldRelease = SuccessorTestGate()
        let newStarted = SuccessorTestGate()
        let newRelease = SuccessorTestGate()
        var negotiations = 0
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in
                negotiations += 1
                return negotiations == 1 ? old : replacement
            },
            warm: { scope, _ in
                if scope?.sourceURL == old.streamURL {
                    oldStarted.open()
                    await oldRelease.wait() // Finishes after a new scope exists.
                } else {
                    newStarted.open()
                    await newRelease.wait()
                }
            }
        )
        let cache = makeCache()
        defer { subject.cancel(); cache.discardAll() }
        let client = JellyfinClient(deviceId: "successor-tests")
        subject.prepare(itemID: old.mediaID, client: client, cache: cache,
                        allowsWarming: true, playbackState: { nil })
        await oldStarted.wait()
        let handoffStarted = SuccessorTestGate()
        let oldHandoff = Task {
            handoffStarted.open()
            return await subject.preparedForHandoff()
        }
        await handoffStarted.wait()
        subject.cancel()
        subject.prepare(itemID: replacement.mediaID, client: client, cache: cache,
                        allowsWarming: true, playbackState: { nil })
        await newStarted.wait()
        let replacementScope = try #require(cache.next)
        oldRelease.open()
        #expect(await oldHandoff.value == nil)
        #expect(subject.isPreparing)
        #expect(cache.next === replacementScope)
        newRelease.open()
        #expect(await subject.preparedForHandoff()?.source.id == "replacement")
        #expect(cache.next === replacementScope)
    }

    @Test func suspendedNegotiationDoesNotRetainItsOwner() async throws {
        let expected = try prepared(sourceID: "late")
        let started = SuccessorTestGate()
        let release = SuccessorTestGate()
        let finished = SuccessorTestGate()
        var subject: PlaybackSuccessorPreparation? = PlaybackSuccessorPreparation(
            negotiate: { _, _ in
                started.open()
                await release.wait()
                finished.open()
                return expected
            },
            warm: { _, _ in }
        )
        let cache = makeCache()
        defer { cache.discardAll() }
        subject?.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"), cache: cache,
                         allowsWarming: true, playbackState: { nil })
        await started.wait()
        weak let released = subject
        subject = nil
        #expect(released == nil)
        release.open()
        await finished.wait()
        #expect(cache.next == nil)
    }

    @Test func releasingOwnerCancelsWarmingAndDiscardsItsStagedScope() async throws {
        let expected = try prepared(sourceID: "released")
        let started = SuccessorTestGate()
        let finished = SuccessorTestGate()
        var cancelled = false
        var subject: PlaybackSuccessorPreparation? = PlaybackSuccessorPreparation(
            negotiate: { _, _ in expected },
            warm: { _, _ in
                started.open()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { cancelled = Task.isCancelled }
                finished.open()
            }
        )
        let cache = makeCache()
        defer { cache.discardAll() }
        subject?.prepare(itemID: expected.mediaID,
                         client: JellyfinClient(deviceId: "successor-tests"), cache: cache,
                         allowsWarming: true, playbackState: { nil })
        await started.wait()
        #expect(cache.next != nil)
        weak let released = subject
        subject = nil
        #expect(released == nil)
        #expect(cache.next == nil)
        await finished.wait()
        #expect(cancelled)
    }

    private func prepared(sourceID: String) throws -> PlaybackSuccessorPreparation.PreparedPlayback {
        let data = Data("""
        {"MediaSources":[{"Id":"\(sourceID)","Size":1024,"Container":"mkv"}],"PlaySessionId":"session"}
        """.utf8)
        let info = try JellyfinClient.decoder.decode(PlaybackInfoResponse.self, from: data)
        return .init(mediaID: "episode-2", info: info, source: try #require(info.mediaSources.first),
                     streamURL: URL(string: "https://media.test/\(sourceID).mkv")!, method: .directPlay)
    }

    private func makeCache() -> PlaybackCacheCoordinator {
        PlaybackCacheCoordinator(
            rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            byteLimit: 1_024, isEnabled: true, allowsTranscodeCaching: false
        )
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(predicate())
    }
}

/// An intentionally cancellation-insensitive dependency, used to prove that
/// late results cannot publish into a replacement preparation generation.
@MainActor
private final class SuccessorTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}
