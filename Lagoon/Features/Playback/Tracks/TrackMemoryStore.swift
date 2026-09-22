import Foundation
import LagoonEngine
import Observation

/// A track choice that can be stored, and its defaults namespace. The
/// namespace belongs to the choice so no call site can write one kind into
/// another's key.
nonisolated protocol RememberedTrackChoice: Codable, Equatable {
    static var memoryNamespace: String { get }
    /// Reference-date seconds, used only to evict the oldest entries. Not a
    /// `Date`: dates stay out of Codable.
    var updatedAt: Double { get }
}

/// A track layout's shape as one comparable string.
nonisolated enum TrackLayoutFingerprint {
    /// Fields are length-prefixed because titles may contain separators, and a
    /// collision would apply a remembered position to the wrong layout.
    static func of(_ streams: [[String]]) -> String {
        streams
            .map { fields in fields.map { "\($0.count):\($0)" }.joined() }
            .joined(separator: "|")
    }
}

/// Per-account track choices, scoped to a series so correcting one episode
/// carries to the rest. Written straight to `UserDefaults`, so it outlives
/// the player.
@MainActor
@Observable
final class TrackMemoryStore<Choice: RememberedTrackChoice> {
    private(set) var accountID: String?
    private var choices: [String: Choice] = [:]

    private let defaults: UserDefaults
    /// Oldest entries fall off so the payload stays bounded.
    private static var capacity: Int { 200 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        choices = accountID.flatMap { Self.stored(for: $0, in: defaults) } ?? [:]
    }

    /// An episode answers for its series, anything else only for itself.
    nonisolated static func scope(seriesID: String?, itemID: String) -> String {
        seriesID ?? itemID
    }

    func choice(for scope: String) -> Choice? {
        choices[scope]
    }

    func remember(_ choice: Choice, for scope: String) {
        var merged = reloaded()
        merged[scope] = choice
        if merged.count > Self.capacity {
            // Never the entry just written, whatever the clock has done.
            let evictable = merged
                .filter { $0.key != scope }
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(merged.count - Self.capacity)
                .map(\.key)
            for key in evictable {
                merged.removeValue(forKey: key)
            }
        }
        choices = merged
        persist()
    }

    /// Called when the viewer lands back on the automatic choice.
    func forget(_ scope: String) {
        var merged = reloaded()
        let removed = merged.removeValue(forKey: scope) != nil
        choices = merged
        guard removed else { return }
        persist()
    }

    /// Re-read before writing, so two players on one account (PiP and a new
    /// one) do not overwrite each other's entries.
    private func reloaded() -> [String: Choice] {
        guard let accountID,
              let stored = Self.stored(for: accountID, in: defaults) else { return choices }
        return stored
    }

    private func persist() {
        guard let accountID,
              let data = try? JSONEncoder().encode(choices) else { return }
        defaults.set(data, forKey: Self.key(accountID))
    }

    private static func stored(
        for accountID: String,
        in defaults: UserDefaults
    ) -> [String: Choice]? {
        guard let data = defaults.data(forKey: key(accountID)) else { return nil }
        return try? JSONDecoder().decode([String: Choice].self, from: data)
    }

    private static func key(_ accountID: String) -> String {
        "playback.\(Choice.memoryNamespace).\(accountID)"
    }
}
