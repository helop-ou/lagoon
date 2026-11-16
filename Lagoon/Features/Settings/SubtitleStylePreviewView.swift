import SwiftUI

/// A sample subtitle line in a style, over a dim still. Settings and the
/// first sign-in's setup both show it.
struct SubtitleStylePreviewView: View {
    let style: SubtitleRenderStyle

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: Metrics.settingsRowCornerRadius)
                .fill(
                    LinearGradient(
                        colors: [.indigo.opacity(0.45), .black.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("This is how subtitles will look.")
                .font(style.font)
                .foregroundStyle(style.foregroundColor)
                .subtitleEdge(style.edgeStyle, color: style.edgeColor)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.vertical, Metrics.Space.s)
                .background(
                    style.backgroundColor.opacity(style.backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: Metrics.cardArtRadius)
                )
                .padding(.bottom, Metrics.Space.l)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .accessibilityIdentifier("settings.subtitlePreview")
    }
}
