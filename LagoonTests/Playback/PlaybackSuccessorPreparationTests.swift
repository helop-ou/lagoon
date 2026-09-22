import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

@Suite("Playback successor preparation", .timeLimit(.minutes(1)))
@MainActor
struct PlaybackSuccessorPreparationTests {
    @Test func completedPreparationIsReusedAfterItsTaskFinishes() async throws {
        let expected = try prepared(sourceID: "ready")
        var negotiations = 0
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in negotiations += 1; return expected }
        )
        let staging = StagingSpy()
        defer { subject.cancel() }
        subject.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"),
                        staging: staging.brief, warms: true)
        await waitUntil { !subject.isPreparing }
        #expect(staging.staged.map(\.url) == [expected.streamURL])
        #expect(subject.hasPreparation)

        let result = try #require(await subject.preparedForHandoff())
        #expect(result.source.id == "ready")
        #expect(negotiations == 1)
        #expect(!subject.hasPreparation)
        // Handing the result over must not open a second scope for it: the
        // one staged during negotiation is what the next engine promotes.
        #expect(staging.staged.count == 1)
        #expect(staging.discarded.isEmpty)
    }

    @Test func handoffEndsWarmingWithoutCancellingNegotiation() async throws {
        let expected = try prepared(sourceID: "warming")
        let started = SuccessorTestGate()
        let release = SuccessorTestGate()
        let subject = PlaybackSuccessorPreparation(
            negotiate: { _, _ in
                started.open()
                await release.wait()
                return expected
            }
        )
        let staging = StagingSpy()
        defer { subject.cancel() }
        subject.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"),
                        staging: staging.brief, warms: true)
        await started.wait()
        let handoff = Task { await subject.preparedForHandoff() }
        await waitUntil { staging.endWarmingCount == 1 }
        release.open()

        #expect(await handoff.value?.source.id == "warming")
        // The scope is still opened — the handoff wants what it can get —
        // but the warm-up it would have queued ahead of the handoff is not.
        #expect(staging.staged.map(\.warms) == [false])
        #expect(staging.discarded.isEmpty)
    }

    @Test func forcedPreparationSkipsWarming() async throws {
        let expected = try prepared(sourceID: "forced")
        let subject = PlaybackSuccessorPreparation(negotiate: { _, _ in expected })
        let staging = StagingSpy()
        defer { subject.cancel() }
        subject.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"),
                        staging: staging.brief, warms: false)
        #expect(await subject.preparedForHandoff()?.source.id == "forced")
        #expect(staging.staged.map(\.warms) == [false])
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
            }
        )
        let staging = StagingSpy()
        defer { subject.cancel() }
        let client = JellyfinClient(deviceId: "successor-tests")
        subject.prepare(itemID: old.mediaID, client: client, staging: staging.brief, warms: false)
        await oldStarted.wait()
        let handoffStarted = SuccessorTestGate()
        let oldHandoff = Task {
            handoffStarted.open()
            return await subject.preparedForHandoff()
        }
        await handoffStarted.wait()
        subject.cancel()
        subject.prepare(itemID: replacement.mediaID, client: client, staging: staging.brief, warms: false)
        await newStarted.wait()
        oldRelease.open()
        #expect(await oldHandoff.value == nil)
        #expect(subject.isPreparing)
        // The abandoned generation may finish at any point after its cancel.
        // It staged nothing on its way out, and discarded only once — on the
        // cancel itself, before the replacement could stage anything.
        #expect(staging.staged.isEmpty)
        #expect(staging.discarded == [old.mediaID])
        newRelease.open()
        #expect(await subject.preparedForHandoff()?.source.id == "replacement")
        #expect(staging.staged.map(\.url) == [replacement.streamURL])
        #expect(staging.discarded == [old.mediaID])
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
            }
        )
        let staging = StagingSpy()
        subject?.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"),
                         staging: staging.brief, warms: true)
        await started.wait()
        weak let released = subject
        subject = nil
        #expect(released == nil)
        release.open()
        await finished.wait()
        #expect(staging.staged.isEmpty)
    }

    @Test func releasingOwnerDiscardsItsStagedScope() async throws {
        let expected = try prepared(sourceID: "released")
        var subject: PlaybackSuccessorPreparation? = PlaybackSuccessorPreparation(
            negotiate: { _, _ in expected }
        )
        let staging = StagingSpy()
        subject?.prepare(itemID: expected.mediaID, client: JellyfinClient(deviceId: "successor-tests"),
                         staging: staging.brief, warms: true)
        await waitUntil { !staging.staged.isEmpty }
        weak let released = subject
        subject = nil
        #expect(released == nil)
        #expect(staging.discarded == [expected.mediaID])
    }

    private func prepared(sourceID: String) throws -> PlaybackSuccessorPreparation.PreparedPlayback {
        let data = Data("""
        {"MediaSources":[{"Id":"\(sourceID)","Size":1024,"Container":"mkv"}],"PlaySessionId":"session"}
        """.utf8)
        let info = try JellyfinClient.decoder.decode(PlaybackInfoResponse.self, from: data)
        return .init(mediaID: "episode-2", info: info, source: try #require(info.mediaSources.first),
                     streamURL: URL(string: "https://media.test/\(sourceID).mkv")!, method: .directPlay)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(predicate())
    }
}

/// Stands in for the engine. Every cache decision the preparation used to
/// make now travels through this brief, so the generation rules can be
/// tested without a player.
@MainActor
private final class StagingSpy {
    private(set) var staged: [(id: String, url: URL, warms: Bool)] = []
    private(set) var endWarmingCount = 0
    private(set) var discarded: [String] = []

    var brief: PlaybackSuccessorPreparation.Staging {
        .init(
            stage: { [self] prepared, warms in
                staged.append((prepared.mediaID, prepared.streamURL, warms))
            },
            endWarming: { [self] in endWarmingCount += 1 },
            discard: { [self] itemID in discarded.append(itemID) }
        )
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
