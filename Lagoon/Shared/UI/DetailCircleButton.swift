import SwiftUI

#if os(iOS)
/// A glass circle for the phone's secondary detail actions. Not
/// `.buttonStyle(.glass)`: on iOS 26 its press highlight is a capsule, not
/// the circle.
struct DetailCircleButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
                .frame(width: Metrics.detailCircleActionSize, height: Metrics.detailCircleActionSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// `DetailCircleButton` for a menu.
struct DetailCircleMenu<Content: View, Label: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            content
        } label: {
            label
                .frame(width: Metrics.detailCircleActionSize, height: Metrics.detailCircleActionSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}
#endif
