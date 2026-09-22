import SwiftUI

struct SeerrRequestsView: View {
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = SeerrRequestsViewModel()
    @State private var filter = SeerrRequestFilter.all
    @State private var onlyMine = false
    @State private var refreshID = 0
    let posterLayout = PosterLayout()
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        Group {
            if let user = seerr.user {
                content(user: user)
            } else {
                signedOutContent
            }
        }
        .background(Theme.background.ignoresSafeArea())
        // Keep the fetch on the stable root: on the loading branches, each
        // isLoading change cancels the task and spins forever.
        .task(id: seerr.user.map(loadID) ?? "signed-out") {
            guard let user = seerr.user else { return }
            await reload(user: user)
        }
        // Reconcile rows changed on a detail screen, on the stable root.
        .onAppear {
            guard !viewModel.requests.isEmpty else { return }
            refreshID += 1
        }
        .accessibilityIdentifier("seerr.requests.list")
    }

    @ViewBuilder
    private func content(user: SeerrUser) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Space.l) {
                pageTitle
                controls(user: user)

                if viewModel.isLoading, viewModel.requests.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Requests")
                } else if let error = viewModel.errorMessage, viewModel.requests.isEmpty {
                    ErrorStateView(message: error) { refreshID += 1 }
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else if viewModel.requests.isEmpty {
                    VStack(spacing: Metrics.Space.m) {
                        Image(systemName: "tray")
                            .font(Typography.glyph)
                            .foregroundStyle(.secondary)
                        Text("No \(filter == .all ? "" : filter.title.lowercased() + " ")requests")
                            .font(.title3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    let grid = posterLayout.grid(fitting: gridWidth)
                    LazyVGrid(columns: grid.columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(Array(viewModel.requests.enumerated()), id: \.element.id) { index, request in
                            SeerrRequestCard(request: request)
                                .onAppear {
                                    guard index >= viewModel.requests.count - grid.columnCount * 3 else {
                                        return
                                    }
                                    Task {
                                        await viewModel.load(
                                            client: seerr.client,
                                            user: user,
                                            filter: filter,
                                            onlyMine: effectiveOnlyMine(for: user)
                                        )
                                    }
                                }
                        }
                    }
                    .environment(\.posterCardWidth, grid.cardWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                }

                if viewModel.isLoading, !viewModel.requests.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(Metrics.Space.xxl)
                        .accessibilityLabel("Loading more requests")
                } else if let error = viewModel.errorMessage, !viewModel.requests.isEmpty {
                    InlineRetryView(message: error) {
                        Task {
                            await viewModel.load(
                                client: seerr.client,
                                user: user,
                                filter: filter,
                                onlyMine: effectiveOnlyMine(for: user)
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.bottom, Metrics.Space.section)
        }
        .scrollClipDisabled()
        .refreshable { await reload(user: user) }
    }

    private var pageTitle: some View {
        Text(requestsTitle)
            .font(.largeTitle.bold())
            .padding(.top, Metrics.Space.xxl)
            .padding(.bottom, Metrics.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var signedOutContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                pageTitle
                    .padding(.horizontal, Metrics.screenGutter)
                ErrorStateView(message: SeerrError.unauthenticated.localizedDescription) {
                    Task { await seerr.refreshUser() }
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
            }
            .padding(.bottom, Metrics.Space.section)
        }
        .scrollClipDisabled()
    }

    private var requestsTitle: String {
        onlyMine || seerr.user?.canViewAllRequests != true ? "My Requests" : "All Requests"
    }

    private func controls(user: SeerrUser) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.Space.m) {
                if user.canViewAllRequests {
                    Button {
                        onlyMine.toggle()
                        refreshID += 1
                    } label: {
                        Label(onlyMine ? "My Requests" : "All Requests", systemImage: onlyMine ? "person" : "person.2")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.requests.scope")
                }

                ForEach(SeerrRequestFilter.allCases) { option in
                    Button {
                        guard filter != option else { return }
                        filter = option
                        refreshID += 1
                    } label: {
                        HStack {
                            Text(option.title)
                            if filter == option { Image(systemName: "checkmark") }
                        }
                        .fontWeight(filter == option ? .bold : .regular)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.requests.filter.\(option.rawValue)")
                }
            }
            .padding(.vertical, Metrics.Space.s)
        }
        .scrollClipDisabled()
    }

    private func loadID(user: SeerrUser) -> String {
        "\(user.id):\(filter.rawValue):\(effectiveOnlyMine(for: user)):\(refreshID)"
    }

    private func reload(user: SeerrUser) async {
        await viewModel.load(
            client: seerr.client,
            user: user,
            filter: filter,
            onlyMine: effectiveOnlyMine(for: user),
            reset: true
        )
    }

    private func effectiveOnlyMine(for user: SeerrUser) -> Bool {
        !user.canViewAllRequests || onlyMine
    }
}

/// One request as a poster card, the shape the rest of the app uses.
private struct SeerrRequestCard: View {
    let request: SeerrMediaRequest
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var details: SeerrMediaDetails?
    let layout = PosterLayout()

    /// Download progress in place of "Processing" when the server knows it.
    private var badgeTitle: String {
        guard request.progress == .processing, let progress = request.downloadProgress else {
            return request.progress.title
        }
        return progress.isImporting ? String(localized: "Importing") : progress.percentText
    }

    private var badgeSymbol: String {
        guard request.progress == .processing, let progress = request.downloadProgress else {
            return request.progress.symbol
        }
        return progress.isImporting ? "square.and.arrow.down" : "arrow.down.circle"
    }

    /// A moving transfer gets the falling arrow.
    private var badgeMotion: SeerrStatusMotion {
        guard request.progress == .processing, request.downloadProgress != nil else {
            return request.progress.motion
        }
        return .bounce
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            NavigationLink(value: SeerrNavigationRoute.request(request)) {
                ZStack(alignment: .topTrailing) {
                    CachedAsyncImage(
                        url: SeerrClient.imageURL(path: details?.posterPath, width: layout.imageWidth),
                        maxPixelSize: layout.imageSize
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack {
                            Color.white.opacity(0.07)
                            Text(details?.displayTitle ?? "")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(Metrics.Space.m)
                        }
                    }
                    .frame(width: layout.width, height: layout.height)
                    .clipped()

                    // One word: longer labels wrap and cover the artwork.
                    SeerrStatusLabel(title: badgeTitle, symbol: badgeSymbol, motion: badgeMotion)
                        .font(.caption2.bold())
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .padding(.horizontal, Metrics.Space.s)
                        .padding(.vertical, Metrics.Space.xs)
                        .background(.regularMaterial, in: Capsule())
                        .padding(Metrics.Space.s)
                }
                .frame(width: layout.width, height: layout.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .accessibilityLabel(details?.displayTitle ?? "Request \(request.id)")
            .accessibilityValue(badgeTitle)
            .accessibilityIdentifier("seerr.request.\(request.id)")

            VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                Text(details?.displayTitle ?? "Loading \(request.resolvedMediaType.title)…")
                    .font(.caption.weight(.medium))
                    .lineLimit(layout.captionLines)
                if let name = request.requestedBy?.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: layout.width, alignment: .leading)
            .frame(minHeight: layout.captionHeight, alignment: .topLeading)
        }
        .frame(width: layout.width)
        .task(id: request.id) {
            guard let tmdbID = request.tmdbID else { return }
            details = try? await seerr.client.details(id: tmdbID, mediaType: request.resolvedMediaType)
        }
    }
}
