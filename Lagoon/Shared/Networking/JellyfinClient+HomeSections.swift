import Foundation

// Home Screen Sections plugin support (HEL-47). Entirely optional: a server
// without the plugin 404s the whole route and Home falls back to its own
// rails, which is also what happens on any error here.
extension JellyfinClient {
    /// One row the plugin offers, as `HomeScreen/Sections` describes it.
    nonisolated struct HomeSection: Decodable, Identifiable, Sendable {
        /// The plugin's own section key — `ContinueWatching`, `MyList`, … —
        /// and the path component its content is fetched by.
        let section: String
        let displayText: String?
        /// `Landscape`, `Portrait` or `Square`. Square has no rail style of
        /// its own here; it borrows the poster rail.
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

    /// Section types the plugin offers, or an empty list when it isn't
    /// installed.
    ///
    /// **This is a catalogue, not a layout.** Verified against a real server
    /// (2026-08-18): it returns every section type the plugin knows — 28 of
    /// them, including Books, Music and Jellyseerr rows for a library that
    /// has none — regardless of what the admin enabled. Neither the plugin
    /// (`HomeScreen/UserSettings` and friends all 404) nor core
    /// `DisplayPreferences` (no `homesection*` keys) exposes the enabled
    /// set, so a client cannot know the intended layout. That is why
    /// `HomeViewModel` treats these as *additional* rows and drops the ones
    /// it already draws itself, rather than letting them define Home.
    func homeSections() async -> [HomeSection] {
        guard let userId else { return [] }
        let page: HomeSectionsPage? = try? await get("HomeScreen/Sections", query: [
            URLQueryItem(name: "userId", value: userId),
        ], probe: true)
        return page?.items ?? []
    }

    /// A section's contents. Empty on any failure — one bad section must not
    /// cost the others.
    func homeSectionItems(_ section: String) async -> [MediaItem] {
        guard let userId else { return [] }
        let page: ItemsPage? = try? await get("HomeScreen/Section/\(section)", query: [
            URLQueryItem(name: "userId", value: userId),
        ], probe: true)
        return page?.items ?? []
    }
}
