import Foundation

// What this session tells the server it can do.
extension JellyfinClient {
    /// `ClientCapabilitiesDto`, with only the fields Lagoon can claim.
    nonisolated struct ClientCapabilities: Encodable {
        let playableMediaTypes: [String]
        let supportedCommands: [String]
        let supportsMediaControl: Bool
        let supportsPersistentIdentifier: Bool
    }

    /// Registers this session's capabilities.
    ///
    /// `SupportedCommands` stays empty until the player handles
    /// `GeneralCommand`; otherwise other clients offer controls that do
    /// nothing. SyncPlay works without this call.
    func reportCapabilities() async throws {
        try await postVoid("Sessions/Capabilities/Full", body: ClientCapabilities(
            playableMediaTypes: ["Video"],
            supportedCommands: [],
            supportsMediaControl: true,
            supportsPersistentIdentifier: true
        ))
    }
}
