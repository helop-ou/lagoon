import Foundation

/// What the primary button on a Seerr title page says and does, outside the
/// view so it can be tested.
///
/// One button draws every state. On Apple TV a button that is swapped for
/// another, or disabled, gives up the focus: after a request it landed on
/// the tab bar, and Back then left the app.
nonisolated struct SeerrPrimaryAction: Equatable {
    enum Tap: Equatable {
        /// Says what the status means.
        case explain(String)
        case confirmMovieRequest
        case confirmUnblock
        case chooseSeasons
    }

    /// What decides the action, read from the page's details and the viewer.
    struct Context: Equatable {
        var availability: SeerrAvailabilityStatus = .unknown
        var mediaType: SeerrMediaType = .movie
        /// The title was matched to an item in the Jellyfin library.
        var isInLibrary = false
        var canRequest = false
        var canManageBlocklist = false
        var canRequestMoreSeasons = false
        var downloadProgress: SeerrDownloadProgress?
    }

    var title: String
    var symbol: String
    var motion: SeerrStatusMotion = .still
    var identifier = "seerr.detail.status"
    var tap: Tap

    /// nil when the page opens the title in Lagoon instead.
    static func resolve(_ context: Context) -> SeerrPrimaryAction? {
        switch context.availability {
        case .available:
            context.isInLibrary ? nil : SeerrPrimaryAction(
                title: "Available in Jellyfin",
                symbol: "checkmark.circle.fill",
                tap: .explain("Seerr reports this title as available, but Lagoon couldn't match it to an item in your current Jellyfin library.")
            )
        case .pending, .processing:
            inProgress(context)
        case .partiallyAvailable:
            if context.isInLibrary {
                nil
            } else if context.canRequestMoreSeasons {
                requestMoreSeasons
            } else {
                partiallyAvailable
            }
        case .blocklisted:
            blocklisted(context)
        case .unknown, .deleted:
            request(context)
        }
    }

    static let requestMoreSeasons = SeerrPrimaryAction(
        title: String(localized: "Request More Seasons"),
        symbol: "plus",
        identifier: "seerr.detail.request",
        tap: .chooseSeasons
    )

    static let partiallyAvailable = SeerrPrimaryAction(
        title: SeerrAvailabilityStatus.partiallyAvailable.title,
        symbol: "circle.lefthalf.filled",
        tap: .explain("Some of this title is already available in your Jellyfin library.")
    )

    /// A request waiting for approval or being added to the library, with
    /// the download's progress when the server knows it.
    private static func inProgress(_ context: Context) -> SeerrPrimaryAction {
        if context.availability == .processing, let progress = context.downloadProgress {
            return SeerrPrimaryAction(
                title: progress.isImporting ? String(localized: "Importing") : progress.percentText,
                symbol: progress.isImporting ? "square.and.arrow.down" : "arrow.down.circle",
                motion: .bounce,
                tap: .explain(progress.downloadCount > 1
                    ? "\(progress.summary). \(progress.downloadCount) downloads."
                    : progress.summary)
            )
        }
        let isPending = context.availability == .pending
        return SeerrPrimaryAction(
            title: context.availability.title,
            symbol: isPending ? "clock" : "arrow.triangle.2.circlepath",
            motion: isPending ? .pulse : .rotate,
            tap: .explain(isPending
                ? "This request is waiting for approval."
                : "This title has been approved and is being added to your library.")
        )
    }

    /// Jellyseerr drops the media row with the block, so the reload after
    /// an unblock shows the ordinary request.
    private static func blocklisted(_ context: Context) -> SeerrPrimaryAction {
        guard context.canManageBlocklist else {
            return SeerrPrimaryAction(
                title: context.availability.title,
                symbol: "hand.raised",
                tap: .explain("The server administrator has blocked this title, so it cannot be requested.")
            )
        }
        return SeerrPrimaryAction(
            title: String(localized: "Unblock"),
            symbol: "hand.raised.slash",
            identifier: "seerr.detail.unblock",
            tap: .confirmUnblock
        )
    }

    private static func request(_ context: Context) -> SeerrPrimaryAction {
        guard context.canRequest else {
            return SeerrPrimaryAction(
                title: "Request Unavailable",
                symbol: "lock",
                tap: .explain("Your Seerr account doesn't have permission to request this title.")
            )
        }
        return context.mediaType == .movie
            ? SeerrPrimaryAction(
                title: String(localized: "Request Movie"),
                symbol: "plus",
                identifier: "seerr.detail.request",
                tap: .confirmMovieRequest
            )
            : SeerrPrimaryAction(
                title: String(localized: "Choose Seasons"),
                symbol: "plus",
                identifier: "seerr.detail.request",
                tap: .chooseSeasons
            )
    }
}
