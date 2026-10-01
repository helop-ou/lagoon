import SwiftUI

/// Whether a player covers the pages. Neither platform's player removes the
/// pages beneath it, so decoration that redraws asks this to rest under
/// playback. The playback feature conforms and the app injects it.
@MainActor
protocol PlayerCoverState: AnyObject {
    var isPlayerUp: Bool { get }
}

extension EnvironmentValues {
    @Entry var playerCover: (any PlayerCoverState)?
}
