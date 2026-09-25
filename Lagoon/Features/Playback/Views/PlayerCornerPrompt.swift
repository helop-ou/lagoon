import SwiftUI

/// The bottom-trailing corner the skip pill and the Up Next card share.
/// The two are never up together, so one inset serves both.
private nonisolated enum PlayerCornerMetrics {
    #if os(tvOS)
    /// Clears the transport so a prompt never overlaps it.
    static let bottomInset: CGFloat = 240
    #else
    static let bottomInset: CGFloat = 130
    #endif
}

extension View {
    /// Places a transient prompt in the player's corner. It scales in
    /// unless Reduce Motion is on.
    func playerCornerPrompt(reduceMotion: Bool) -> some View {
        transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, Metrics.screenGutter)
            .padding(.bottom, PlayerCornerMetrics.bottomInset)
    }

    /// Lifts a corner prompt off the video.
    func playerCornerPromptShadow() -> some View {
        shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}
