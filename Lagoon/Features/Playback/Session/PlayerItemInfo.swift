import Foundation

/// What the player's Info tab and transport show about the item.
nonisolated struct PlayerItemInfo: Equatable {
    /// Transport headline: the series for episodes, the item otherwise.
    let title: String
    /// Small line above the headline, e.g. "S1 E1 · Freedom Day".
    let subtitle: String?
    /// A synopsis to show while the picture is loading, if there is one.
    let overview: String?
    /// Short tokens: runtime, year, "HEVC (4K DV)", "Dolby Digital+ 5.1", …
    let facts: [String]
    /// One line, e.g. "HEVC · 4K DV · 3840×1600 · 23.976 fps".
    let videoSummary: String?
    /// Artwork for the system's Now Playing panel, if there is any.
    let posterURL: URL?
    /// Empty when the item has no chapters.
    var chapters: [PlayerChapter] = []
    /// nil when there are no trickplay tiles.
    var trickplay: TrickplaySource?
    /// Empty when the server has no segments for the item.
    var segments: [MediaSegment] = []

    init(
        title: String,
        subtitle: String? = nil,
        overview: String? = nil,
        facts: [String],
        videoSummary: String? = nil,
        posterURL: URL? = nil,
        chapters: [PlayerChapter] = [],
        trickplay: TrickplaySource? = nil,
        segments: [MediaSegment] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.overview = overview
        self.facts = facts
        self.videoSummary = videoSummary
        self.posterURL = posterURL
        self.chapters = chapters
        self.trickplay = trickplay
        self.segments = segments
    }
}

/// A chapter mark on the transport.
nonisolated struct PlayerChapter: Identifiable, Equatable {
    /// Position in the chapter list, which is also its display number.
    let id: Int
    /// What to call the chapter, if the container named it.
    let name: String?
    /// Where the chapter begins, in seconds.
    let start: Double

    init(id: Int, name: String? = nil, start: Double) {
        self.id = id
        self.name = name
        self.start = start
    }
}
