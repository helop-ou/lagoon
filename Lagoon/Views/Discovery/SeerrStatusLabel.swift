import SwiftUI

/// A Seerr status as an icon and a word, where the icon animates while the
/// thing it sits in holds focus (HEL-117).
///
/// Focus-only on purpose: a grid of twenty request cards all turning at once
/// is noise, while one turning because you are looking at it is the tvOS
/// idiom. `\.isFocused` reports the nearest focusable ancestor, so this works
/// unchanged inside a card's label and inside a button.
struct SeerrStatusLabel: View {
    let title: String
    let symbol: String
    var motion: SeerrStatusMotion = .still

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(title, systemImage: symbol)
            .seerrStatusMotion(motion, isActive: isFocused && !reduceMotion)
    }
}

private struct SeerrStatusMotionModifier: ViewModifier {
    let motion: SeerrStatusMotion
    let isActive: Bool

    func body(content: Content) -> some View {
        switch motion {
        case .still:
            content
        case .rotate:
            // Slowed from the default: at full speed the refresh arrows read
            // as a spinner in trouble rather than work in progress.
            content.symbolEffect(.rotate, options: .repeating.speed(0.6), isActive: isActive)
        case .bounce:
            content.symbolEffect(.bounce, options: .repeating.speed(0.8), isActive: isActive)
        case .pulse:
            content.symbolEffect(.pulse, options: .repeating, isActive: isActive)
        }
    }
}

extension View {
    /// Applies a status glyph's animation. Callers pass an `isActive` that
    /// already accounts for Reduce Motion — symbol effects are not assumed to
    /// honour it, and Lagoon gates its other indefinite motion explicitly
    /// (see `HeroSection`).
    func seerrStatusMotion(_ motion: SeerrStatusMotion, isActive: Bool) -> some View {
        modifier(SeerrStatusMotionModifier(motion: motion, isActive: isActive))
    }
}
