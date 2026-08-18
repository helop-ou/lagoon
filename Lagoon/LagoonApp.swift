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
        }
    }
}
