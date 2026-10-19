import SwiftUI

/// Every video playlist, opened from Library. Each card opens the playlist's
/// page.
struct PlaylistsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    /// Nil until the first answer, and after a failed one.
    @State private var playlists: [CollectionShelfItem]?
    @State private var isLoading = false

    private let columns = [
        GridItem(.adaptive(minimum: Metrics.landscapeWidth), spacing: Metrics.cardSpacing, alignment: .topLeading),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                #if os(tvOS)
                Text("Playlists").font(.largeTitle.bold())
                #endif
                content
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.top, Metrics.Space.xxl)
            .padding(.bottom, Metrics.detailBottomPadding)
        }
        .scrollClipDisabled()
        .themedPageBackground()
        #if os(iOS)
        .navigationTitle("Playlists")
        #endif
        .task { await load() }
        .onChange(of: serverSync.generation) { _, _ in
            Task { await load() }
        }
        .accessibilityIdentifier("library.playlists.view")
    }

    @ViewBuilder
    private var content: some View {
        if let playlists, !playlists.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridRowSpacing) {
                ForEach(playlists) { playlist in
                    CollectionCard(collection: playlist, identifier: "playlist")
                }
            }
        } else if playlists == nil, isLoading {
            LoadingView()
        } else {
            // The only focusable element when empty. Without it Menu quits the app.
            InlineRetryView(message: playlists == nil
                ? String(localized: "Couldn't load your playlists.")
                : String(localized: "You have no video playlists.")
            ) {
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let loaded = await PlaylistShelf.load(client: session.client) {
            playlists = loaded
        } else if playlists?.isEmpty != false {
            playlists = nil
        }
    }
}
