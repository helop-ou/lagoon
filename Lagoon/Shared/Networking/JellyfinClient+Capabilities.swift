import Foundation

// What this session tells the server it can do (HEL-172).
extension JellyfinClient {
    /// `ClientCapabilitiesDto`. Only the four fields Lagoon can honestly
    /// claim are sent; the rest of the DTO is about remote control features
    /// that do not exist here yet.
    nonisolated struct ClientCapabilities: Encodable {
        let playableMediaTypes: [String]
        let supportedCommands: [String]
        let supportsMediaControl: Bool
        let supportsPersistentIdentifier: Bool
    }

    /// Registers this session's capabilities with the server.
    ///
    /// `SupportedCommands` is deliberately empty: the player does not yet
    /// handle `GeneralCommand` socket messages, and advertising a command
    /// Lagoon would silently drop is worse than advertising none — another
    /// client's dashboard would offer a control that does nothing. Fill it
    /// in when the player grows a handler.
    ///
    /// Not required for SyncPlay: a fixture 12.0.0 session that never posted
    /// this still received every group command over the socket (measured
    /// 2026-09-14). It is sent anyway so the session shows up in Jellyfin's
    /// dashboard as a video client that can be controlled.
    func reportCapabilities() async throws {
        try await postVoid("Sessions/Capabilities/Full", body: ClientCapabilities(
            playableMediaTypes: ["Video"],
            supportedCommands: [],
            supportsMediaControl: true,
            supportsPersistentIdentifier: true
        ))
    }
}
