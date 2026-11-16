import SwiftUI

/// The bottom-trailing corner the skip pill and the Up Next card share.
/// The two are never up together, so one inset serves both.
nonisolated enum PlayerCornerMetrics {
    #if os(tvOS)
    /// Clears the transport so a prompt never overlaps it.
    static let bottomInset: CGFloat = 240
    #else
    static let bottomInset: CGFloat = 130
    /// Clears two lines of subtitles where the transport is elsewhere.
    static let subtitleInset: CGFloat = 96
    #endif
}

#if os(iOS)
extension EnvironmentValues {
    /// False above a fold: the transport is on the other side of it, and a
    /// prompt has only the subtitles to clear.
    @Entry var playerCornerPromptClearsTransport = true
}

private struct PlayerCornerPromptPlacement: ViewModifier {
    @Environment(\.playerCornerPromptClearsTransport) private var clearsTransport

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, Metrics.screenGutter)
            .padding(.bottom, clearsTransport ? PlayerCornerMetrics.bottomInset : PlayerCornerMetrics.subtitleInset)
    }
}
#endif

extension View {
    /// Places a transient prompt in the player's corner. It scales in
    /// unless Reduce Motion is on.
    func playerCornerPrompt(reduceMotion: Bool) -> some View {
        transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            #if os(iOS)
            .modifier(PlayerCornerPromptPlacement())
            #else
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, Metrics.screenGutter)
            .padding(.bottom, PlayerCornerMetrics.bottomInset)
            #endif
    }

    /// Lifts a corner prompt off the video.
    func playerCornerPromptShadow() -> some View {
        shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}
