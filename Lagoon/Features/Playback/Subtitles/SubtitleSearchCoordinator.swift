import Foundation
import LagoonEngine
import Observation

nonisolated enum SubtitleSearchPhase: Equatable {
    case idle
    case searching
    case noProvider
    /// The account lacks Jellyfin's subtitle-management permission, so every
    /// remote endpoint answers 403. A server setting, so retrying cannot fix it.
    case notPermitted
    case noResults
    case failed(String)
    case downloading(String)
    case downloadFailed(String)
    case downloaded

    var isBusy: Bool {
        switch self {
        case .searching, .downloading:
            true
        default:
            false
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { true } else { false }
    }
}

/// Bounded retry for the transient `SubtitleDownloadError`s. These calls
/// reach third-party providers through the server and are the flakiest.
nonisolated enum SubtitleRetryPolicy {
    static let downloadAttempts = 3
    /// A search degrades gracefully, so it gets only one quick retry.
    static let searchAttempts = 2

    static func delayBeforeRetry(after attempt: Int) -> Duration {
        attempt <= 1 ? .milliseconds(500) : .seconds(2)
    }

    static func shouldRetry(
        _ error: SubtitleDownloadError,
        afterAttempt attempt: Int,
        maxAttempts: Int = downloadAttempts
    ) -> Bool {
        attempt < maxAttempts && error.isRetryable
    }
}

nonisolated struct SubtitleStreamSignature: Hashable {
    let index: Int?
    let deliveryURL: String?

    init(_ stream: MediaStream) {
        index = stream.index
        deliveryURL = stream.deliveryUrl
    }
}

/// Jellyfin refreshes the library after accepting a remote-subtitle
/// download. Poll PlaybackInfo until the new sidecar appears, rather than
/// reading the first stale response as a failure.
@MainActor
struct DownloadedSubtitlePoller {
    nonisolated static let defaultRefreshDelays: [Duration] = [
        .zero,
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
    ]

    let refreshDelays: [Duration]

    init(refreshDelays: [Duration] = Self.defaultRefreshDelays) {
        self.refreshDelays = refreshDelays
    }

    func waitForStream(
        mediaSourceID: String,
        existingSignatures: Set<SubtitleStreamSignature>,
        requestedLanguage: String?,
        fetchPlaybackInfo: () async throws -> PlaybackInfoResponse
    ) async throws -> MediaStream {
        var receivedPlaybackInfo = false
        var lastError: Error?

        for delay in refreshDelays {
            try Task.checkCancellation()
            try await Task.sleep(for: delay)
            do {
                let playbackInfo = try await fetchPlaybackInfo()
                receivedPlaybackInfo = true
                if let stream = Self.newStream(
                    in: playbackInfo,
                    mediaSourceID: mediaSourceID,
                    existingSignatures: existingSignatures,
                    requestedLanguage: requestedLanguage
                ) {
                    return stream
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if !receivedPlaybackInfo, let lastError { throw lastError }
        throw SubtitleDownloadError.notAvailable
    }

    static func newStream(
        in playbackInfo: PlaybackInfoResponse,
        mediaSourceID: String,
        existingSignatures: Set<SubtitleStreamSignature>,
        requestedLanguage: String?
    ) -> MediaStream? {
        let exactSource = playbackInfo.mediaSources.first { $0.id == mediaSourceID }
        guard let source = exactSource ?? (playbackInfo.mediaSources.count == 1 ? playbackInfo.mediaSources.first : nil) else {
            return nil
        }
        let candidates = (source.mediaStreams ?? []).filter {
            $0.isSubtitle
                && $0.isExternal == true
                && $0.deliveryUrl != nil
                && !existingSignatures.contains(SubtitleStreamSignature($0))
        }
        let normalizedLanguage = requestedLanguage.flatMap(SubtitlePreferencesStore.normalizedLanguage)
        return candidates.first {
            normalizedLanguage == nil
                || SubtitlePreferencesStore.normalizedLanguage($0.language ?? "") == normalizedLanguage
        } ?? candidates.first
    }
}

/// Host-side service for the player's subtitle tab. Only the final
/// authenticated sidecar URL crosses into the engine.
@MainActor
@Observable
final class SubtitleSearchCoordinator {
    private(set) var phase: SubtitleSearchPhase = .idle
    private(set) var results: [SubtitleCandidate] = []
    /// The Subtitles tab is either choosing a track or browsing results, never
    /// both.
    private(set) var isBrowsingResults = false
    private(set) var preferredLanguages: [String] = []
    private(set) var languageChoices: [String] = []
    private(set) var selectedLanguage: String?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private weak var engine: (any PlayerEngine)?
    @ObservationIgnored private var itemID = ""
    @ObservationIgnored private var mediaSourceID = ""
    @ObservationIgnored private var existingSignatures: Set<SubtitleStreamSignature> = []
    @ObservationIgnored private var onTrackAdded: ((MediaStream) -> Void)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var downloadGeneration = 0
    @ObservationIgnored private let downloadedSubtitlePoller: DownloadedSubtitlePoller

    init() {
        downloadedSubtitlePoller = DownloadedSubtitlePoller()
    }

    init(downloadedSubtitlePoller: DownloadedSubtitlePoller) {
        self.downloadedSubtitlePoller = downloadedSubtitlePoller
    }

    var selectedLanguageTitle: String {
        selectedLanguage.map(SubtitlePreferencesStore.displayName)
            ?? String(localized: "Preferred Languages")
    }

    func configure(
        client: JellyfinClient,
        engine: any PlayerEngine,
        itemID: String,
        mediaSourceID: String,
        streams: [MediaStream],
        preferredLanguages: [String],
        missingMode: MissingSubtitleMode,
        hasSuitableLocalTrack: Bool,
        onTrackAdded: @escaping (MediaStream) -> Void
    ) {
        cancel()
        self.client = client
        self.engine = engine
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.preferredLanguages = preferredLanguages
        languageChoices = Self.makeLanguageChoices(preferredLanguages: preferredLanguages)
        self.onTrackAdded = onTrackAdded
        selectedLanguage = nil
        results = []
        isBrowsingResults = false
        phase = .idle
        existingSignatures = Set(streams.filter { $0.isSubtitle }.map(SubtitleStreamSignature.init))
        if missingMode == .automaticSearch, !hasSuitableLocalTrack {
            startSearch()
        }
    }

    /// Changing the language while browsing re-runs the search.
    func selectLanguage(_ language: String?) {
        selectedLanguage = language
        if isBrowsingResults { startSearch() }
    }

    func cycleLanguage() {
        let options: [String?] = [nil] + languageChoices.map(Optional.some)
        let next = (options.firstIndex(where: { $0 == selectedLanguage }).map { $0 + 1 } ?? 0) % options.count
        selectedLanguage = options[next]
        if isBrowsingResults { startSearch() }
    }

    func startSearch() {
        guard !phase.isDownloading else { return }
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        isBrowsingResults = true
        phase = .searching
        results = []
        let requested = selectedLanguage.map { [$0] } ?? preferredLanguages
        let languages = requested.isEmpty ? SubtitlePreferencesStore.systemCaptionLanguages : requested
        searchTask = Task { [weak self] in
            guard let self, let client = self.client else { return }
            guard await client.canManageSubtitles() else {
                guard generation == self.searchGeneration else { return }
                self.phase = .notPermitted
                return
            }
            await self.searchJellyfin(languages: languages, generation: generation)
        }
    }

    /// Leaves the results browser for the track list. Abandons a running search
    /// but not a download: the status line reports its outcome.
    func closeResults() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        results = []
        isBrowsingResults = false
        switch phase {
        case .downloading, .downloaded, .downloadFailed:
            break
        default:
            phase = .idle
        }
    }

    private func searchJellyfin(languages: [String], generation: Int) async {
        guard let client else { return }
        let itemID = itemID

        // Search languages concurrently so one slow provider does not gate the rest.
        let outcomes = await withTaskGroup(
            of: (Int, Result<[RemoteSubtitleInfo], Error>).self
        ) { group in
            for (offset, language) in languages.enumerated() {
                group.addTask { @MainActor in
                    let code = JellyfinSubtitleLanguageCode.threeLetter(for: language)
                    do {
                        let matches = try await Self.retrying(
                            maxAttempts: SubtitleRetryPolicy.searchAttempts
                        ) {
                            try await client.searchRemoteSubtitles(itemId: itemID, language: code)
                        }
                        return (offset, .success(matches))
                    } catch {
                        return (offset, .failure(error))
                    }
                }
            }
            var collected: [(Int, Result<[RemoteSubtitleInfo], Error>)] = []
            for await outcome in group { collected.append(outcome) }
            // Keep request order: provider ranking is meaningful.
            return collected.sorted { $0.0 < $1.0 }
        }
        guard generation == searchGeneration else { return }
        if Task.isCancelled {
            phase = .idle
            return
        }

        guard let resolved = Self.resolveSearch(outcomes.map(\.1)) else {
            phase = .idle
            return
        }
        results = resolved.results
        phase = resolved.phase
    }

    /// What a finished search shows: the merged results, or why there are
    /// none. Nil when a language search was cancelled.
    static func resolveSearch(
        _ outcomes: [Result<[RemoteSubtitleInfo], Error>]
    ) -> (results: [SubtitleCandidate], phase: SubtitleSearchPhase)? {
        var merged: [SubtitleCandidate] = []
        var seen: Set<String> = []
        var successfulSearches = 0
        var itemMissing = false
        var failures: [SubtitleDownloadError] = []
        for result in outcomes {
            switch result {
            case .success(let matches):
                successfulSearches += 1
                for match in matches where seen.insert(match.id).inserted {
                    merged.append(SubtitleCandidate(match))
                }
            case .failure(let error) where error is CancellationError:
                return nil
            case .failure(let error):
                let classified = SubtitleDownloadError.classify(error)
                // Jellyfin answers 404 for a missing item, not a missing provider.
                if classified.httpStatus == 404 {
                    itemMissing = true
                } else {
                    failures.append(classified)
                }
            }
        }

        if !merged.isEmpty { return (merged, .idle) }
        if let failure = mostActionable(failures) {
            return ([], failure == .notPermitted ? .notPermitted : .failed(failure.localizedDescription))
        }
        if itemMissing, successfulSearches == 0 { return ([], .noProvider) }
        return ([], .noResults)
    }

    /// A permission or session problem explains every other failure, so it wins.
    static func mostActionable(_ failures: [SubtitleDownloadError]) -> SubtitleDownloadError? {
        failures.first { $0 == .notPermitted }
            ?? failures.first { $0 == .sessionExpired }
            ?? failures.first
    }

    /// Retries only transient errors, rethrowing the classified error.
    static func retrying<T>(
        maxAttempts: Int = SubtitleRetryPolicy.downloadAttempts,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let classified = SubtitleDownloadError.classify(error)
                guard SubtitleRetryPolicy.shouldRetry(
                    classified,
                    afterAttempt: attempt,
                    maxAttempts: maxAttempts
                ) else { throw classified }
                try await Task.sleep(for: SubtitleRetryPolicy.delayBeforeRetry(after: attempt))
                attempt += 1
            }
        }
    }

    func startDownload(_ candidate: SubtitleCandidate) {
        guard let engine, !phase.isBusy else { return }
        let selectionRevision = engine.subtitleSelectionRevision
        downloadTask?.cancel()
        downloadGeneration &+= 1
        let generation = downloadGeneration
        phase = .downloading(candidate.id)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            await self.downloadFromJellyfin(candidate, generation: generation, selectionRevision: selectionRevision)
        }
    }

    private func downloadFromJellyfin(_ candidate: SubtitleCandidate, generation: Int, selectionRevision: Int) async {
        guard let client, let engine else { return }
        var directFailure: SubtitleDownloadError?
        do {
            guard await client.canManageSubtitles() else {
                throw SubtitleDownloadError.notPermitted
            }
            try Task.checkCancellation()
            guard generation == downloadGeneration else { return }

            let requestedLanguage = SubtitlePreferencesStore.normalizedLanguage(
                candidate.language ?? selectedLanguage ?? ""
            )
            do {
                try await attachDirectDownload(
                    candidate,
                    generation: generation,
                    selectionRevision: selectionRevision,
                    client: client,
                    engine: engine
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                directFailure = SubtitleDownloadError.classify(error)
            }

            // Jellyfin's save path is a fallback for formats Lagoon cannot parse and
            // for servers without the direct endpoint. It fetches from the provider
            // again, so skip it for failures a retry cannot fix (403, expired session)
            // to save the provider's download quota.
            guard let directFailure,
                  directFailure == .unsupportedFile || directFailure.httpStatus == 404 else {
                throw directFailure ?? .providerUnavailable
            }

            try await attachViaServerSave(
                candidate,
                requestedLanguage: requestedLanguage,
                generation: generation,
                selectionRevision: selectionRevision,
                client: client,
                engine: engine
            )
        } catch is CancellationError {
            if generation == downloadGeneration { phase = .idle }
        } catch {
            guard generation == downloadGeneration else { return }
            var failure = SubtitleDownloadError.classify(error)
            // Provider 404 and nothing attached: the result really is gone, the one
            // case the quota/removal wording fits.
            if failure == .notAvailable, directFailure?.httpStatus == 404 {
                failure = .providerUnavailable
            }
            phase = failure == .notPermitted
                ? .notPermitted
                : .downloadFailed(failure.localizedDescription)
        }
    }

    /// Fetches once, validates the bytes, then uploads the same bytes to
    /// Jellyfin. This bypasses the 10.11.x endpoint that can return 204 after a
    /// failed save. Returns without attaching once the download is stale.
    private func attachDirectDownload(
        _ candidate: SubtitleCandidate,
        generation: Int,
        selectionRevision: Int,
        client: JellyfinClient,
        engine: any PlayerEngine
    ) async throws {
        let file = try await Self.retrying {
            try await client.remoteSubtitleFile(subtitleId: candidate.providerID)
        }
        try await ExternalSubtitleLoader.validate(file.data, language: candidate.language)
        guard try isStillCurrent(generation: generation, selectionRevision: selectionRevision, engine: engine) else {
            return
        }
        // The controller maps the selected track through its own stream list to
        // carry the choice into the next episode. The server has no stream for
        // this file until the upload lands, so add the candidate's description.
        attach(ExternalSubtitleTrack(
            url: file.url,
            preloadedData: file.data,
            title: candidate.name,
            language: candidate.language,
            select: true,
            isForced: candidate.isForced,
            isHearingImpaired: candidate.isHearingImpaired,
            isDownloaded: true
        ), described: .externalSubtitle(describing: candidate), to: engine)

        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            try? await client.uploadSubtitle(
                itemId: itemID,
                data: file.data,
                language: candidate.language,
                format: candidate.format ?? "srt",
                isForced: candidate.isForced,
                isHearingImpaired: candidate.isHearingImpaired
            )
        }
    }

    /// Has Jellyfin save the subtitle, waits for the new sidecar in
    /// PlaybackInfo and attaches it. Returns without attaching once the
    /// download is stale.
    private func attachViaServerSave(
        _ candidate: SubtitleCandidate,
        requestedLanguage: String?,
        generation: Int,
        selectionRevision: Int,
        client: JellyfinClient,
        engine: any PlayerEngine
    ) async throws {
        try await Self.retrying {
            try await client.downloadRemoteSubtitle(itemId: itemID, subtitleId: candidate.providerID)
        }
        let stream = try await downloadedSubtitlePoller.waitForStream(
            mediaSourceID: mediaSourceID,
            existingSignatures: existingSignatures,
            requestedLanguage: requestedLanguage
        ) {
            try await client.playbackInfo(itemId: self.itemID)
        }
        guard let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else {
            throw SubtitleDownloadError.notAvailable
        }
        guard try isStillCurrent(generation: generation, selectionRevision: selectionRevision, engine: engine) else {
            return
        }
        existingSignatures.insert(SubtitleStreamSignature(stream))
        attach(ExternalSubtitleTrack(
            url: url,
            title: stream.displayTitle ?? candidate.name,
            language: stream.language ?? candidate.language,
            select: true,
            isForced: stream.isForced == true || candidate.isForced,
            isHearingImpaired: stream.isHearingImpaired == true || candidate.isHearingImpaired,
            isDownloaded: true
        ), described: stream, to: engine)
    }

    /// Whether a finished download may still attach. Cancellation throws; a
    /// newer download drops it silently; a subtitle choice the viewer made
    /// meanwhile wins and leaves the status idle.
    private func isStillCurrent(generation: Int, selectionRevision: Int, engine: any PlayerEngine) throws -> Bool {
        try Task.checkCancellation()
        guard generation == downloadGeneration else { return false }
        guard engine.subtitleSelectionRevision == selectionRevision else {
            phase = .idle
            return false
        }
        return true
    }

    /// Selects a downloaded track in the player and reports it, ending the
    /// download. `stream` is how the controller sees the track afterwards.
    private func attach(
        _ track: ExternalSubtitleTrack,
        described stream: MediaStream,
        to engine: any PlayerEngine
    ) {
        engine.addExternalSubtitle(track)
        onTrackAdded?(stream)
        phase = .downloaded
        finishBrowsing()
    }

    /// Returns to the track list without touching `phase`, so the "Downloaded
    /// and selected" line survives.
    private func finishBrowsing() {
        results = []
        isBrowsingResults = false
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadGeneration &+= 1
        if phase.isDownloading { phase = .idle }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        cancelDownload()
        persistenceTask?.cancel()
        persistenceTask = nil
        searchGeneration &+= 1
    }

    /// Drops the session-sized references at dismissal. Cancellation alone
    /// keeps the client and completion closure alive until the controller dies.
    func detach() {
        cancel()
        client = nil
        engine = nil
        onTrackAdded = nil
        itemID = ""
        mediaSourceID = ""
        existingSignatures.removeAll()
        results.removeAll()
        isBrowsingResults = false
        phase = .idle
    }

    #if DEBUG
    /// Fixture for the Debug component gallery.
    static func previewingResults(_ results: [SubtitleCandidate]) -> SubtitleSearchCoordinator {
        let coordinator = SubtitleSearchCoordinator()
        coordinator.results = results
        coordinator.isBrowsingResults = true
        coordinator.languageChoices = ["eng", "est"]
        coordinator.phase = .idle
        return coordinator
    }
    #endif

    static func makeLanguageChoices(preferredLanguages: [String]) -> [String] {
        // Keep this list compact during playback. Settings has the full catalogue.
        SubtitlePreferencesStore.deduplicated(
            preferredLanguages + SubtitlePreferencesStore.commonLanguageChoices
        )
    }
}

/// Jellyfin's subtitle route uses ISO 639-2 codes. Apple's preference APIs
/// return BCP-47 or two-letter codes.
nonisolated enum JellyfinSubtitleLanguageCode {
    /// ISO 639-1 → ISO 639-2/T, from the Library of Congress table. Three-letter-
    /// only languages pass through unchanged.
    private static let common: [String: String] = [
        "aa": "aar", "ab": "abk", "af": "afr", "ak": "aka", "sq": "sqi", "am": "amh",
        "ar": "ara", "an": "arg", "hy": "hye", "as": "asm", "av": "ava", "ae": "ave",
        "ay": "aym", "az": "aze", "ba": "bak", "bm": "bam", "eu": "eus", "be": "bel",
        "bn": "ben", "bi": "bis", "bs": "bos", "br": "bre", "bg": "bul", "my": "mya",
        "ca": "cat", "ch": "cha", "ce": "che", "zh": "zho", "cu": "chu", "cv": "chv",
        "kw": "cor", "co": "cos", "cr": "cre", "cs": "ces", "da": "dan", "dv": "div",
        "nl": "nld", "dz": "dzo", "en": "eng", "eo": "epo", "et": "est", "ee": "ewe",
        "fo": "fao", "fj": "fij", "fi": "fin", "fr": "fra", "fy": "fry", "ff": "ful",
        "ka": "kat", "de": "deu", "gd": "gla", "ga": "gle", "gl": "glg", "gv": "glv",
        "el": "ell", "gn": "grn", "gu": "guj", "ht": "hat", "ha": "hau", "he": "heb",
        "hz": "her", "hi": "hin", "ho": "hmo", "hr": "hrv", "hu": "hun", "ig": "ibo",
        "is": "isl", "io": "ido", "ii": "iii", "iu": "iku", "ie": "ile", "ia": "ina",
        "id": "ind", "ik": "ipk", "it": "ita", "jv": "jav", "ja": "jpn", "kl": "kal",
        "kn": "kan", "ks": "kas", "kr": "kau", "kk": "kaz", "km": "khm", "ki": "kik",
        "rw": "kin", "ky": "kir", "kv": "kom", "kg": "kon", "ko": "kor", "kj": "kua",
        "ku": "kur", "lo": "lao", "la": "lat", "lv": "lav", "li": "lim", "ln": "lin",
        "lt": "lit", "lb": "ltz", "lu": "lub", "lg": "lug", "mk": "mkd", "mh": "mah",
        "ml": "mal", "mi": "mri", "mr": "mar", "ms": "msa", "mg": "mlg", "mt": "mlt",
        "mn": "mon", "na": "nau", "nv": "nav", "nr": "nbl", "nd": "nde", "ng": "ndo",
        "ne": "nep", "nn": "nno", "nb": "nob", "no": "nor", "ny": "nya", "oc": "oci",
        "oj": "oji", "or": "ori", "om": "orm", "os": "oss", "pa": "pan", "fa": "fas",
        "pi": "pli", "pl": "pol", "pt": "por", "ps": "pus", "qu": "que", "rm": "roh",
        "ro": "ron", "rn": "run", "ru": "rus", "sg": "sag", "sa": "san", "si": "sin",
        "sk": "slk", "sl": "slv", "se": "sme", "sm": "smo", "sn": "sna", "sd": "snd",
        "so": "som", "st": "sot", "es": "spa", "sc": "srd", "sr": "srp", "ss": "ssw",
        "su": "sun", "sw": "swa", "sv": "swe", "ty": "tah", "ta": "tam", "tt": "tat",
        "te": "tel", "tg": "tgk", "tl": "tgl", "th": "tha", "bo": "bod", "ti": "tir",
        "to": "ton", "tn": "tsn", "ts": "tso", "tk": "tuk", "tr": "tur", "tw": "twi",
        "ug": "uig", "uk": "ukr", "ur": "urd", "uz": "uzb", "ve": "ven", "vi": "vie",
        "vo": "vol", "cy": "cym", "wa": "wln", "wo": "wol", "xh": "xho", "yi": "yid",
        "yo": "yor", "za": "zha", "zu": "zul",
    ]

    private static let reverse: [String: String] = {
        var result = Dictionary(uniqueKeysWithValues: common.map { ($0.value, $0.key) })
        // ISO 639-2/B aliases still appear in older libraries.
        result.merge([
            "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "chi": "zh",
            "cze": "cs", "dut": "nl", "fre": "fr", "geo": "ka", "ger": "de",
            "gre": "el", "ice": "is", "mac": "mk", "mao": "mi", "may": "ms",
            "per": "fa", "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
        ], uniquingKeysWith: { current, _ in current })
        return result
    }()

    static func twoLetter(for identifier: String) -> String? {
        let base = identifier.lowercased()
        if base.count == 2 { return base }
        return reverse[base]
    }

    static func threeLetter(for identifier: String) -> String {
        let normalized = SubtitlePreferencesStore.normalizedLanguage(identifier) ?? identifier.lowercased()
        if normalized.count == 3 { return normalized }
        return common[normalized] ?? normalized
    }
}
