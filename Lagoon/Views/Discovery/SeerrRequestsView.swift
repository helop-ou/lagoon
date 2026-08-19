import SwiftUI
import Observation

@Observable
private final class SeerrRequestsViewModel {
    var requests: [SeerrMediaRequest] = []
    var page = 0
    var totalPages = 1
    var isLoading = false
    var errorMessage: String?

    func load(
        client: SeerrClient,
        user: SeerrUser,
        filter: SeerrRequestFilter,
        onlyMine: Bool,
        reset: Bool = false
    ) async {
        guard !isLoading else { return }
        if reset {
            requests = []
            page = 0
            totalPages = 1
        }
        guard page < totalPages else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let result = try await client.requests(
                take: 20,
                skip: page * 20,
                filter: filter,
                requestedBy: onlyMine ? user.id : nil
            )
            guard !Task.isCancelled else { return }
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
                ErrorStateView(message: SeerrError.unauthenticated.localizedDescription) {
                    Task { await seerr.refreshUser() }
                }
            }
        }
        .navigationTitle(onlyMine || seerr.user?.canViewAllRequests != true ? "My Requests" : "All Requests")
        .accessibilityIdentifier("seerr.requests.list")
    }

    @ViewBuilder
    private func content(user: SeerrUser) -> some View {
        if viewModel.isLoading, viewModel.requests.isEmpty {
            LoadingView()
                .task(id: loadID(user: user)) { await reload(user: user) }
        } else if let error = viewModel.errorMessage, viewModel.requests.isEmpty {
            ErrorStateView(message: error) { refreshID += 1 }
                .task(id: loadID(user: user)) { await reload(user: user) }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.Space.l) {
                    controls(user: user)

                    if viewModel.requests.isEmpty {
                        VStack(spacing: Metrics.Space.m) {
                            Image(systemName: "tray")
                                .font(Typography.glyph)
                                .foregroundStyle(.secondary)
                            Text("No \(filter == .all ? "" : filter.title.lowercased() + " ")requests")
                                .font(.title3)
                        }
                        .frame(maxWidth: .infinity, minHeight: 400)
                        .focusable()
                    } else {
                        ForEach(viewModel.requests) { request in
                            SeerrRequestRow(request: request)
                                .onAppear {
                                    guard request.id == viewModel.requests.suffix(4).first?.id else { return }
                                    Task {
                                        await viewModel.load(
                                            client: seerr.client,
                                            user: user,
                                            filter: filter,
                                            onlyMine: onlyMine
                                        )
                                    }
                                }
                        }
                    }

                    if viewModel.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(Metrics.Space.xxl)
                    }
                }
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.xxl)
            }
            .scrollClipDisabled()
            .refreshable { await reload(user: user) }
            .task(id: loadID(user: user)) { await reload(user: user) }
            .onAppear {
                guard !viewModel.requests.isEmpty else { return }
                refreshID += 1
            }
        }
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
        "\(user.id):\(filter.rawValue):\(onlyMine):\(refreshID)"
    }

    private func reload(user: SeerrUser) async {
        await viewModel.load(
            client: seerr.client,
            user: user,
            filter: filter,
            onlyMine: onlyMine,
            reset: true
        )
    }
}

private struct SeerrRequestRow: View {
    let request: SeerrMediaRequest
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var details: SeerrMediaDetails?

    var body: some View {
        NavigationLink(value: SeerrNavigationRoute.request(request)) {
            HStack(spacing: Metrics.Space.l) {
                CachedAsyncImage(
                    url: SeerrClient.imageURL(path: details?.posterPath, width: 300),
                    maxPixelSize: 240
                ) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.07)
                }
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    Text(details?.displayTitle ?? "Loading \(request.resolvedMediaType.title)…")
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: Metrics.Space.m) {
                        Label(request.requestStatus.title, systemImage: statusIcon)
                        if let name = request.requestedBy?.name {
                            Text("Requested by \(name)")
                        }
                    }
                    .font(.caption)
                    if let year = details?.year {
                        Text(year).font(.caption2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.forward")
            }
            .padding(Metrics.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("seerr.request.\(request.id)")
        .task(id: request.id) {
            guard let tmdbID = request.tmdbID else { return }
            details = try? await seerr.client.details(id: tmdbID, mediaType: request.resolvedMediaType)
        }
    }

    private var statusIcon: String {
        switch request.requestStatus {
        case .pending: "clock"
        case .approved: "checkmark.circle"
        case .declined: "xmark.circle"
        }
    }

    private var posterWidth: CGFloat {
        #if os(tvOS)
        120
        #else
        80
        #endif
    }

    private var posterHeight: CGFloat { posterWidth * 1.5 }
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
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                        HStack(alignment: .top, spacing: Metrics.Space.xxl) {
                            CachedAsyncImage(
                                url: SeerrClient.imageURL(path: details?.posterPath, width: 500),
                                maxPixelSize: Int(Metrics.posterHeight)
                            ) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.white.opacity(0.07)
                            }
                            .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

                            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                                Text(details?.displayTitle ?? "Request #\(request.id)")
                                    .font(.largeTitle.bold())
                                Label(currentRequest.requestStatus.title, systemImage: statusIcon)
                                    .font(.headline)
                                if let requestedBy = currentRequest.requestedBy?.name {
                                    Text("Requested by \(requestedBy)").font(.callout)
                                }
                                if let seasons = currentRequest.seasons, !seasons.isEmpty {
                                    Text("Seasons \(seasons.map { String($0.seasonNumber) }.joined(separator: ", "))")
                                        .font(.callout)
                                }
                                if let overview = details?.overview {
                                    Text(overview)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(7)
                                        .frame(maxWidth: 760, alignment: .leading)
                                }
                                actions
                                if let errorMessage {
                                    Text(errorMessage).font(.callout).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.xxl)
                }
                .scrollClipDisabled()
            }
        }
        .navigationTitle(details?.displayTitle ?? "Request")
        .task { await load() }
        .confirmationDialog(
            confirmation?.title ?? "Update Request",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let confirmation {
                Button(confirmation.actionTitle, role: confirmation.role) { apply(confirmation) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("seerr.request.detail.\(request.id)")
    }

    @ViewBuilder
    private var actions: some View {
        if isMutating {
            ProgressView()
        } else if currentRequest.requestStatus == .pending, seerr.user?.canManageRequests == true {
            HStack(spacing: Metrics.Space.m) {
                Button("Approve") { confirmation = .approve }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.request.approve")
                Button("Decline", role: .destructive) { confirmation = .decline }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("seerr.request.decline")
            }
        } else if currentRequest.requestStatus == .pending,
                  currentRequest.requestedBy?.id == seerr.user?.id {
            Button("Cancel Request", role: .destructive) { confirmation = .delete }
                .buttonStyle(.glass)
                .accessibilityIdentifier("seerr.request.cancel")
        }
    }

    private var statusIcon: String {
        switch currentRequest.requestStatus {
        case .pending: "clock"
        case .approved: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
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

        var title: String {
            switch self {
            case .approve: "Approve this request?"
            case .decline: "Decline this request?"
            case .delete: "Cancel this request?"
            }
        }
        var actionTitle: String {
            switch self {
            case .approve: "Approve"
            case .decline: "Decline"
            case .delete: "Cancel Request"
            }
        }
        var role: ButtonRole? {
            switch self {
            case .approve: nil
            case .decline, .delete: .destructive
            }
        }
    }
}
