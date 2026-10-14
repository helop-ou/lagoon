import SwiftUI

/// Play or Resume, From Beginning when there is somewhere to resume, then
/// the page's own controls, with a caption under Play. Shared by the film
/// and collection pages.
///
/// The caption sits under the row on wide layouts and under the pill on a
/// phone.
struct DetailPlayActions<Secondary: View>: View {
    let resumes: Bool
    let caption: String?
    let play: () -> Void
    /// Nil hides From Beginning.
    let playFromBeginning: (() -> Void)?
    @ViewBuilder let secondary: Secondary

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    init(
        resumes: Bool,
        caption: String?,
        play: @escaping () -> Void,
        playFromBeginning: (() -> Void)?,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.resumes = resumes
        self.caption = caption
        self.play = play
        self.playFromBeginning = playFromBeginning
        self.secondary = secondary()
    }

    var body: some View {
        #if os(iOS)
        if !usesLeadingColumn {
            actions
        } else {
            captionedActions
        }
        #else
        captionedActions
        #endif
    }

    private var captionedActions: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            actions
            captionText
        }
    }

    @ViewBuilder
    private var captionText: some View {
        if let caption {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    #if os(iOS)
    private var usesLeadingColumn: Bool {
        DetailLayout.usesLeadingColumn(horizontalSizeClass)
    }
    #endif

    /// Play leads so it takes first focus; otherwise Select on arrival lands
    /// on whatever follows it.
    private var actions: some View {
        DetailActionLayout {
            #if os(iOS)
            if usesLeadingColumn {
                playButton
            } else {
                // The caption hangs under the pill alone so the row stays level.
                VStack(spacing: Metrics.Space.xs) {
                    playButton
                        .alignmentGuide(.detailPillCenter) { $0[VerticalAlignment.center] }
                    captionText
                }
            }
            #else
            playButton
            #endif
        } secondary: {
            fromBeginningButton
            secondary
        }
    }

    private var playButton: some View {
        Button(action: play) {
            Label(resumes ? "Resume" : "Play", systemImage: "play.fill")
                .detailPrimaryLabel()
        }
        .detailPrimaryButton()
        #if os(iOS)
        .accessibilityIdentifier("detail.play")
        #endif
    }

    /// A pill beside Play on TV and wide iPad; a circle on a phone, where a
    /// pill folds the four-control row into a column.
    @ViewBuilder
    private var fromBeginningButton: some View {
        if let playFromBeginning {
            #if os(iOS)
            if usesLeadingColumn {
                Button(action: playFromBeginning) {
                    Label("From Beginning", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
            } else {
                DetailCircleButton(action: playFromBeginning) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("From Beginning")
            }
            #else
            Button(action: playFromBeginning) {
                Label("From Beginning", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
            #endif
        }
    }
}

extension Ticks {
    /// `1:02:03` or `4:05`, for a resume caption.
    static func timestamp(_ ticks: Int64) -> String {
        let seconds = Int(Ticks.seconds(ticks))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
