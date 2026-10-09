import Foundation

/// The app-wide stores that follow the active account. `SessionStore` points
/// them at it; tests hand in their own so they never touch the real ones.
struct AccountScopedStores {
    let themes: ThemeStore
    let topShelf: TopShelfPublisher?
    #if os(iOS)
    let downloads: DownloadStore
    #endif

    static var shared: AccountScopedStores {
        #if os(iOS)
        AccountScopedStores(themes: .shared, topShelf: TopShelfStore.publisher, downloads: .shared)
        #else
        AccountScopedStores(themes: .shared, topShelf: TopShelfStore.publisher)
        #endif
    }
}
