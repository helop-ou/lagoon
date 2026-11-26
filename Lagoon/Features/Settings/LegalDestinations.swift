import Foundation

/// Published privacy and support pages, which must match the URLs in App
/// Store Connect, the public repository and the beta page. An unpublished
/// page stays nil and no screen shows it.
nonisolated enum LegalDestinations {
    static let privacyPolicy: URL? = URL(string: "https://lagoon.helop.dev/privacy/")
    static let support: URL? = URL(string: "https://lagoon.helop.dev/support/")
    static let sourceCode: URL? = URL(string: "https://github.com/helop-ou/lagoon")
    /// The website's page, not the TestFlight link, which a shipped build
    /// could not follow if it changed.
    static let beta: URL? = URL(string: "https://lagoon.helop.dev/beta/")

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
