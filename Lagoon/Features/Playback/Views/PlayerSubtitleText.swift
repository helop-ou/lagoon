import LagoonEngine
import SwiftUI

/// Bench hook (`debug.benchFlatCues`): skip `rasterizedCue()` for an
/// on-device A/B. Cue shadow and background filtered every frame cost dropped
/// frames on Apple TV HDR; rasterizing them fixes that.
private let benchFlatCues = UserDefaults.standard.bool(forKey: "debug.benchFlatCues")

private extension View {
    /// Bakes the cue into one texture. Apply after edge and background, and
    /// before the accessibility identifier, so UI tests can still query
    /// `player.subtitle.text`.
    @ViewBuilder
    func rasterizedCue() -> some View {
        if benchFlatCues {
            self
        } else {
            self.drawingGroup()
        }
    }

    /// The styling a plain cue and an ASS cue share, rasterized.
    func subtitleCue(_ style: SubtitleRenderStyle, alignment: TextAlignment) -> some View {
        font(style.font)
            .multilineTextAlignment(alignment)
            .foregroundStyle(style.foregroundColor)
            .subtitleEdge(style.edgeStyle, color: style.edgeColor)
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
            .background(
                style.backgroundColor.opacity(style.backgroundOpacity),
                in: RoundedRectangle(cornerRadius: Metrics.cardArtRadius)
            )
            .rasterizedCue()
    }
}

struct PlayerSubtitleText: View {
    let text: String
    let style: SubtitleRenderStyle
    var accessibilityIdentifier = "player.subtitle.text"

    var body: some View {
        Text(text)
            .subtitleCue(style, alignment: .center)
            .padding(.bottom, style.bottomPadding)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Inline ASS styling. Placement belongs to `PositionedSubtitleLayout`, so
/// no shelf padding here.
struct PlayerStyledSubtitleText: View {
    let cue: SubtitleTextCue
    let style: SubtitleRenderStyle
    /// Only the first simultaneous cue keeps the canonical identifier.
    var accessibilityIdentifier = "player.subtitle.text"

    var body: some View {
        styledText
            .subtitleCue(style, alignment: cue.alignment?.textAlignment ?? .center)
            .accessibilityLabel(cue.text)
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var styledText: Text {
        cue.runs.reduce(Text("")) { partial, run in
            var fragment = Text(run.text)
            if run.isBold { fragment = fragment.bold() }
            if run.isItalic { fragment = fragment.italic() }
            if let color = run.primaryColor {
                fragment = fragment.foregroundColor(color.swiftUIColor)
            }
            // tvOS 26 deprecates `Text.+`.
            return Text("\(partial)\(fragment)")
        }
    }
}

private extension SubtitleTextAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .bottomLeft, .middleLeft, .topLeft: .leading
        case .bottomCenter, .middleCenter, .topCenter: .center
        case .bottomRight, .middleRight, .topRight: .trailing
        }
    }
}

private extension SubtitleTextColor {
    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}
