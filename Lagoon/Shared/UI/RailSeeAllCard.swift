import SwiftUI

/// Ends a rail rather than heading it: a focusable heading adds a focus
/// stop between every pair of rails.
struct RailSeeAllCard<Route: Hashable>: View {
    let destination: Route
    let title: String
    var identifier = "rail.seeAll"
    let layout = PosterLayout()

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            NavigationLink(value: destination) {
                ZStack {
                    Color.artworkPlaceholder
                    VStack(spacing: Metrics.Space.m) {
                        Image(systemName: "arrow.forward")
                            .font(.title2)
                        Text("See All")
                            .font(.callout.weight(.medium))
                    }
                }
                .frame(width: layout.width, height: layout.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            // The system draws the focus visual, never us.
            .cardButtonStyle()
            .accessibilityLabel("See all \(title)")
            .accessibilityIdentifier(identifier)

            // Matches the poster cards' caption space to keep the baseline.
            Color.clear
                .frame(width: layout.width, height: layout.captionHeight)
        }
        .frame(width: layout.width)
    }
}
