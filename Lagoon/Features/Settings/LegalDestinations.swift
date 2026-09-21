import Foundation

/// Where Lagoon's published privacy policy and support pages live
/// (audit A06). The site is on `lagoon.helop.dev`, and these are the same
/// URLs entered in App Store Connect — the two have to agree, because a
/// reviewer checks one against the other.
///
/// A destination whose page is not published stays nil, and every screen
/// that would show it shows nothing, so the app never points at an address
/// that does not answer.
nonisolated enum LegalDestinations {
    static let privacyPolicy: URL? = URL(string: "https://lagoon.helop.dev/privacy/")
    static let support: URL? = URL(string: "https://lagoon.helop.dev/support/")

    /// A viewer on Apple TV cannot open a link, so the address itself is
    /// what the screen shows them to type on another device.
    static func displayAddress(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
