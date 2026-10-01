import Foundation
import LagoonEngine

/// A track choice that can be stored, and its defaults namespace. The
/// namespace belongs to the choice so no call site can write one kind into
/// another's key.
nonisolated protocol RememberedTrackChoice: Codable, Equatable {
    static var memoryNamespace: String { get }
    /// Reference-date seconds, used only to evict the oldest entries. Not a
    /// `Date`: dates stay out of Codable.
    var updatedAt: Double { get }
    /// 1-based, in the engine's ordinal space for this kind of track.
    var ordinal: Int { get }
    /// Fingerprint of the layout the ordinal was measured against.
    var layout: String { get }
}

/// What a layout stream offers the description match: the two fields a
/// remembered choice can name it by.
nonisolated protocol TrackLayoutEntry {
    var language: String? { get }
    var title: String? { get }
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

/// The matching rungs audio and subtitle memory share. The policies stay
/// separate types because their layouts and fingerprints differ, so each
/// passes its own fingerprint in.
nonisolated enum TrackLayoutMatch {
    /// The ordinal when the description names exactly one track, else nil.
    /// Ambiguity is failure: Jellyfin synthesizes titles from codec and
    /// channels, and a release can tag several tracks alike (full, forced and
    /// SDH all "English"), so language alone names none of them.
    static func uniqueDescriptiveOrdinal<Entry: TrackLayoutEntry>(
        matchingLanguage language: String?,
        title: String?,
        in streams: [Entry]
    ) -> Int? {
        guard language != nil || title != nil else { return nil }
        let exact = streams.indices.filter {
            streams[$0].language == language && streams[$0].title == title
        }
        if exact.count == 1 { return exact[0] + 1 }
        // Titles pick up episode noise ("English (SDH) - Forced"), so fall back to
        // language, but only where it names one track.
        guard exact.isEmpty, let language else { return nil }
        let byLanguage = streams.indices.filter { streams[$0].language == language }
        return byLanguage.count == 1 ? byLanguage[0] + 1 : nil
    }

    /// Last resort: the first track of the right language. Maybe not the
    /// variant the viewer picked, but never a language they cannot read.
    static func approximateDescriptiveOrdinal<Entry: TrackLayoutEntry>(
        matchingLanguage language: String?,
        in streams: [Entry]
    ) -> Int? {
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
    }

    /// Position, fenced by an identical layout. Reached only after description
    /// fails, so it covers untagged releases and ones that tag several tracks
    /// alike.
    static func positionalOrdinal<Choice: RememberedTrackChoice, Entry>(
        for choice: Choice,
        in streams: [Entry],
        fingerprint: String
    ) -> Int? {
        guard !streams.isEmpty,
              choice.layout == fingerprint,
              (1...streams.count).contains(choice.ordinal) else { return nil }
        return choice.ordinal
    }
}

/// What a viewer's track change does to the stored choice.
nonisolated enum TrackMemoryOutcome: Equatable {
    case remember(ordinal: Int)
    case forget
}

/// Per-account track choices, scoped to a series so correcting one episode
/// carries to the rest. Written straight to `UserDefaults`, so it outlives
/// the player.
@MainActor
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
