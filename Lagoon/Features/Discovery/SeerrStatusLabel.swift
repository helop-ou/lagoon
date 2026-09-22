import SwiftUI

/// A Seerr status as icon and word; the icon animates only while its
/// container holds focus, so a grid does not all spin at once.
/// `\.isFocused` reads the nearest focusable ancestor, card or button.
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
            // Slowed: at full speed it reads as a stuck spinner.
            content.symbolEffect(.rotate, options: .repeating.speed(0.6), isActive: isActive)
        case .bounce:
            content.symbolEffect(.bounce, options: .repeating.speed(0.8), isActive: isActive)
        case .pulse:
            content.symbolEffect(.pulse, options: .repeating, isActive: isActive)
        }
    }
}

extension View {
    /// Callers' `isActive` must already account for Reduce Motion; symbol
    /// effects are not assumed to honour it.
    func seerrStatusMotion(_ motion: SeerrStatusMotion, isActive: Bool) -> some View {
        modifier(SeerrStatusMotionModifier(motion: motion, isActive: isActive))
    }
}
