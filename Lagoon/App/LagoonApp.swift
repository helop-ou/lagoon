import SwiftUI

@main
struct LagoonApp: App {
    @State private var deepLinks = DeepLinkRouter()
    /// Keeps the diagnostics process observers alive for the app's lifetime.
    private let diagnosticsObserver: DiagnosticsProcessObserver

    init() {
        diagnosticsObserver = DiagnosticsConfiguration.install()
        // Without this the engine runs with default knobs and reports nothing.
        EngineConfiguration.install()
        // Must start before the first negotiation. Until it reports, the
        // path counts as unrestricted.
        NetworkPathObserver.shared.start()
        #if os(iOS)
        // The background session must exist before the system delivers
        // events for transfers that outlived the process.
        _ = DownloadStore.shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(deepLinks)
                // Top Shelf links can arrive on a cold launch, before a
                // session exists, so the router holds them.
                .onOpenURL { deepLinks.handle($0) }
                .preferredColorScheme(.dark)
                // A killed process never restores the display mode on
                // player exit, so every launch resets it.
                .task {
                    #if os(tvOS)
                    DisplayModeMatcher.apply(nil)
                    #endif
                }
        }
        #if os(iOS)
        .backgroundTask(.urlSession(DownloadStore.sessionIdentifier)) {
            // `init` already re-created the session. Wait until queued
            // callbacks reach the manifest on disk, so the OS does not
            // suspend the app mid-write.
            await DownloadStore.shared.finishBackgroundEvents()
        }
        #endif
    }
}
