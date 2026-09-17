import Foundation

/// Where Lagoon's published privacy policy and support pages live, once they
/// exist (HEL-143, audit A06). The website section in docs/release.md proposes
/// `lagoon.helop.dev`; until a page is actually published its entry stays
/// nil and every screen that would show it shows nothing, so the app never
/// points at an address that does not answer. Fill these in with the same
/// URLs entered in App Store Connect.
nonisolated enum LegalDestinations {
    static let privacyPolicy: URL? = nil
    static let support: URL? = nil

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
