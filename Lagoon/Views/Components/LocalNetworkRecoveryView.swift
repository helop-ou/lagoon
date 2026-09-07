import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared by server setup and optional-service setup; never guesses a
/// permission state from an address or generic connectivity failure.
struct LocalNetworkRecoveryView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(iOS)
        Button("Open Settings") {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            openURL(url)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("network.openSettings")
        #endif
    }
}
