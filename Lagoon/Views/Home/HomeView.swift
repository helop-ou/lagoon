import SwiftUI

struct HomeView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = HomeViewModel()
    @State private var playerItem: PlayerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.isLoading {
                LoadingView()
            } else if let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await viewModel.retry(client: session.client) }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HeroSection(items: viewModel.heroItems)
                            .padding(.top, Metrics.Space.s)
                            .padding(.bottom, Metrics.Space.xl)

                        MediaRail(
                            title: "Continue Watching",
                            items: viewModel.resume,
                            style: .landscape,
                            playAction: { playerItem = PlayerItem(media: $0) },
                            onUserDataChange: refreshUserData
                        )
                        MediaRail(
                            title: "Next Up",
                            items: viewModel.nextUp,
                            style: .landscape,
                            playAction: { playerItem = PlayerItem(media: $0) },
                            onUserDataChange: refreshUserData
                        )
                        // Above Recently Added: things you deliberately
                        // starred outrank things the server happened to
                        // ingest, and the rail hides itself when empty.
                        MediaRail(
                            title: "Favorites",
                            items: viewModel.favorites,
                            onUserDataChange: refreshUserData
                        )
                        ForEach(viewModel.latestRails) { rail in
                            MediaRail(title: rail.title, items: rail.items, onUserDataChange: refreshUserData)
                        }
                        // Whatever the server's Home Screen Sections plugin
                        // adds on top (HEL-47) — nothing at all without it.
                        ForEach(viewModel.pluginRails) { rail in
                            MediaRail(
                                title: rail.title,
                                items: rail.items,
                                style: rail.style,
                                onUserDataChange: refreshUserData
                            )
                        }

                        Color.clear.frame(height: 60)
                    }
                }
                .scrollClipDisabled()
            }
        }
        .task {
            await viewModel.load(client: session.client)
        }
        .onAppear {
            Task { await viewModel.refreshProgress(client: session.client) }
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .fullScreenCover(item: $playerItem) { item in
            VideoPlayerView(playerItem: item)
                .preferredColorScheme(.dark)
        }
    }

    /// Marking something watched or favourited from a card menu can move it
    /// between Continue Watching, Next Up and Favorites, so all three are
    /// re-fetched rather than guessing which one moved.
    private func refreshUserData() async {
        await viewModel.refreshProgress(client: session.client)
    }
}
