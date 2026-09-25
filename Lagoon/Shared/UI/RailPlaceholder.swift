import SwiftUI

/// A rail-shaped stand-in while a shelf loads or fails: the same heading as
/// a resolved rail, over status text or a spinner, at a fixed height so nothing
/// jumps once the real content arrives.
struct RailPlaceholder<Content: View>: View {
    let title: String
    let minHeight: CGFloat
    let content: () -> Content

    init(
        title: String,
        minHeight: CGFloat = 180,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.minHeight = minHeight
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            Text(title).font(.headline)
            content()
        }
        .padding(.horizontal, Metrics.screenGutter)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
    }
}
