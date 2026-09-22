import Foundation
import LagoonEngine
import Observation

/// A track choice durable enough to be stored, and the defaults namespace
/// it is stored under.
///
/// The namespace belongs to the choice rather than to a store's
/// initializer, so no call site can write one kind of choice into another
/// kind's key by passing the wrong string.
nonisolated protocol RememberedTrackChoice: Codable, Equatable {
    static var memoryNamespace: String { get }
    /// Reference-date seconds, used only to evict the oldest entries.
    /// Deliberately not a `Date`: the codebase keeps dates out of Codable.
    var updatedAt: Double { get }
}

/// The shape of a track layout, as one string two layouts can be compared
/// by.
nonisolated enum TrackLayoutFingerprint {
    /// Fields are length-prefixed rather than merely joined, because a
    /// title is uncontrolled file metadata and may contain the separators
    /// itself — and two different layouts colliding here is the one way a
    /// remembered position could be applied to a layout it was never
    /// measured in.
    static func of(_ streams: [[String]]) -> String {
        streams
            .map { fields in fields.map { "\($0.count):\($0)" }.joined() }
            .joined(separator: "|")
    }
}

/// Per-account memory of track choices, scoped to a series so that
/// correcting one episode carries to the rest of the show. Written straight
/// through to `UserDefaults`, so it outlives the player presentation.
///
/// Generic over the choice because the mechanism — re-read, merge, evict,
/// persist — has nothing to do with what was chosen, and a second copy of
/// it would be a second place for the merge to go wrong.
@MainActor
@Observable
final class TrackMemoryStore<Choice: RememberedTrackChoice> {
    private(set) var accountID: String?
    private var choices: [String: Choice] = [:]

    private let defaults: UserDefaults
    /// Enough for any plausible library of part-watched shows; the oldest
    /// entries fall off rather than letting the payload grow without end.
    private static var capacity: Int { 200 }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        choices = accountID.flatMap { Self.stored(for: $0, in: defaults) } ?? [:]
    }

    /// One show, one choice: an episode answers for its series, anything
    /// else only for itself.
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

    /// Dropped when the viewer lands back on what automatic selection would
    /// have picked anyway: there is no longer an override to carry.
    func forget(_ scope: String) {
        var merged = reloaded()
        let removed = merged.removeValue(forKey: scope) != nil
        choices = merged
        guard removed else { return }
        persist()
    }

    /// Re-reads what is on disk before changing it, so two players open
    /// over one account — a Picture in Picture session and a new one — do
    /// not write whole-map snapshots over each other's entries.
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
