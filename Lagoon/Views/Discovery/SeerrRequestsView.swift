import SwiftUI
import Observation

@Observable
private final class SeerrRequestsViewModel {
    var requests: [SeerrMediaRequest] = []
    var page = 0
    var totalPages = 1
    var isLoading = false
    var errorMessage: String?
    private var loadGeneration = 0

    func load(
        client: SeerrClient,
        user: SeerrUser,
        filter: SeerrRequestFilter,
        onlyMine: Bool,
        reset: Bool = false
    ) async {
        if reset {
            // A filter/scope change owns a new generation. Let it supersede
            // an older request whose task is still unwinding after SwiftUI
            // cancelled it.
            loadGeneration += 1
            requests = []
            page = 0
            totalPages = 1
        } else {
            guard !isLoading else { return }
        }
        guard page < totalPages else { return }
        let generation = loadGeneration
        isLoading = true
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        errorMessage = nil
        do {
            let result = try await client.requests(
                take: 20,
                skip: page * 20,
                filter: filter,
                requestedBy: onlyMine ? user.id : nil
            )
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let existing = Set(requests.map(\.id))
            requests += result.results.filter { !existing.contains($0.id) }
            page = result.pageInfo.page
            totalPages = result.pageInfo.pages
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SeerrRequestsView: View {
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = SeerrRequestsViewModel()
    @State private var filter = SeerrRequestFilter.all
    @State private var onlyMine = false
    @State private var refreshID = 0
    let posterLayout = PosterLayout()

    var body: some View {
        Group {
            if let user = seerr.user {
                content(user: user)
            } else {
                signedOutContent
            }
        }
        // Keep the fetch on the stable screen root. Putting it on the
        // ScrollView/LoadingView branches made each isLoading transition
        // remove and cancel the task, producing an endless spinner.
        .task(id: seerr.user.map(loadID) ?? "signed-out") {
            guard let user = seerr.user else { return }
            await reload(user: user)
        }
        // Returning from a moderation/detail screen should reconcile the
        // row that may have changed there without tying refresh to a child
        // view that is replaced during loading.
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
                    LazyVGrid(columns: posterLayout.columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(Array(viewModel.requests.enumerated()), id: \.element.id) { index, request in
                            SeerrRequestCard(request: request)
                                .onAppear {
                                    guard index >= viewModel.requests.count - Metrics.gridColumns * 3 else {
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

/// One request as a poster card, the same shape the rest of the app uses for
/// media. It replaced a full-width glass slab holding a small poster in a lot
/// of empty space, which made a handful of requests fill the screen and
/// matched nothing else in the app.
private struct SeerrRequestCard: View {
    let request: SeerrMediaRequest
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var details: SeerrMediaDetails?
    let layout = PosterLayout()

    /// "Processing" says nothing about whether anything is happening. When
    /// the server knows how far the download has got, say that instead
    /// (HEL-116).
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

    /// A transfer that is actually moving gets the falling arrow; everything
    /// else takes the state's own motion.
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

                    // One word, like the availability badges on the Discover
                    // cards. The full "Pending Approval" wrapped to two lines
                    // and covered a third of the artwork.
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

/// The request detail's data and its refresh rules, kept out of the view
/// because HEL-136 states them as behaviour — poll only what can change, and
/// hold the last good snapshot through a transient failure — and behaviour
/// that exists only inside a `View`'s private `@State` cannot be tested.
@Observable
final class SeerrRequestDetailModel {
    var currentRequest: SeerrMediaRequest
    private(set) var details: SeerrMediaDetails?
    private(set) var jellyfinItem: MediaItem?
    private(set) var qualityProfile: String?
    private(set) var isLoading = true
    var errorMessage: String?
    /// Whether the page has ever rendered a good snapshot. Not the same
    /// question as `details == nil`: a request whose media carries no TMDB id
    /// has no details to load at all, so asking about `details` painted the
    /// error state over a perfectly good page on every transient poll failure.
    private(set) var hasLoadedOnce = false
    private var didResolveQualityProfile = false
    private var didResolveAvailableMedia = false

    init(request: SeerrMediaRequest) {
        currentRequest = request
    }

    func load(
        client: SeerrClient,
        jellyfin: JellyfinClient,
        isRefresh: Bool = false
    ) async {
        if !isRefresh { isLoading = true }
        defer {
            if !isRefresh { isLoading = false }
        }
        do {
            let loadedRequest = try await client.request(id: currentRequest.id)
            let loadedDetails = try await mediaDetails(
                for: loadedRequest,
                client: client,
                isRefresh: isRefresh
            )
            let loadedJellyfinItem = await jellyfinItem(
                for: loadedRequest,
                details: loadedDetails,
                jellyfin: jellyfin
            )
            let loadedQualityProfile: String?
            if didResolveQualityProfile {
                loadedQualityProfile = qualityProfile
            } else {
                loadedQualityProfile = await qualityProfile(for: loadedRequest, client: client)
            }
            // The cadence can change as this assignment lands. Publish one
            // complete snapshot before SwiftUI replaces the polling task.
            guard !Task.isCancelled else { return }
            currentRequest = loadedRequest
            details = loadedDetails
            jellyfinItem = loadedJellyfinItem
            qualityProfile = loadedQualityProfile
            didResolveQualityProfile = true
            if Self.isInLibrary(loadedRequest) { didResolveAvailableMedia = true }
            hasLoadedOnce = true
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            // Live refresh is reconciliation, not a new page load. A brief
            // Seerr/Radarr outage must not erase a useful percentage or ETA.
            if !isRefresh || !hasLoadedOnce {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Everything this page shows live — status, percentage, ETA — rides on
    /// the request itself. TMDB supplies title, overview, genres, artwork and
    /// year, none of which change while a request is being watched, so a poll
    /// re-reads TMDB only when it must: `jellyfinMediaId` lands on the media
    /// row when the title reaches the library, and that gates "Open in Lagoon".
    /// Availability flipping therefore buys exactly one more fetch, not one
    /// every ten seconds (HEL-136).
    private func mediaDetails(
        for request: SeerrMediaRequest,
        client: SeerrClient,
        isRefresh: Bool
    ) async throws -> SeerrMediaDetails? {
        guard let tmdbID = request.tmdbID else { return nil }
        let needsStaticMetadata = !isRefresh
            || details == nil
            || (Self.isInLibrary(request) && !didResolveAvailableMedia)
        guard needsStaticMetadata else { return details }
        return try await client.details(id: tmdbID, mediaType: request.resolvedMediaType)
    }

    /// Names the quality profile the request was made against. `MediaRequest`
    /// carries only a `profileId`, so the name comes from the Radarr/Sonarr
    /// service; when the request does not say which server, the default one
    /// is the server that would have taken it (HEL-118).
    ///
    /// Best-effort throughout: a missing profile is one absent token, never
    /// an error on a page that is about the request.
    private func qualityProfile(
        for request: SeerrMediaRequest,
        client: SeerrClient
    ) async -> String? {
        let mediaType = request.resolvedMediaType
        guard mediaType != .person else {
            return nil
        }
        let services = (try? await client.services(mediaType)) ?? []
        let wants4k = request.is4k == true
        // The server the request names, else the default one for its
        // resolution, which is the server that would have taken it.
        let service = services.first { $0.id == request.serverId }
            ?? services.first { $0.isDefault && $0.is4k == wants4k }
            ?? services.first(where: \.isDefault)

        // `profileId` is only set when the requester explicitly chose one,
        // which needs REQUEST_ADVANCED and is rare. Everything else inherits
        // the server's active profile, and *that* is what an approver is
        // agreeing to fetch.
        guard let profileID = request.profileId ?? service?.activeProfileId,
              let serverID = service?.id
        else {
            return nil
        }
        let profiles = (try? await client.qualityProfiles(mediaType, serverID: serverID)) ?? []
        return profiles.first { $0.id == profileID }?.name
    }

    /// A request whose title has arrived should be playable from here rather
    /// than only removable — the same match `SeerrMediaDetailView` makes, and
    /// on the same terms: the Jellyfin id Seerr recorded when it can, an
    /// exact TMDB lookup when it cannot (HEL-115). Once matched, the item is
    /// as static as the artwork, so a poll keeps the one it already has.
    private func jellyfinItem(
        for request: SeerrMediaRequest,
        details: SeerrMediaDetails?,
        jellyfin: JellyfinClient
    ) async -> MediaItem? {
        guard Self.isInLibrary(request) else { return nil }
        if let resolved = jellyfinItem { return resolved }
        let jellyfinID = details?.mediaInfo?.jellyfinMediaId
        if let jellyfinID, !jellyfinID.isEmpty {
            return try? await jellyfin.item(id: jellyfinID)
        } else if let tmdbID = request.tmdbID {
            return try? await jellyfin.item(
                tmdbID: tmdbID,
                mediaType: request.resolvedMediaType
            )
        }
        return nil
    }

    /// Whether the title is playable to any degree, which is what makes the
    /// Jellyfin id worth resolving.
    private nonisolated static func isInLibrary(_ request: SeerrMediaRequest) -> Bool {
        request.progress == .available || request.progress == .partiallyAvailable
    }
}

struct SeerrRequestDetailView: View {
    let request: SeerrMediaRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrSessionStore.self) private var seerr
    @Environment(SessionStore.self) private var session
    @State private var model: SeerrRequestDetailModel
    @State private var isMutating = false
    @State private var confirmation: Confirmation?
    @State private var isShowingProgressDetail = false

    init(request: SeerrMediaRequest) {
        self.request = request
        _model = State(initialValue: SeerrRequestDetailModel(request: request))
    }

    private var currentRequest: SeerrMediaRequest { model.currentRequest }
    private var details: SeerrMediaDetails? { model.details }
    private var jellyfinItem: MediaItem? { model.jellyfinItem }
    private var qualityProfile: String? { model.qualityProfile }

    var body: some View {
        Group {
            if model.isLoading, !model.hasLoadedOnce {
                LoadingView()
            } else {
                // The same scaffold every other detail page uses. Hand-rolling
                // one here is what produced the narrow centred box: nothing
                // claimed the page width, so the ScrollView hugged its
                // content and the background was sized to that. The scaffold
                // pins the page to the screen it belongs to — its own comment
                // records this being fixed once already (HEL-41).
                DetailPageScaffold(
                    backdropURL: SeerrClient.imageURL(path: details?.backdropPath, width: 1280)
                ) {
                    DetailMetadataHeader(
                        subtitle: detailSubtitle,
                        factTokens: factTokens,
                        genres: details?.genres?.map(\.name) ?? [],
                        overview: details?.overview
                    ) {
                        Text(details?.displayTitle ?? "Request #\(request.id)")
                            .font(.largeTitle.bold())
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } buttons: {
                        actions
                    }

                    if let errorMessage = model.errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal, Metrics.screenGutter)
                    }
                }
            }
        }
        .task { await model.load(client: seerr.client, jellyfin: session.client) }
        .seerrLiveRefreshable(
            cadence: SeerrLiveRefreshCadence.request(currentRequest),
            isPaused: model.isLoading || isMutating
        ) {
            await model.load(client: seerr.client, jellyfin: session.client, isRefresh: true)
        }
        .confirmationDialog(
            confirmation.map(confirmationTitle) ?? String(localized: "Update Request"),
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmationActionTitle(confirmation), role: confirmation.role) {
                    apply(confirmation)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            currentRequest.downloadProgress?.isImporting == true
                ? String(localized: "Importing")
                : String(localized: "Downloading"),
            isPresented: $isShowingProgressDetail
        ) {
            Button("OK") { isShowingProgressDetail = false }
        } message: {
            Text(progressDetailMessage)
        }
        .accessibilityIdentifier("seerr.request.detail.\(request.id)")
    }

    /// What the one-line subtitle has no room for: how many downloads the
    /// title is spread across, and what the server is actually fetching.
    private var progressDetailMessage: String {
        guard let progress = currentRequest.downloadProgress else {
            return String(localized: "This title has been approved and is being added to your library.")
        }
        var lines = [progress.summary]
        if progress.downloadCount > 1 {
            lines.append(String(localized: "\(progress.downloadCount) downloads."))
        }
        return lines.joined(separator: " ")
    }

    /// The short form. The subtitle above already carries the full sentence,
    /// and repeating it here put the same words on screen twice.
    private var processingBadgeTitle: String {
        guard let progress = currentRequest.downloadProgress else {
            return currentRequest.progress.title
        }
        return progress.isImporting ? String(localized: "Importing") : progress.percentText
    }

    private var processingSymbol: String {
        guard let progress = currentRequest.downloadProgress else {
            return currentRequest.progress.symbol
        }
        return progress.isImporting ? "square.and.arrow.down" : "arrow.down.circle"
    }

    private var processingMotion: SeerrStatusMotion {
        currentRequest.downloadProgress == nil ? currentRequest.progress.motion : .bounce
    }

    private var detailSubtitle: String {
        if currentRequest.progress == .processing, let progress = currentRequest.downloadProgress {
            return progress.summary
        }
        return currentRequest.progress.title
    }

    private var factTokens: [String] {
        var tokens: [String] = []
        if let requestedBy = currentRequest.requestedBy?.name {
            tokens.append(String(localized: "Requested by \(requestedBy)"))
        }
        if let seasons = currentRequest.seasons, !seasons.isEmpty {
            let numbers = seasons.map { String($0.seasonNumber) }.joined(separator: ", ")
            tokens.append(seasons.count == 1
                ? String(localized: "Season \(numbers)")
                : String(localized: "Seasons \(numbers)"))
        }
        if currentRequest.is4k == true { tokens.append("4K") }
        // What an approver is actually agreeing to fetch (HEL-118).
        if let qualityProfile { tokens.append(qualityProfile) }
        if let year = details?.year { tokens.append(year) }
        return tokens
    }

    /// A request that is not pending used to render no actions at all, so an
    /// approved or declined one was a dead end. Jellyseerr allows removing a
    /// request in any state, and a manager looking at their own pending
    /// request previously got Approve/Decline with no way to cancel it,
    /// because the first branch won.
    @ViewBuilder
    private var actions: some View {
        if isMutating {
            ProgressView()
        } else {
            AdaptiveActionStack {
                // A title still on its way has nothing to act on, so this is
                // the one thing worth focusing — and the glyph animates while
                // it is (HEL-117).
                if currentRequest.progress == .processing {
                    Button {
                        isShowingProgressDetail = true
                    } label: {
                        SeerrStatusLabel(
                            title: processingBadgeTitle,
                            symbol: processingSymbol,
                            motion: processingMotion
                        )
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.request.progress")
                }
                // Watching it is the point of having requested it, so this
                // leads.
                if let jellyfinItem {
                    NavigationLink(value: SeerrNavigationRoute.jellyfinItem(jellyfinItem)) {
                        Label("Open in Lagoon", systemImage: "play.fill")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.request.open")
                }
                if currentRequest.requestStatus == .pending, canModerate {
                    Button("Approve") { confirmation = .approve }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("seerr.request.approve")
                    Button("Decline", role: .destructive) { confirmation = .decline }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("seerr.request.decline")
                }
                if canRemove {
                    Button(removeTitle, role: .destructive) { confirmation = .delete }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("seerr.request.cancel")
                }
            }
        }
    }

    private var canModerate: Bool {
        seerr.user?.canManageRequests == true
    }

    private var isOwnRequest: Bool {
        currentRequest.requestedBy?.id != nil && currentRequest.requestedBy?.id == seerr.user?.id
    }

    private var canRemove: Bool {
        canModerate || isOwnRequest
    }

    /// Withdrawing something still awaiting approval is a cancellation;
    /// removing one already decided is not. The confirmation has to agree
    /// with the button that opened it.
    private var removeTitle: LocalizedStringKey {
        currentRequest.requestStatus == .pending ? "Cancel Request" : "Remove Request"
    }

    private func confirmationTitle(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .approve: String(localized: "Approve this request?")
        case .decline: String(localized: "Decline this request?")
        case .delete:
            currentRequest.requestStatus == .pending
                ? String(localized: "Cancel this request?")
                : String(localized: "Remove this request?")
        }
    }

    private func confirmationActionTitle(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .approve: String(localized: "Approve")
        case .decline: String(localized: "Decline")
        case .delete:
            currentRequest.requestStatus == .pending
                ? String(localized: "Cancel Request")
                : String(localized: "Remove Request")
        }
    }

    private func apply(_ confirmation: Confirmation) {
        self.confirmation = nil
        isMutating = true
        model.errorMessage = nil
        Task {
            defer { isMutating = false }
            do {
                switch confirmation {
                case .approve:
                    model.currentRequest = try await seerr.client.setRequestStatus(
                        id: request.id,
                        approved: true
                    )
                    await reconcile()
                case .decline:
                    model.currentRequest = try await seerr.client.setRequestStatus(
                        id: request.id,
                        approved: false
                    )
                    await reconcile()
                case .delete:
                    try await seerr.client.deleteRequest(id: request.id)
                    dismiss()
                    return
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// A moderation action changes the very state the page is watching, so it
    /// gets an immediate reconcile rather than waiting out the cadence.
    private func reconcile() async {
        await model.load(client: seerr.client, jellyfin: session.client, isRefresh: true)
    }

    private enum Confirmation {
        case approve
        case decline
        case delete

        var role: ButtonRole? {
            switch self {
            case .approve: nil
            case .decline, .delete: .destructive
            }
        }
    }
}
