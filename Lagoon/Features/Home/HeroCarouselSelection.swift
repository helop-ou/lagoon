/// Keeps the featured title stable when a refresh reorders or replaces slides.
nonisolated struct HeroCarouselSelection {
    private(set) var selectedID: String?

    func currentID(in ids: [String]) -> String? {
        if let selectedID, ids.contains(selectedID) { return selectedID }
        return ids.first
    }

    mutating func reconcile(with ids: [String]) {
        selectedID = currentID(in: ids)
    }

    mutating func select(_ id: String?, in ids: [String]) {
        // Native scrolling can briefly report no target between pages.
        guard let id, ids.contains(id) else { return }
        selectedID = id
    }

    func adjacentID(offset: Int, in ids: [String]) -> String? {
        guard let current = currentID(in: ids), let index = ids.firstIndex(of: current) else {
            return nil
        }
        let next = (index + offset % ids.count + ids.count) % ids.count
        return ids[next]
    }
}
