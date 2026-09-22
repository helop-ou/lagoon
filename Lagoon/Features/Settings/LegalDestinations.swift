import Foundation

/// Published privacy and support pages. Must match the URLs in App Store
/// Connect. An unpublished page stays nil and no screen shows it.
nonisolated enum LegalDestinations {
    static let privacyPolicy: URL? = URL(string: "https://lagoon.helop.dev/privacy/")
    static let support: URL? = URL(string: "https://lagoon.helop.dev/support/")

    /// The address as shown for typing on another device.
    static func displayAddress(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
