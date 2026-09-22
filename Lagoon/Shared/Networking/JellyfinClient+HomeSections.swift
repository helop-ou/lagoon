import Foundation

// Home Screen Sections plugin. Optional: without it, or on any error, Home
// uses its own rails.
extension JellyfinClient {
    /// One row the plugin offers, as `HomeScreen/Sections` describes it.
    nonisolated struct HomeSection: Decodable, Identifiable, Sendable {
        /// The section key (`ContinueWatching`, `MyList`), also its fetch path.
        let section: String
        let displayText: String?
        /// `Landscape`, `Portrait` or `Square` (drawn as a poster rail).
        let viewMode: String?
        let orderIndex: Int?

        var id: String { section }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            section = try c.decode(String.self, forKey: "section")
            displayText = try c.decodeIfPresent(String.self, forKey: "displayText")
            viewMode = try c.decodeIfPresent(String.self, forKey: "viewMode")
            orderIndex = try c.decodeIfPresent(Int.self, forKey: "orderIndex")
        }
    }

    private nonisolated struct HomeSectionsPage: Decodable {
        let items: [HomeSection]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            items = try c.decodeIfPresent([HomeSection].self, forKey: "items") ?? []
        }
    }

    /// Section types the plugin offers, empty when it isn't installed.
    ///
    /// A catalogue, not a layout: every type the plugin knows, whatever the
    /// admin enabled, and nothing exposes the enabled set. So `HomeViewModel`
    /// adds these as extra rows rather than letting them define Home.
    func homeSections() async -> [HomeSection] {
        guard let userId else { return [] }
        let page: HomeSectionsPage? = try? await get("HomeScreen/Sections", query: [
            URLQueryItem(name: "userId", value: userId),
        ], probe: true)
        let legacy = page?.items ?? []
        var seen = Set<String>()
        return legacy.filter { seen.insert($0.section).inserted }
    }

    /// A section's contents. Empty on failure, so one bad section costs
    /// nothing else.
    func homeSectionItems(_ section: String) async -> [MediaItem] {
        guard let userId else { return [] }
        let page: ItemsPage? = try? await get("HomeScreen/Section/\(section)", query: [
            URLQueryItem(name: "userId", value: userId),
        ], probe: true)
        return page?.items ?? []
    }
}
