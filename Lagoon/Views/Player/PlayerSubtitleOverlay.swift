import SwiftUI

/// The cue layer, lifted out of `CustomPlayerView` (HEL-150).
///
/// `currentSubtitleText`, `currentSubtitleCues` and `currentSubtitleImages`
/// all move at the engine's tick rate, and Observation tracks property reads
/// per view *body*. Reading them here — and nowhere above here — is what keeps
/// a cue change from re-evaluating the whole player, and on tvOS from
/// re-hosting `MenuPressGate`'s tree ten times a second along with it.
///
/// Bitmap cues (PGS/VobSub) land exactly where they compose on the video
/// plane; text cues sit bottom-center Infuse-style.
struct PlayerSubtitleOverlay: View {
    @PlayerEngineRef var engine: any PlayerEngine
    let style: SubtitleRenderStyle
    /// Custom renderers must tell Media Accessibility which caption text is
    /// currently onscreen. The report is driven from here because this is the
    /// one body that reads that text; the player still clears it on its own
    /// disappearance.
    let onDisplayedCaption: (String?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let videoRect = displayedVideoRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(engine.currentSubtitleImages.enumerated()), id: \.offset) { _, cue in
                    Image(decorative: cue.image, scale: 1)
                        .resizable()
                        .accessibilityIdentifier("player.subtitle.image")
                        .frame(
                            width: videoRect.width * cue.rect.width,
                            height: videoRect.height * cue.rect.height
                        )
                        .position(
                            x: videoRect.minX + videoRect.width * cue.rect.midX,
                            y: videoRect.minY + videoRect.height * cue.rect.midY
                        )
                }
                let textCues = engine.currentSubtitleCues
                if !textCues.isEmpty,
                   textCues.allSatisfy({ $0.usesDefaultPlacement && $0.usesDefaultStyle }),
                   let text = engine.currentSubtitleText {
                    // Preserve the exact pre-HEL-107 path for ordinary SRT,
                    // WebVTT and unstyled dialogue.
                    VStack {
                        Spacer()
                        PlayerSubtitleText(text: text, style: style)
                    }
                    .frame(maxWidth: .infinity)
                } else if !textCues.isEmpty {
                    let defaultCues = textCues.filter(\.usesDefaultPlacement)
                    if !defaultCues.isEmpty {
                        VStack(spacing: Metrics.Space.xs) {
                            Spacer()
                            ForEach(Array(defaultCues.enumerated()), id: \.offset) { index, cue in
                                PlayerStyledSubtitleText(
                                    cue: cue,
                                    style: style,
                                    accessibilityIdentifier: Self.subtitleIdentifier(index)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, style.bottomPadding)
                    }
                    ForEach(
                        Array(textCues.filter { !$0.usesDefaultPlacement }.enumerated()),
                        id: \.offset
                    ) { index, cue in
                        PositionedSubtitleLayout(
                            position: cue.position,
                            alignment: cue.alignment ?? .bottomCenter
                        ) {
                            PlayerStyledSubtitleText(
                                cue: cue,
                                style: style,
                                accessibilityIdentifier: Self.subtitleIdentifier(defaultCues.count + index)
                            )
                        }
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: engine.currentSubtitleText, initial: true) { _, text in
            onDisplayedCaption(text)
        }
    }

    /// The first cue on screen keeps `player.subtitle.text`; the rest are
    /// suffixed so simultaneous authored cues stay individually addressable
    /// without making that name ambiguous.
    static func subtitleIdentifier(_ index: Int) -> String {
        index == 0 ? "player.subtitle.text" : "player.subtitle.text.\(index)"
    }

    /// Where the aspect-fit video actually sits inside the surface.
    private func displayedVideoRect(in container: CGSize) -> CGRect {
        guard let videoSize = engine.videoSize, videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Places one authored cue inside the aspect-fit video rect. `Layout` can
/// place a subview by an arbitrary anchor, which is the semantic difference
/// between ASS `\an1` and `\an3` at the same `\pos` coordinate.
private struct PositionedSubtitleLayout: Layout {
    let position: SubtitleTextPosition?
    let alignment: SubtitleTextAlignment

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let point = position ?? alignment.defaultPosition
        let proposedWidth = max(bounds.width * 0.9, 1)
        let size = subview.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
        subview.place(
            at: CGPoint(
                x: bounds.minX + bounds.width * CGFloat(point.x),
                y: bounds.minY + bounds.height * CGFloat(point.y)
            ),
            anchor: alignment.unitPoint,
            proposal: ProposedViewSize(width: min(size.width, proposedWidth), height: size.height)
        )
    }
}

private extension SubtitleTextAlignment {
    var unitPoint: UnitPoint {
        switch self {
        case .bottomLeft: .bottomLeading
        case .bottomCenter: .bottom
        case .bottomRight: .bottomTrailing
        case .middleLeft: .leading
        case .middleCenter: .center
        case .middleRight: .trailing
        case .topLeft: .topLeading
        case .topCenter: .top
        case .topRight: .topTrailing
        }
    }

    var defaultPosition: SubtitleTextPosition {
        let x: Double = switch self {
        case .bottomLeft, .middleLeft, .topLeft: 0.04
        case .bottomCenter, .middleCenter, .topCenter: 0.5
        case .bottomRight, .middleRight, .topRight: 0.96
        }
        let y: Double = switch self {
        case .topLeft, .topCenter, .topRight: 0.04
        case .middleLeft, .middleCenter, .middleRight: 0.5
        case .bottomLeft, .bottomCenter, .bottomRight: 0.96
        }
        return SubtitleTextPosition(x: x, y: y)
    }
}
