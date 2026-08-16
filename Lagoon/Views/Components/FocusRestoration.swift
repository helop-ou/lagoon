import SwiftUI

/// tvOS does not restore focus to the presenting screen after dismissing a
/// fullScreenCover that contained custom focusable content (the player's
/// surface) — the remote goes dead. This scope asks the focus system to
/// re-resolve a default once the player item goes nil, after the dismissal
/// transition has finished.
struct PlayerDismissFocusScope: ViewModifier {
    let isPresented: Bool

    #if os(tvOS)
    @Namespace private var namespace
    @Environment(\.resetFocus) private var resetFocus
    #endif

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .focusScope(namespace)
            .onChange(of: isPresented) { wasPresented, isNowPresented in
                guard wasPresented, !isNowPresented else { return }
                Task { @MainActor in
                    // Past the cover's dismissal animation, or the reset no-ops.
                    try? await Task.sleep(for: .milliseconds(350))
                    resetFocus(in: namespace)
                }
            }
        #else
        content
        #endif
    }
}

extension View {
    /// Apply to any screen that presents the player in a fullScreenCover.
    func restoresFocusAfterPlayer(isPresented: Bool) -> some View {
        modifier(PlayerDismissFocusScope(isPresented: isPresented))
    }
}
