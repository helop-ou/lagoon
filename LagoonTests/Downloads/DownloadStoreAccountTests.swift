#if os(iOS)
import Foundation
import Testing
@testable import Lagoon

/// The store's per-account manifest, against a private directory and a
/// foreground session, so the app's own downloads are never touched.
@Suite("Download store accounts", .serialized)
@MainActor
struct DownloadStoreAccountTests {
    private final class Owner {}

    private let base = FileManager.default.temporaryDirectory
        .appending(path: "DownloadStoreAccountTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeStore() -> DownloadStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnansweredProtocol.self]
        return DownloadStore(baseDirectory: base, sessionConfiguration: configuration)
    }

    private func directory(for accountID: String) -> URL {
        base.appending(path: DownloadStore.accountKey(for: accountID), directoryHint: .isDirectory)
    }

    private func storeManifest(_ itemIDs: [String], for accountID: String) throws {
        var manifest = DownloadManifest()
        for id in itemIDs { manifest.insert(DownloadManifestTests.makeEntry(id: id)) }
        try FileManager.default.createDirectory(at: directory(for: accountID), withIntermediateDirectories: true)
        DownloadStore.saveManifest(manifest, at: directory(for: accountID).appending(path: "manifest.json"))
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }

    @Test func aNilActivationFromAnotherOwnerIsIgnored() throws {
        defer { cleanUp() }
        try storeManifest(["item1"], for: "a")
        let store = makeStore()
        let owner = Owner()
        let stray = Owner()

        store.activate(accountID: "a", owner: ObjectIdentifier(owner))
        store.activate(accountID: nil, owner: ObjectIdentifier(stray))
        #expect(store.accountID == "a")
        #expect(store.entries.map(\.itemID) == ["item1"])

        store.activate(accountID: nil, owner: ObjectIdentifier(owner))
        #expect(store.accountID == nil)
        #expect(store.entries.isEmpty)
    }

    @Test func removingTheActiveAccountDeletesItsFilesAndTransfers() async throws {
        defer { cleanUp() }
        try storeManifest(["item1"], for: "a")
        let store = makeStore()
        let owner = Owner()
        store.activate(accountID: "a", owner: ObjectIdentifier(owner))
        let key = DownloadStore.accountKey(for: "a")
        let transfer = store.session.downloadTask(with: URL(string: "https://downloads.invalid/item1")!)
        transfer.taskDescription = DownloadTaskDescription(
            itemID: "item1", fileName: "item1.mp4", accountKey: key, attemptToken: "attempt"
        ).raw
        let other = store.session.downloadTask(with: URL(string: "https://downloads.invalid/item2")!)
        other.taskDescription = DownloadTaskDescription(
            itemID: "item2", fileName: "item2.mp4", accountKey: "other", attemptToken: "attempt"
        ).raw
        transfer.resume()
        other.resume()
        defer { other.cancel() }

        store.removeAll(forAccountKey: key)
        try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
            store.entries.isEmpty
        }

        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory(for: "a").path))
        #expect(transfer.state != .running)
        #expect(other.state == .running)
    }

    @Test func removingAnotherAccountLeavesTheActiveOneAlone() async throws {
        defer { cleanUp() }
        try storeManifest(["item1"], for: "a")
        try storeManifest(["item2"], for: "b")
        let store = makeStore()
        let owner = Owner()
        store.activate(accountID: "a", owner: ObjectIdentifier(owner))

        store.removeAll(forAccountKey: DownloadStore.accountKey(for: "b"))
        try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
            !FileManager.default.fileExists(atPath: directory(for: "b").path)
        }

        #expect(!FileManager.default.fileExists(atPath: directory(for: "b").path))
        #expect(store.entries.map(\.itemID) == ["item1"])
        #expect(FileManager.default.fileExists(atPath: directory(for: "a").appending(path: "manifest.json").path))
    }
}

/// Keeps every transfer running until it is cancelled.
private nonisolated final class UnansweredProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
#endif
