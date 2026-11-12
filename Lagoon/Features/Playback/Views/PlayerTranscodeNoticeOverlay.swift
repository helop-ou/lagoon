import SwiftUI

/// Says the server is converting what plays, and offers the original when a
/// cap was the reason. Shares the corner with the skip pill, Up Next and the
/// lower-quality offer, and yields to all three. Not focusable on tvOS, for
/// the same reason as they are: Select and Back reach it from the surface.
struct PlayerTranscodeNoticeOverlay: View {
    let prompt: PlaybackTranscodeNoticePrompt
    /// The panel is open, a scrub is in progress, or another prompt is up.
    let isSuppressed: Bool
    let reduceMotion: Bool

    var body: some View {
        let notice = isSuppressed ? nil : prompt.notice
        Group {
            if let notice {
                PlayerTranscodeNoticeCard(
                    notice: notice,
                    onPlayOriginal: { prompt.playOriginal() },
                    onDismiss: { prompt.dismiss() }
                )
                .playerCornerPrompt(reduceMotion: reduceMotion)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: notice)
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }
}

struct PlayerTranscodeNoticeCard: View {
    let notice: PlaybackTranscodeNotice
    let onPlayOriginal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                #if os(iOS)
                if !notice.offersOriginal {
                    Spacer(minLength: Metrics.Space.s)
                    Button("Dismiss", systemImage: "xmark", action: onDismiss)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.mini)
                        .accessibilityIdentifier("player.transcodeNotice.dismiss")
                }
                #endif
            }

            Text(message)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if notice.offersOriginal {
                #if os(tvOS)
                Text("Select to play the original · Back to keep this")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                #else
                HStack(spacing: Metrics.Space.s) {
                    // The player keeps the white accent, so the prominent fill is white.
                    Button("Play Original", action: onPlayOriginal)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                        .accessibilityIdentifier("player.transcodeNotice.playOriginal")
                    Button("Keep", action: onDismiss)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("player.transcodeNotice.keep")
                }
                .controlSize(.small)
                #endif
            }
        }
        .padding(Metrics.Space.l)
        .frame(width: TranscodeNoticeMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .playerCornerPromptShadow()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player.transcodeNotice")
    }

    private var title: LocalizedStringKey {
        notice.offersOriginal ? "Playing a Smaller Version" : "Converting on the Server"
    }

    private var message: LocalizedStringKey {
        switch notice {
        case .capped(.metered, _, _):
            "To save data on this connection, the server is sending a smaller version."
        case .capped(.setting, _, let maxBitrate):
            "Maximum Quality is set to \(Self.megabits(maxBitrate)) Mbps, so the server is sending a smaller version."
        case .capped(_, let probed?, _):
            "Your connection measured \(Self.megabits(probed)) Mbps, so the server is sending a smaller version."
        case .capped:
            "The server is sending a smaller version to suit your connection."
        case .converting(.video):
            "This device can't play this video format, so the server is converting it."
        case .converting(.audio):
            "This device can't play this audio format, so the server is converting it."
        case .converting(.subtitles):
            "The server is drawing the selected subtitles into the picture."
        case .converting(.bitrate):
            "This file's bitrate is higher than this device streams, so the server is converting it."
        case .converting(.qualityLimit):
            "The server is sending a smaller version to suit the quality limit."
        case .converting(.playbackProblem):
            "The original file wouldn't play here, so the server is converting it."
        case .converting(.other):
            "The server is converting this file so it can play here."
        }
    }

    private static func megabits(_ bitsPerSecond: Int) -> Int {
        Int((Double(bitsPerSecond) / 1_000_000).rounded())
    }
}

private nonisolated enum TranscodeNoticeMetrics {
    #if os(tvOS)
    static let width: CGFloat = 520
    #else
    static let width: CGFloat = 300
    #endif
}
