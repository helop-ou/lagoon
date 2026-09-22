import Foundation

/// Which items Home's hero shows, from tiers in priority order (see
/// `HomeViewModel.heroTiers`). The first tier with anything eligible supplies
/// the whole hero; tiers are never mixed to reach six.
nonisolated enum HeroSelection {
    static let count = 6

    /// A hero needs a backdrop to paint and an overview to say.
    static func isEligible(_ item: MediaItem) -> Bool {
        item.backdropImageTags?.isEmpty == false && item.overview != nil
    }

    /// The first non-empty tier's eligible items, in order, deduplicated.
    static func candidates(from tiers: [[MediaItem]]) -> [MediaItem] {
        for tier in tiers {
            let eligible = unique(tier.filter(isEligible))
            if !eligible.isEmpty { return eligible }
        }
        return []
    }

    /// Up to `count` of the leading tier, shuffled so launches differ.
    static func select(
        tiers: [[MediaItem]],
        shuffle: ([MediaItem]) -> [MediaItem] = { $0.shuffled() }
    ) -> [MediaItem] {
        Array(shuffle(candidates(from: tiers)).prefix(count))
    }

    /// Shown items stay in place, with fresh records, while any tier still
    /// has them; vacancies fill from the leading tier.
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
