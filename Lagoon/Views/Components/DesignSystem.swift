import SwiftUI

// Layout and animation tokens — prefer these over literals.
// tvOS values follow the 80pt safe-zone gutter convention; iOS scales down.

enum Metrics {
    #if os(tvOS)
    static let screenGutter: CGFloat = 80
    static let cardSpacing: CGFloat = 40
    static let posterWidth: CGFloat = 260
    static let landscapeWidth: CGFloat = 360
    static let heroHeight: CGFloat = 540
    static let gridColumns = 6
    static let gridRowSpacing: CGFloat = 50
    static let railTopPadding: CGFloat = 40    // headroom for the system focus lift
    static let railBottomPadding: CGFloat = 80
    static let scrubberHeight: CGFloat = 8     // thin bar, per the Infuse reference
    /// Backdrop left uncovered above the detail page's info block, so the
    /// artwork is the first thing on screen (HEL-46).
    static let detailHeroSpace: CGFloat = 250
    /// Band where the backdrop fades out before the info block starts.
    static let detailScrimFade: CGFloat = 220
    static let castPortraitSize: CGFloat = 130
    static let castCount = 8
    /// Box the title's logo artwork fits inside — height is what keeps a
    /// wide wordmark and a stacked one reading as the same design.
    static let logoMaxWidth: CGFloat = 620
    static let logoMaxHeight: CGFloat = 150
    #else
    static let screenGutter: CGFloat = 20
    static let cardSpacing: CGFloat = 14
    static let posterWidth: CGFloat = 140
    static let landscapeWidth: CGFloat = 240
    static let heroHeight: CGFloat = 340
    static let gridColumns = 3
    static let gridRowSpacing: CGFloat = 20
    static let railTopPadding: CGFloat = 6
    static let railBottomPadding: CGFloat = 10
    static let scrubberHeight: CGFloat = 8     // matches the AVKit transport bar
    static let detailHeroSpace: CGFloat = 90
    static let detailScrimFade: CGFloat = 110
    static let castPortraitSize: CGFloat = 72
    // No castCount on iOS: the strip scrolls there, so it shows everyone.
    static let logoMaxWidth: CGFloat = 240
    static let logoMaxHeight: CGFloat = 70
    #endif

    static var posterHeight: CGFloat { (posterWidth * 3 / 2).rounded() }
    static var landscapeHeight: CGFloat { (landscapeWidth * 9 / 16).rounded() }

    static let cardCornerRadius: CGFloat = 12
    static let cardArtRadius: CGFloat = 10
    static let badgeCornerRadius: CGFloat = 6
    static let panelCornerRadius: CGFloat = 32
    static let progressBarHeight: CGFloat = 6
}

enum Motion {
    static let fast: TimeInterval = 0.2       // focus platters, small reveals
    static let standard: TimeInterval = 0.4   // layer swaps, state transitions
    static let slow: TimeInterval = 0.6       // hero slide change
    static let crossfade: TimeInterval = 0.8  // backdrop / ambient-glow crossfade
}

// Brand colors are only for genuine branding: progress fills, the wordmark,
// selection markers. Everything else uses system semantic styles.
extension Color {
    static let lagoonTeal = Color(red: 74 / 255, green: 209 / 255, blue: 199 / 255)
    static let lagoonDeep = Color(red: 8 / 255, green: 46 / 255, blue: 68 / 255)
}

extension View {
    /// System card style on tvOS (lift, parallax, specular); plain elsewhere.
    @ViewBuilder
    func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}

/// Brand wash for the onboarding screens only.
struct BrandBackgroundGradient: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.lagoonDeep.opacity(0.9), location: 0),
                .init(color: Color.lagoonDeep.opacity(0.55), location: 0.4),
                .init(color: Color.lagoonDeep.opacity(0.2), location: 0.8),
                .init(color: .clear, location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .background(Color.black)
        .ignoresSafeArea()
    }
}
