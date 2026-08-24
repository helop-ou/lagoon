import Foundation

/// Where a subtitle result came from. Jellyfin's routes need the server's
/// permission and persist the file for every client; OpenSubtitles is fetched
/// straight into the player and never touches the library (HEL-92).
nonisolated enum SubtitleSourceKind: String, Sendable, Equatable {
    case jellyfin
    case openSubtitles

    var displayName: String {
        switch self {
        case .jellyfin: "Jellyfin"
        case .openSubtitles: "OpenSubtitles"
        }
    }
}

nonisolated enum SubtitleSourcePreference: String, CaseIterable, Sendable {
    case automatic
    case jellyfin
    case openSubtitles

    var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .jellyfin: "Jellyfin Server"
        case .openSubtitles: "OpenSubtitles"
        }
    }
}

/// Why no source could be used, which is a different answer from a search
/// that ran and found nothing.
nonisolated enum SubtitleSourceUnavailable: Error, Equatable {
    case jellyfinNotPermitted
    case providerNotConfigured
}

nonisolated enum SubtitleSourcePolicy {
    /// Jellyfin wins when it is available: it persists the sidecar for every
    /// client and every other viewer, converts the file server-side, uses
    /// whatever providers the administrator configured, and costs the viewer
    /// none of their personal provider quota. The direct provider exists for
    /// the accounts Jellyfin will not serve — the common case on a shared
    /// server — and for anyone who would rather not write to a shared library.
    static func resolve(
        preference: SubtitleSourcePreference,
        jellyfinAllowed: Bool,
        providerConfigured: Bool
    ) -> Result<SubtitleSourceKind, SubtitleSourceUnavailable> {
        switch preference {
        case .jellyfin:
            return jellyfinAllowed ? .success(.jellyfin) : .failure(.jellyfinNotPermitted)
        case .openSubtitles:
            return providerConfigured ? .success(.openSubtitles) : .failure(.providerNotConfigured)
        case .automatic:
            if jellyfinAllowed { return .success(.jellyfin) }
            if providerConfigured { return .success(.openSubtitles) }
            return .failure(.jellyfinNotPermitted)
        }
    }
}

/// One provider result, whichever source produced it. The player UI binds to
/// this rather than to Jellyfin's DTO so neither source is privileged.
nonisolated struct SubtitleCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let source: SubtitleSourceKind
    let name: String?
    let language: String?
    let providerName: String?
    let format: String?
    let downloadCount: Int?
    let isHashMatch: Bool
    let isHearingImpaired: Bool
    let isForced: Bool
    let isMachineTranslated: Bool
    let isAITranslated: Bool
    /// The identifier the owning source needs to fetch this result.
    let jellyfinID: String?
    let providerFileID: Int?

    init(_ info: RemoteSubtitleInfo) {
        id = "jellyfin:" + info.id
        source = .jellyfin
        name = info.name
        language = info.threeLetterISOLanguageName
        providerName = info.providerName
        format = info.format
        downloadCount = info.downloadCount
        isHashMatch = info.isHashMatch == true
        isHearingImpaired = info.hearingImpaired == true
        isForced = info.isForced == true
        isMachineTranslated = info.machineTranslated == true
        isAITranslated = info.aiTranslated == true
        jellyfinID = info.id
        providerFileID = nil
    }

    init(_ result: OpenSubtitlesResult) {
        id = "opensubtitles:\(result.fileID)"
        source = .openSubtitles
        name = result.releaseName
        language = result.language
        providerName = result.uploader.map { "OpenSubtitles · \($0)" } ?? "OpenSubtitles"
        // The provider converts on download, so this is always what arrives.
        format = "srt"
        downloadCount = result.downloadCount
        isHashMatch = result.isHashMatch
        isHearingImpaired = result.isHearingImpaired
        isForced = result.isForced
        isMachineTranslated = result.isMachineTranslated
        isAITranslated = result.isAITranslated
        jellyfinID = nil
        providerFileID = result.fileID
    }

    /// An exact-release match beats a title match, and a human translation
    /// beats a machine one. Everything else keeps the provider's own order.
    static func ranked(_ candidates: [SubtitleCandidate]) -> [SubtitleCandidate] {
        candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.isHashMatch != rhs.element.isHashMatch {
                return lhs.element.isHashMatch
            }
            let lhsSynthetic = lhs.element.isMachineTranslated || lhs.element.isAITranslated
            let rhsSynthetic = rhs.element.isMachineTranslated || rhs.element.isAITranslated
            if lhsSynthetic != rhsSynthetic { return rhsSynthetic }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}

/// What a search knows about the item being played. Jellyfin's own routes
/// need none of it — the server already knows the item — but a direct
/// provider search has to be told what it is looking at.
nonisolated struct SubtitleSearchContext: Sendable, Equatable {
    var title: String?
    var imdbID: String?
    var tmdbID: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var isEpisode: Bool = false
    /// Used for the release-exact moviehash match, which is the only way the
    /// provider can tell this cut of the film from another.
    var streamURL: URL?
    var fileSize: Int64?

    static func from(
        media: MediaItem,
        streamURL: URL?,
        fileSize: Int64?
    ) -> SubtitleSearchContext {
        let isEpisode = media.type == .episode
        return SubtitleSearchContext(
            title: isEpisode ? (media.seriesName ?? media.name) : media.name,
            imdbID: media.providerIds?["Imdb"] ?? media.providerIds?["IMDB"],
            tmdbID: media.providerIds?["Tmdb"] ?? media.providerIds?["TMDB"],
            seasonNumber: isEpisode ? media.parentIndexNumber : nil,
            episodeNumber: isEpisode ? media.indexNumber : nil,
            isEpisode: isEpisode,
            streamURL: streamURL,
            fileSize: fileSize
        )
    }
}

/// Sidecars fetched straight from a provider, kept on disk so re-watching an
/// episode does not spend another download. The provider allowance is small
/// — five a day anonymously, twenty with a free account — which makes this a
/// correctness concern rather than an optimisation.
nonisolated enum SubtitleFileStore {
    static func directory() -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let directory = caches
            .appendingPathComponent("Lagoon", isDirectory: true)
            .appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    static func fileURL(itemID: String, candidateID: String) -> URL? {
        guard let directory = directory() else { return nil }
        let safe = (itemID + "-" + candidateID)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return directory.appendingPathComponent(safe + ".srt", isDirectory: false)
    }

    static func cached(itemID: String, candidateID: String) -> (url: URL, data: Data)? {
        guard let url = fileURL(itemID: itemID, candidateID: candidateID),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }
        return (url, data)
    }

    @discardableResult
    static func store(_ data: Data, itemID: String, candidateID: String) -> URL? {
        guard let url = fileURL(itemID: itemID, candidateID: candidateID) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
            return url
        } catch {
            return nil
        }
    }
}

/// Where the provider API key comes from. A build-time value is the normal
/// path; the defaults override exists so a key can be pasted in Settings
/// without rebuilding, which is what makes the feature usable to anyone who
/// registers their own consumer key.
nonisolated enum OpenSubtitlesConfiguration {
    static let defaultsKey = "subtitles.openSubtitlesAPIKey"
    static let infoPlistKey = "LagoonOpenSubtitlesAPIKey"

    static func apiKey(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) -> String? {
        if let override = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        guard let value = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
