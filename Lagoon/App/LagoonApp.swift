import SwiftUI

@main
struct LagoonApp: App {
    @State private var deepLinks = DeepLinkRouter()
    /// Holds the process-event observers for the diagnostics history
    /// (HEL-159) for the life of the app.
    private let diagnosticsObserver: DiagnosticsProcessObserver

    init() {
        diagnosticsObserver = DiagnosticsConfiguration.install()
        // The path has to be under observation before the first negotiation
        // asks what it costs (HEL-108). Until the monitor has reported,
        // `NetworkPathObserver` answers "unrestricted", which is the
        // behaviour that existed before the cap.
        NetworkPathObserver.shared.start()
        #if DEBUG && os(iOS)
        // HEL-166 spike: the background session must exist before the
        // system delivers events for transfers that outlived the process.
        _ = DownloadSpikeStore.shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(deepLinks)
                // Top Shelf selections arrive here, including on a cold
                // launch straight from the TV's home screen — which is why
                // the router holds the request rather than acting on it.
                .onOpenURL { deepLinks.handle($0) }
                .preferredColorScheme(.dark)
                // Defensive display-mode reset (HEL-64): the player
                // restores the mode in its exit path, but a killed process
                // never runs exit paths — a harness doing exactly that
                // left a TV wedged at the content mode. A fresh launch
                // therefore always starts from "no preference".
                .task {
                    #if os(tvOS)
                    DisplayModeMatcher.apply(nil)
                    #endif
                }
        }
        #if DEBUG && os(iOS)
        .backgroundTask(.urlSession(DownloadSpikeStore.sessionIdentifier)) {
            // Relaunched in the background to finish a spike transfer: the
            // store's init above already re-created the session and its
            // delegate, which is all the system needs. Touching it here
            // keeps that true if the init order ever changes.
            _ = await MainActor.run { DownloadSpikeStore.shared }
        }
        #endif
    }
}
