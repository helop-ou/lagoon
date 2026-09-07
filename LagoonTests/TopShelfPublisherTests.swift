import Foundation
import Testing
@testable import Lagoon

@Suite("Top Shelf account isolation", .serialized)
@MainActor
struct TopShelfPublisherTests {
    @Test func delayedArtworkCannotRepublishAfterSwitchOrDeleteNewArtwork() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let a = "https://first.test|same-user"
        let b = "https://second.test|same-user"
        fixture.publisher.activate(accountID: a)
        let gate = Gate()
        let pending = try #require(fixture.publisher.publish(owner: owner(a)) { stage, _ in
            await gate.wait()
            return try payload(stage, title: "Private A")
        })
        try await gate.waitUntilBlocked()
        fixture.publisher.activate(accountID: b)
        await fixture.publisher.publish(owner: owner(b)) { stage, _ in try payload(stage, title: "Private B") }?.value
        let published = try #require(fixture.publisher.snapshot)
        let notifications = fixture.notifications
        gate.release()
        await pending.value
        #expect(fixture.publisher.snapshot == published)
        #expect(fixture.publisher.snapshot?.items.first?.title == "Private B")
        #expect(fixture.notifications == notifications)
        #expect(fixture.artworkTitles == ["Private B", "Private B"])
        #expect(!fixture.publisher.accepts(owner: owner(a), generation: published.generation, itemID: "same-item"))
        #expect(fixture.publisher.accepts(owner: owner(b), generation: published.generation, itemID: "same-item"))
    }

    @Test func logoutInvalidatesAlreadyPublishedLinksAndAnUncooperativeRenderer() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publisher.activate(accountID: "a")
        await fixture.publisher.publish(owner: owner("a")) { stage, _ in try payload(stage, title: "Private") }?.value
        let old = try #require(fixture.publisher.snapshot)
        let gate = Gate()
        let task = try #require(fixture.publisher.publish(owner: owner("a")) { stage, _ in
            await gate.wait()
            return try payload(stage, title: "Late private artwork")
        })
        try await gate.waitUntilBlocked()
        fixture.publisher.activate(accountID: nil)
        let notifications = fixture.notifications
        #expect(!fixture.publisher.accepts(owner: old.owner, generation: old.generation, itemID: "same-item"))
        gate.release()
        await task.value
        #expect(fixture.publisher.snapshot == nil)
        #expect(fixture.artworkTitles.isEmpty)
        #expect(fixture.notifications == notifications)
    }

    @Test func latestSameAccountPublisherWinsWithoutIncrementalSnapshots() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publisher.activate(accountID: "a")
        await fixture.publisher.publish(owner: owner("a")) { stage, _ in try payload(stage, title: "Initial") }?.value
        let gate = Gate()
        let delayed = try #require(fixture.publisher.publish(owner: owner("a")) { stage, _ in
            let items = try payload(stage, title: "Old refresh")
            await gate.wait()
            return items
        })
        try await gate.waitUntilBlocked()
        #expect(fixture.publisher.snapshot?.items.first?.title == "Initial")
        await fixture.publisher.publish(owner: owner("a")) { stage, _ in try payload(stage, title: "Latest") }?.value
        gate.release()
        await delayed.value
        #expect(fixture.publisher.snapshot?.items.first?.title == "Latest")
        #expect(fixture.artworkTitles == ["Latest", "Latest"])
    }

    @Test func failedRefreshKeepsSnapshotAndAuthoritativeEmptyClearsIt() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publisher.activate(accountID: "a")
        await fixture.publisher.publish(owner: owner("a")) { stage, _ in try payload(stage, title: "Keep") }?.value
        let snapshot = fixture.publisher.snapshot
        let notifications = fixture.notifications
        await fixture.publisher.publish(owner: owner("a")) { _, _ in throw URLError(.notConnectedToInternet) }?.value
        #expect(fixture.publisher.snapshot == snapshot)
        #expect(fixture.notifications == notifications)
        await fixture.publisher.publish(owner: owner("a")) { _, _ in [] }?.value
        #expect(fixture.publisher.snapshot == nil)
        #expect(fixture.artworkTitles.isEmpty)
        #expect(fixture.notifications == notifications + 1)
    }

    @Test func coldLaunchReusesOnlyTheRestoredAccountsSnapshot() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publisher.activate(accountID: "a")
        await fixture.publisher.publish(owner: owner("a")) { stage, _ in try payload(stage, title: "A") }?.value
        let restored = TopShelfPublisher(directory: fixture.directory)
        restored.activate(accountID: "a")
        #expect(restored.snapshot?.items.first?.title == "A")
        let signedOut = TopShelfPublisher(directory: fixture.directory)
        signedOut.activate(accountID: nil)
        #expect(signedOut.snapshot == nil)
        #expect(fixture.artworkTitles.isEmpty)
    }

    private func owner(_ account: String) -> String { TopShelfPublisher.accountOwner(account) }

    private func payload(_ stage: URL, title: String) throws -> [TopShelfStore.Item] {
        // Deliberately recreate even a deleted directory, like work that
        // ignores cancellation. The publisher must still discard its result.
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for name in ["same-item@1x.jpg", "same-item@2x.jpg"] {
            try Data(title.utf8).write(to: stage.appendingPathComponent(name))
        }
        return [TopShelfStore.Item(id: "same-item", title: title, context: title,
                                  artwork2x: "\(stage.lastPathComponent)/same-item@2x.jpg",
                                  artwork1x: "\(stage.lastPathComponent)/same-item@1x.jpg",
                                  summary: title, genre: "Drama", duration: 120, mediaOptions: nil)]
    }

    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var notifications = 0
        lazy var publisher = TopShelfPublisher(directory: directory) { [weak self] in self?.notifications += 1 }
        var artworkTitles: [String] {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            return (files?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jpg" }
                .compactMap { try? String(contentsOf: $0, encoding: .utf8) }.sorted()
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
        func waitUntilBlocked() async throws {
            for _ in 0..<200 {
                if continuation != nil { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("The publisher did not reach the delayed artwork")
            throw CancellationError()
        }
    }
}
