import SwiftUI

/// What shared cards and menus show of downloads: a mark on a downloaded
/// item, and the menu entries that download, cancel or delete it.
///
/// The Downloads feature conforms and the app injects it, so shared views
/// never name the feature. Nil where there are no downloads, as on tvOS.
@MainActor
protocol ItemDownloadPresenting: AnyObject {
    func isDownloaded(_ itemID: String) -> Bool
    /// The context menu's download entries for this item, or nothing.
    func contextMenuItems(for item: MediaItem) -> AnyView
}

extension EnvironmentValues {
    @Entry var itemDownloads: (any ItemDownloadPresenting)?
}
