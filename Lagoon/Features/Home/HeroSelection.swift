import Foundation

/// Which items Home's hero shows.
///
/// It used to have one source, the recently-added rails, and vanished whenever
/// they came back empty — a server nobody has added to lately, a library a
/// scan has not reached, the public demo between resets. `HomeViewModel` now
/// hands in tiers in priority order: recently added, then Continue Watching
/// and Next Up, then Favorites, then plugin and curated rails, and last a
/// random library sample fetched only when everything above is empty. The
/// first tier with anything eligible supplies the whole hero; tiers are never
/// mixed to reach six, because the hero's job is to be interesting, not full.
nonisolated enum HeroSelection {
    static let count = 6

    /// A hero needs a backdrop to paint and an overview to say.
    static func isEligible(_ item: MediaItem) -> Bool {
        item.backdropImageTags?.isEmpty == false && item.overview != nil
    }

    /// The eligible items of the first tier that has any, in that tier's
    /// order and without duplicates.
    static func candidates(from tiers: [[MediaItem]]) -> [MediaItem] {
        for tier in tiers {
            let eligible = unique(tier.filter(isEligible))
            if !eligible.isEmpty { return eligible }
        }
        return []
    }

    /// A fresh hero: up to `count` of the leading tier, shuffled so the
    /// same six do not greet every launch.
    static func select(
        tiers: [[MediaItem]],
        shuffle: ([MediaItem]) -> [MediaItem] = { $0.shuffled() }
    ) -> [MediaItem] {
        Array(shuffle(candidates(from: tiers)).prefix(count))
    }

    /// The hero after a refresh: what is on screen stays, in place and with
    /// the server's fresh record, as long as any tier still returns it;
    /// vacancies fill from the leading tier in its order. So a hero drawn
    /// from Continue Watching keeps its items when something is finally
    /// added, and the new additions take the free slots.
    static func refreshed(current: [MediaItem], tiers: [[MediaItem]]) -> [MediaItem] {
        let everywhere = Dictionary(
            tiers.flatMap { $0 }.filter(isEligible).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var refreshed = current.compactMap { everywhere[$0.id] }
        var seen = Set(refreshed.map(\.id))
        for candidate in candidates(from: tiers) where refreshed.count < count && seen.insert(candidate.id).inserted {
            refreshed.append(candidate)
        }
        return refreshed
    }

    private static func unique(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
