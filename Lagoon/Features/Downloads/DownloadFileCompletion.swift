import Foundation
import os

/// Commits a finished transfer on the same actor as the store's commands.
/// The temporary file must be consumed before URLSession's delegate returns;
/// no suspension is allowed between checking the attempt and replacing its file.
@MainActor
enum DownloadFileCompletion {
    private static let log = Logger(subsystem: "ee.helop.lagoon", category: "downloads")

    static func apply(
        info: DownloadTaskDescription, status: Int, location: URL,
        directory: URL, manifest: inout DownloadManifest
    ) {
        let manager = FileManager.default
        defer { try? manager.removeItem(at: location) }
        guard let entry = manifest.entry(for: info.itemID),
              entry.attemptToken == info.attemptToken, entry.fileName == info.fileName,
              !entry.isComplete, manager.fileExists(atPath: directory.path) else { return }

        let bytes = (try? manager.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        switch DownloadCompletion.outcome(
            status: status, bytesOnDisk: bytes, expectedBytes: entry.expectedBytes, quality: entry.quality
        ) {
        case .complete(let completedBytes):
            do {
                let destination = directory.appending(path: entry.fileName)
                if manager.fileExists(atPath: destination.path) {
                    _ = try manager.replaceItemAt(destination, withItemAt: location)
                } else {
                    try manager.moveItem(at: location, to: destination)
                }
                manifest.markComplete(info.itemID, bytes: completedBytes, at: Date())
            } catch {
                log.error("persist completed download: \(error.localizedDescription, privacy: .public)")
                manifest.markFailed(info.itemID, reason: String(localized: "Couldn't save the downloaded file"), resumeDataFile: nil)
            }
        case .failed(let reason):
            manifest.markFailed(info.itemID, reason: reason, resumeDataFile: nil)
        }
    }
}
