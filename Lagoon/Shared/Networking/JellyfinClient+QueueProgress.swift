import Foundation

/// Queue progress lives in a display-preferences record, read and written
/// whole. See `QueueProgressRecord` for why nothing else may change.
extension JellyfinClient {
    func queueProgress() async throws -> [QueueProgressEntry] {
        let preferences = try await queuePreferences()
        return QueueProgressRecord.entries(in: preferences["CustomPrefs"] as? [String: Any] ?? [:])
    }

    func recordQueueProgress(_ entry: QueueProgressEntry) async throws {
        try await updateQueueProgress { QueueProgressRecord.recording(entry, in: $0) }
    }

    func removeQueueProgress(listIDs: Set<String>) async throws {
        guard !listIDs.isEmpty else { return }
        try await updateQueueProgress { $0.filter { !listIDs.contains($0.source.id) } }
    }

    private func updateQueueProgress(_ change: ([QueueProgressEntry]) -> [QueueProgressEntry]) async throws {
        let preferences = try await queuePreferences()
        let current = QueueProgressRecord.entries(in: preferences["CustomPrefs"] as? [String: Any] ?? [:])
        let changed = change(current)
        guard changed != current else { return }
        let body = try JSONSerialization.data(
            withJSONObject: QueueProgressRecord.preferences(preferences, storing: changed)
        )
        try await postVoid(
            "DisplayPreferences/\(QueueProgressRecord.preferencesID)",
            query: try queuePreferencesQuery(),
            rawBody: body
        )
    }

    /// Untyped on purpose: the body goes back with every field it came with.
    private func queuePreferences() async throws -> [String: Any] {
        let data = try await getData(
            "DisplayPreferences/\(QueueProgressRecord.preferencesID)",
            query: try queuePreferencesQuery()
        )
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func queuePreferencesQuery() throws -> [URLQueryItem] {
        [
            URLQueryItem(name: "userId", value: try requireUserId()),
            URLQueryItem(name: "client", value: QueueProgressRecord.preferencesClient),
        ]
    }
}
