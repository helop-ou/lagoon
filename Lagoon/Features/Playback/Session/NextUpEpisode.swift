import Foundation

/// The episode queued next, as the Up Next card shows it.
nonisolated struct NextUpEpisode: Equatable {
    /// The episode's name, never the series.
    let title: String
    /// "S1 E4", when the server numbered it.
    let subtitle: String?
    let imageURL: URL?

    init(title: String, subtitle: String? = nil, imageURL: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
    }
}
