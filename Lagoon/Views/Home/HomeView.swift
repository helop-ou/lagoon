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
                            .padding(.top, 8)
                            .padding(.bottom, 28)

                        MediaRail(title: "Continue Watching", items: viewModel.resume, style: .landscape) { item in
                            playerItem = PlayerItem(media: item)
                        }
                        MediaRail(title: "Next Up", items: viewModel.nextUp, style: .landscape) { item in
                            playerItem = PlayerItem(media: item)
                        }
                        ForEach(viewModel.latestRails) { rail in
                            MediaRail(title: rail.title, items: rail.items)
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
        .fullScreenCover(item: $playerItem) { item in
            VideoPlayerView(playerItem: item)
                .preferredColorScheme(.dark)
        }
    }
}
