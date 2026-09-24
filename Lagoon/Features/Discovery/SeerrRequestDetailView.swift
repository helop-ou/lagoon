import SwiftUI

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
                // Use the shared scaffold: a hand-rolled page hugs its content
                // and renders as a narrow centred box.
                DetailPageScaffold(
                    backdropURL: SeerrClient.imageURL(path: details?.backdropPath, width: Metrics.detailBackdropRequestWidth)
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

    /// Download count and what the server is fetching.
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

    /// Short form; the subtitle carries the full sentence.
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
        if let qualityProfile { tokens.append(qualityProfile) }
        if let year = details?.year { tokens.append(year) }
        return tokens
    }

    /// Jellyseerr allows removing a request in any state, including a
    /// manager's own pending one alongside Approve/Decline.
    @ViewBuilder
    private var actions: some View {
        if isMutating {
            ProgressView()
        } else {
            AdaptiveActionStack {
                // Nothing to act on while processing, so this takes focus.
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
                // Leads when the title is watchable.
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

    /// Must match the button that opened the confirmation.
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

    /// Moderation reconciles at once rather than waiting for the cadence.
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
