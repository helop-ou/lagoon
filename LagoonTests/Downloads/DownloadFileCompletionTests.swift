import Foundation
import Testing
@testable import Lagoon

@MainActor
@Suite("Download file completion")
struct DownloadFileCompletionTests {
    private func fixture() throws -> (directory: URL, manifest: DownloadManifest, info: DownloadTaskDescription) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "download-completion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = DownloadManifest()
        manifest.insert(DownloadManifestTests.makeEntry())
        manifest.markStarted("item1", taskIdentifier: 2, attemptToken: "current")
        let info = DownloadTaskDescription(itemID: "item1", fileName: "item1.mp4", accountKey: "account", attemptToken: "current")
        return (directory, manifest, info)
    }

    @Test func staleCompletionCannotReplaceNewerAttemptsFile() throws {
        let (directory, initialManifest, _) = try fixture()
        var manifest = initialManifest
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "item1.mp4")
        let temporary = directory.appending(path: "incoming")
        try Data("replacement".utf8).write(to: destination)
        try Data("stale".utf8).write(to: temporary)
        let stale = DownloadTaskDescription(itemID: "item1", fileName: "item1.mp4", accountKey: "account", attemptToken: "old")
        let before = manifest

        DownloadFileCompletion.apply(info: stale, status: 200, location: temporary, directory: directory, manifest: &manifest)

        #expect(try Data(contentsOf: destination) == Data("replacement".utf8))
        #expect(manifest == before)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func completionPreservesUnrelatedInMemoryChanges() throws {
        let (directory, initialManifest, info) = try fixture()
        var manifest = initialManifest
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appending(path: "incoming")
        try Data("video".utf8).write(to: temporary)
        manifest.recordPosition("item1", ticks: 123)
        let report = PendingPlaybackReport(itemID: "other", mediaSourceID: "source", positionTicks: 456, createdAt: Date())
        manifest.enqueue(report)

        DownloadFileCompletion.apply(info: info, status: 200, location: temporary, directory: directory, manifest: &manifest)

        #expect(manifest.entry(for: "item1")?.isComplete == true)
        #expect(manifest.entry(for: "item1")?.receivedBytes == 5)
        #expect(manifest.entry(for: "item1")?.localPositionTicks == 123)
        #expect(manifest.pendingReports == [report])
        #expect(try Data(contentsOf: directory.appending(path: "item1.mp4")) == Data("video".utf8))
    }

    @Test func removedAccountDirectoryIsNeverRecreated() throws {
        let (directory, initialManifest, info) = try fixture()
        var manifest = initialManifest
        try FileManager.default.removeItem(at: directory)
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Data("video".utf8).write(to: temporary)
        let before = manifest

        DownloadFileCompletion.apply(info: info, status: 200, location: temporary, directory: directory, manifest: &manifest)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(manifest == before)
    }

    @Test func failureDiscardsResponseAndDoesNotPublishMediaFile() throws {
        let (directory, initialManifest, info) = try fixture()
        var manifest = initialManifest
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appending(path: "incoming")
        try Data("forbidden".utf8).write(to: temporary)

        DownloadFileCompletion.apply(info: info, status: 403, location: temporary, directory: directory, manifest: &manifest)

        #expect(manifest.entry(for: "item1")?.state == .failed)
        #expect(manifest.entry(for: "item1")?.failure == "Not permitted by the server")
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "item1.mp4").path))
    }

    @Test func currentAttemptReplacesAnExistingDestination() throws {
        let (directory, initialManifest, info) = try fixture()
        var manifest = initialManifest
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "item1.mp4")
        let temporary = directory.appending(path: "incoming")
        try Data("prior bytes".utf8).write(to: destination)
        try Data("new video".utf8).write(to: temporary)

        DownloadFileCompletion.apply(info: info, status: 200, location: temporary, directory: directory, manifest: &manifest)

        #expect(try Data(contentsOf: destination) == Data("new video".utf8))
        #expect(manifest.entry(for: "item1")?.state == .complete)
        #expect(manifest.entry(for: "item1")?.receivedBytes == 9)
    }

    @Test func duplicateCompletionCannotReplaceFinishedFile() throws {
        let (directory, initialManifest, info) = try fixture()
        var manifest = initialManifest
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appending(path: "incoming")
        try Data("video".utf8).write(to: temporary)
        DownloadFileCompletion.apply(info: info, status: 200, location: temporary, directory: directory, manifest: &manifest)
        try Data("duplicate".utf8).write(to: temporary)

        DownloadFileCompletion.apply(info: info, status: 200, location: temporary, directory: directory, manifest: &manifest)

        #expect(try Data(contentsOf: directory.appending(path: "item1.mp4")) == Data("video".utf8))
        #expect(manifest.entry(for: "item1")?.receivedBytes == 5)
    }
}
