import Foundation
@testable import Lagoon

extension AccountScopedStores {
    /// Stores nothing else can see: themes on the test's own defaults, Top
    /// Shelf and downloads under a fresh temporary directory. The real ones
    /// back the installed app and the Top Shelf extension.
    static func isolated(defaults: UserDefaults) -> AccountScopedStores {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AccountScopedStores-\(UUID().uuidString)", directoryHint: .isDirectory)
        let topShelf = TopShelfPublisher(directory: root.appending(path: "TopShelf", directoryHint: .isDirectory))
        #if os(iOS)
        let downloads = DownloadStore(
            baseDirectory: root.appending(path: "Downloads", directoryHint: .isDirectory),
            sessionConfiguration: .ephemeral
        )
        return AccountScopedStores(themes: ThemeStore(defaults: defaults), topShelf: topShelf, downloads: downloads)
        #else
        return AccountScopedStores(themes: ThemeStore(defaults: defaults), topShelf: topShelf)
        #endif
    }
}
