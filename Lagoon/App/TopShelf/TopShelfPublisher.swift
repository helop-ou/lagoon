import CryptoKit
import Foundation

/// One serial commit point for the app/extension snapshot. Rendering may
/// finish after cancellation, but it can only write its unique staging tree.
@MainActor
final class TopShelfPublisher {
    nonisolated struct Snapshot: Codable, Equatable {
        let owner: String
        let generation: UUID
        let publishedAt: Date
        let items: [TopShelfStore.Item]
    }

    nonisolated static let snapshotName = "snapshot-v2.json"
    let directory: URL
    private(set) var owner: String?
    private(set) var lastResult: String?
    private(set) var lastAttempt: Date?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var hasActivated = false
    private let notify: () -> Void

    init(directory: URL, notify: @escaping () -> Void = {}) {
        self.directory = directory
        self.notify = notify
    }

    nonisolated static func accountOwner(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var snapshot: Snapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.snapshotName)),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data), value.owner == owner else { return nil }
        return value
    }

    func activate(accountID: String?) {
        let next = accountID.map(Self.accountOwner)
        guard !hasActivated || next != owner else { return }
        hasActivated = true
        task?.cancel()
        generation = UUID()
        owner = next
        // A same-account cold launch may reuse a complete snapshot. Anything
        // owned by another account, including the legacy unowned format, goes.
        if snapshot == nil { clear() }
    }

    func clear() {
        task?.cancel()
        task = nil
        generation = UUID()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.snapshotName))
        removeDirectories(except: nil)
        lastResult = "Continue Watching is empty"
        lastAttempt = .now
        notify()
    }

    /// The operation must return only fully written images beneath `stage`.
    /// A successful empty result clears; throwing retains the last snapshot.
    @discardableResult
    func publish(owner requestedOwner: String,
                 operation: @escaping (URL, Snapshot?) async throws -> [TopShelfStore.Item]) -> Task<Void, Never>? {
        guard owner == requestedOwner else { return nil }
        task?.cancel()
        let ticket = UUID()
        generation = ticket
        let previous = snapshot
        let name = "\(requestedOwner)-\(ticket.uuidString)"
        let stage = directory.appendingPathComponent(name, isDirectory: true)
        task = Task {
            defer {
                // A stale writer may clean only its own directory. It never
                // deletes a newer publisher's artwork or committed manifest.
                if snapshot?.generation != ticket { try? FileManager.default.removeItem(at: stage) }
            }
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let items = try await operation(stage, previous)
                try Task.checkCancellation()
                guard owner == requestedOwner, generation == ticket else { return }
                if items.isEmpty { clear(); return }
                let value = Snapshot(owner: requestedOwner, generation: ticket, publishedAt: .now, items: items)
                let data = try JSONEncoder().encode(value)
                // No suspension from identity validation through commit and
                // notification. Extension readers see a whole old or new file.
                try data.write(to: directory.appendingPathComponent(Self.snapshotName), options: .atomic)
                removeDirectories(except: name)
                lastAttempt = .now
                lastResult = "Published \(items.count) titles"
                notify()
            } catch is CancellationError {
            } catch {
                guard owner == requestedOwner, generation == ticket else { return }
                lastAttempt = .now
                lastResult = "Could not update Continue Watching"
            }
        }
        return task
    }

    func accepts(owner: String, generation: UUID, itemID: String) -> Bool {
        guard let snapshot, snapshot.owner == owner, snapshot.generation == generation else { return false }
        return snapshot.items.contains { $0.id == itemID }
    }

    private func removeDirectories(except kept: String?) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name != Self.snapshotName && name != kept {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
