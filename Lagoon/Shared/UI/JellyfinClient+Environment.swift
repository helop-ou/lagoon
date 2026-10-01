import SwiftUI

extension EnvironmentValues {
    /// The active account's client, for shared views that build artwork URLs
    /// or send a quick mutation. Injected beside the session that owns it, so
    /// shared views never depend on the session itself.
    @Entry var jellyfinClient: JellyfinClient?
}
