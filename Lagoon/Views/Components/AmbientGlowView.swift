import SwiftUI

/// Three radial blobs from the artwork's dominant colors, blurred to mush —
/// the soft color field behind the hero panel.
struct AmbientGlowView: View {
    let palette: ArtworkPalette

    private static let centers: [UnitPoint] = [
        UnitPoint(x: 0.25, y: 0.3),
        UnitPoint(x: 0.85, y: 0.25),
        UnitPoint(x: 0.6, y: 0.85),
    ]

    var body: some View {
        ZStack {
            ForEach(Array(palette.colors.prefix(3).enumerated()), id: \.offset) { index, color in
                RadialGradient(
                    colors: [color.opacity(0.5), .clear],
                    center: Self.centers[index],
                    startRadius: 0,
                    endRadius: 700
                )
            }
        }
        .blur(radius: 120)
        .animation(.easeInOut(duration: Motion.crossfade), value: palette)
        .allowsHitTesting(false)
    }
}
