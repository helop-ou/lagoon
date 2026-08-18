import SwiftUI

@main
struct LagoonApp: App {
    @State private var deepLinks = DeepLinkRouter()

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
    }
}
