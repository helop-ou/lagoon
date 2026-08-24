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
                    LazyVGrid(columns: Metrics.posterGridColumns, spacing: Metrics.gridRowSpacing) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            NavigationLink(value: SeerrNavigationRoute.request(request)) {
                ZStack(alignment: .topTrailing) {
                    CachedAsyncImage(
                        url: SeerrClient.imageURL(path: details?.posterPath, width: 500),
                        maxPixelSize: Int(Metrics.posterHeight)
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
                    .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                    .clipped()

                    // One word, like the availability badges on the Discover
                    // cards. The full "Pending Approval" wrapped to two lines
                    // and covered a third of the artwork.
                    Label(statusBadge, systemImage: statusIcon)
                        .font(.caption2.bold())
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .padding(.horizontal, Metrics.Space.s)
                        .padding(.vertical, Metrics.Space.xs)
                        .background(.regularMaterial, in: Capsule())
                        .padding(Metrics.Space.s)
                }
                .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .accessibilityLabel(details?.displayTitle ?? "Request \(request.id)")
            .accessibilityValue(request.requestStatus.title)
            .accessibilityIdentifier("seerr.request.\(request.id)")

            VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                Text(details?.displayTitle ?? "Loading \(request.resolvedMediaType.title)…")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let name = request.requestedBy?.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: Metrics.posterWidth, height: Metrics.posterCaptionHeight, alignment: .topLeading)
        }
        .frame(width: Metrics.posterWidth)
        .task(id: request.id) {
            guard let tmdbID = request.tmdbID else { return }
            details = try? await seerr.client.details(id: tmdbID, mediaType: request.resolvedMediaType)
        }
    }

    private var statusBadge: String {
        switch request.requestStatus {
        case .pending: String(localized: "Pending")
        case .approved: String(localized: "Approved")
        case .declined: String(localized: "Declined")
        }
    }

    private var statusIcon: String {
        switch request.requestStatus {
        case .pending: "clock"
        case .approved: "checkmark.circle"
        case .declined: "xmark.circle"
        }
    }
}

struct SeerrRequestDetailView: View {
    let request: SeerrMediaRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var currentRequest: SeerrMediaRequest
    @State private var details: SeerrMediaDetails?
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var errorMessage: String?
    @State private var confirmation: Confirmation?

    init(request: SeerrMediaRequest) {
        self.request = request
        _currentRequest = State(initialValue: request)
    }

    var body: some View {
        Group {
            if isLoading, details == nil {
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
                        subtitle: currentRequest.requestStatus.title,
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

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal, Metrics.screenGutter)
                    }
                }
            }
        }
        .task { await load() }
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
        .accessibilityIdentifier("seerr.request.detail.\(request.id)")
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
            HStack(spacing: Metrics.Space.m) {
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

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            currentRequest = (try? await seerr.client.request(id: request.id)) ?? currentRequest
            if let tmdbID = currentRequest.tmdbID {
                details = try await seerr.client.details(id: tmdbID, mediaType: currentRequest.resolvedMediaType)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ confirmation: Confirmation) {
        self.confirmation = nil
        isMutating = true
        errorMessage = nil
        Task {
            do {
                switch confirmation {
                case .approve:
                    currentRequest = try await seerr.client.setRequestStatus(id: request.id, approved: true)
                case .decline:
                    currentRequest = try await seerr.client.setRequestStatus(id: request.id, approved: false)
                case .delete:
                    try await seerr.client.deleteRequest(id: request.id)
                    dismiss()
                    return
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isMutating = false
        }
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
