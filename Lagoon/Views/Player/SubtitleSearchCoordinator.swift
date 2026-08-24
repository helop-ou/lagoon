import Foundation
import Observation

nonisolated enum SubtitleSearchPhase: Equatable {
    case idle
    case searching
    case noProvider
    /// The account lacks Jellyfin's subtitle-management permission, so every
    /// remote endpoint answers 403. Distinguished from a failure because it
    /// is a server setting, not something retrying can fix.
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

/// Why a subtitle search or download failed, kept specific enough to be
/// actionable. Collapsing every failure into "the provider could not supply
/// this file" sent viewers after an imagined download quota when the real
/// cause was a 403, an expired session or a timeout (HEL-91).
nonisolated enum SubtitleDownloadError: LocalizedError, Equatable {
    case notAvailable
    case providerUnavailable
    case unsupportedFile
    case notPermitted
    case sessionExpired
    case rateLimited
    case timedOut
    case offline
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Jellyfin did not attach this subtitle to the item. Try another result."
        case .providerUnavailable:
            "The subtitle provider could not supply this file. It may have been removed or the provider's download limit may have been reached. Try another result."
        case .unsupportedFile:
            "The subtitle provider returned a file Lagoon couldn't read. Try another result."
        case .notPermitted:
            "This Jellyfin account isn't allowed to manage subtitles. Ask the server administrator to enable Subtitle Management for it."
        case .sessionExpired:
            "This Jellyfin session has expired. Sign in again to download subtitles."
        case .rateLimited:
            "The subtitle provider is rate-limiting requests right now. Try again in a few minutes."
        case .timedOut:
            "The subtitle provider didn't respond in time. Try again."
        case .offline:
            "Lagoon couldn't reach the Jellyfin server."
        case .server(let status):
            "Jellyfin returned an error (\(status))."
        }
    }

    /// Maps transport failures onto the cause a viewer can act on. Anything
    /// unrecognised stays an honest server error rather than being asserted
    /// to be a provider problem.
    static func classify(_ error: Error) -> SubtitleDownloadError {
        if let known = error as? SubtitleDownloadError { return known }
        if let jellyfin = error as? JellyfinError {
            switch jellyfin {
            case .unauthorized:
                return .sessionExpired
            case .server(let status):
                switch status {
                case 401: return .sessionExpired
                case 403: return .notPermitted
                case 429: return .rateLimited
                case 500...599: return .providerUnavailable
                default: return .server(status)
                }
            default:
                return .server(0)
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .offline
            default:
                return .server(url.errorCode)
            }
        }
        return .server(0)
    }

    /// Only failures that fail *fast* and plausibly succeed on a second try.
    ///
    /// A timeout is deliberately excluded: the provider budget is already
    /// 90 s, and retrying it would leave a viewer watching a spinner for
    /// minutes to reach the same answer. Rate limiting is excluded because
    /// retrying inside seconds cannot clear a limit measured in minutes and
    /// would spend more of the provider's quota getting there — the message
    /// tells the viewer to wait instead.
    var isRetryable: Bool {
        switch self {
        case .offline, .providerUnavailable:
            true
        case .timedOut, .rateLimited, .notPermitted, .sessionExpired,
             .unsupportedFile, .notAvailable, .server:
            false
        }
    }
}

/// Bounded retry for the transient half of `SubtitleDownloadError`. Remote
/// subtitle calls reach third-party providers through the server, which makes
/// them the flakiest requests Lagoon issues and the ones most worth retrying.
nonisolated enum SubtitleRetryPolicy {
    /// A download failure costs the viewer their action and a unit of the
    /// provider's quota, so it is worth persisting at.
    static let downloadAttempts = 3
    /// A search already degrades gracefully — other languages still return
    /// results, and the Search button is right there — so it buys one quick
    /// retry rather than making every search wait on the worst provider.
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

/// Provider searches fan out from the server to third-party services, so they
/// need far longer than an ordinary library call. The client-wide 30 s budget
/// timed these out routinely.
nonisolated enum SubtitleRequestTimeout {
    static let provider: TimeInterval = 90
}

nonisolated struct SubtitleStreamSignature: Hashable {
    let index: Int?
    let deliveryURL: String?

    init(_ stream: MediaStream) {
        index = stream.index
        deliveryURL = stream.deliveryUrl
    }
}

/// Jellyfin queues its library refresh after accepting a remote-subtitle
/// download. Poll PlaybackInfo until that refresh exposes the new sidecar
/// rather than interpreting the first stale response as an unplayable file.
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
            $0.type == "Subtitle"
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

/// Host-side service for the player's subtitle tab. Search/download stays
/// outside PlayerEngine; only the final authenticated sidecar URL crosses
/// the engine boundary (HEL-49).
@MainActor
@Observable
final class SubtitleSearchCoordinator {
    private(set) var phase: SubtitleSearchPhase = .idle
    private(set) var results: [RemoteSubtitleInfo] = []
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
        phase = .idle
        existingSignatures = Set(streams.filter { $0.type == "Subtitle" }.map(SubtitleStreamSignature.init))
        if missingMode == .automaticSearch, !hasSuitableLocalTrack {
            startSearch()
        }
    }

    func selectLanguage(_ language: String?) {
        selectedLanguage = language
    }

    func cycleLanguage() {
        let options: [String?] = [nil] + languageChoices.map(Optional.some)
        let next = (options.firstIndex(where: { $0 == selectedLanguage }).map { $0 + 1 } ?? 0) % options.count
        selectedLanguage = options[next]
    }

    func startSearch() {
        guard let client, !phase.isDownloading else { return }
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        phase = .searching
        results = []
        let requested = selectedLanguage.map { [$0] } ?? preferredLanguages
        let languages = requested.isEmpty ? SubtitlePreferencesStore.systemCaptionLanguages : requested
        let itemID = itemID
        searchTask = Task { [weak self] in
            guard let self else { return }
            // Every remote endpoint answers 403 without this permission, so
            // ask once and say so, instead of reporting one opaque failure
            // per language.
            guard await client.canManageSubtitles() else {
                if generation == self.searchGeneration { self.phase = .notPermitted }
                return
            }
            guard generation == self.searchGeneration else { return }

            // Languages are searched concurrently: one slow provider must not
            // gate the rest, and sequentially they multiplied both the wait
            // and the number of chances to time out.
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
                // Provider ranking is meaningful, so restore request order
                // rather than completion order.
                return collected.sorted { $0.0 < $1.0 }
            }
            guard generation == self.searchGeneration else { return }
            if Task.isCancelled {
                self.phase = .idle
                return
            }

            var merged: [RemoteSubtitleInfo] = []
            var seen: Set<String> = []
            var successfulSearches = 0
            var itemMissing = false
            var failures: [SubtitleDownloadError] = []
            for (_, result) in outcomes {
                switch result {
                case .success(let matches):
                    successfulSearches += 1
                    for match in matches where seen.insert(match.id).inserted {
                        merged.append(match)
                    }
                case .failure(let error) where error is CancellationError:
                    self.phase = .idle
                    return
                case .failure(let error):
                    let classified = SubtitleDownloadError.classify(error)
                    // Jellyfin answers 404 for an item it cannot find, not for
                    // a missing provider; treat it as such.
                    if case .server(404) = classified {
                        itemMissing = true
                    } else {
                        failures.append(classified)
                    }
                }
            }

            self.results = merged
            if !merged.isEmpty {
                self.phase = .idle
            } else if let failure = Self.mostActionable(failures) {
                self.phase = failure == .notPermitted
                    ? .notPermitted
                    : .failed(failure.localizedDescription)
            } else if itemMissing, successfulSearches == 0 {
                self.phase = .noProvider
            } else {
                self.phase = .noResults
            }
        }
    }

    /// A permission or session problem explains every other failure in the
    /// batch, so it wins over whichever language happened to fail first.
    static func mostActionable(_ failures: [SubtitleDownloadError]) -> SubtitleDownloadError? {
        failures.first { $0 == .notPermitted }
            ?? failures.first { $0 == .sessionExpired }
            ?? failures.first
    }

    /// Retries only the transient half of `SubtitleDownloadError`, rethrowing
    /// the classified error so callers never have to re-derive it.
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

    func startDownload(_ result: RemoteSubtitleInfo) {
        guard let client, let engine, !phase.isBusy else { return }
        downloadTask?.cancel()
        downloadGeneration &+= 1
        let generation = downloadGeneration
        phase = .downloading(result.id)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            var directFailure: SubtitleDownloadError?
            do {
                guard await client.canManageSubtitles() else {
                    throw SubtitleDownloadError.notPermitted
                }
                try Task.checkCancellation()
                guard generation == self.downloadGeneration else { return }

                let requestedLanguage = SubtitlePreferencesStore.normalizedLanguage(
                    result.threeLetterISOLanguageName ?? selectedLanguage ?? ""
                )
                do {
                    // Fetch once for immediate playback, validate the actual
                    // bytes, then upload those same bytes to Jellyfin. This
                    // bypasses the 10.11.x endpoint that can return 204 even
                    // after its internal provider/save operation failed.
                    let file = try await Self.retrying {
                        try await client.remoteSubtitleFile(subtitleId: result.id)
                    }
                    let hasCues = await Task.detached {
                        !SubtitleParser.cues(from: file.data).isEmpty
                    }.value
                    guard hasCues else { throw SubtitleDownloadError.unsupportedFile }
                    try Task.checkCancellation()
                    guard generation == self.downloadGeneration else { return }
                    let track = ExternalSubtitleTrack(
                        url: file.url,
                        preloadedData: file.data,
                        title: result.name,
                        language: result.threeLetterISOLanguageName,
                        select: true,
                        isForced: result.isForced == true,
                        isHearingImpaired: result.hearingImpaired == true,
                        isDownloaded: true
                    )
                    engine.addExternalSubtitle(track)
                    phase = .downloaded

                    persistenceTask?.cancel()
                    persistenceTask = Task { [weak self] in
                        guard let self else { return }
                        try? await client.uploadSubtitle(
                            itemId: itemID,
                            data: file.data,
                            language: result.threeLetterISOLanguageName,
                            format: result.format ?? "srt",
                            isForced: result.isForced == true,
                            isHearingImpaired: result.hearingImpaired == true
                        )
                    }
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    directFailure = SubtitleDownloadError.classify(error)
                }

                // Jellyfin's native save/convert path is a compatibility
                // fallback for provider formats Lagoon cannot parse, and for
                // servers without the direct endpoint. It makes the server
                // fetch from the provider a *second* time, so it must not run
                // for a failure the retry could never fix — a 403 or an
                // expired session would only burn the provider's download
                // quota on its way to the same error.
                guard let directFailure,
                      directFailure == .unsupportedFile || directFailure == .server(404) else {
                    throw directFailure ?? .providerUnavailable
                }

                try await Self.retrying {
                    try await client.downloadRemoteSubtitle(itemId: itemID, subtitleId: result.id)
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
                let track = ExternalSubtitleTrack(
                    url: url,
                    title: stream.displayTitle ?? result.name,
                    language: stream.language ?? result.threeLetterISOLanguageName,
                    select: true,
                    isForced: stream.isForced == true || result.isForced == true,
                    isHearingImpaired: stream.isHearingImpaired == true || result.hearingImpaired == true,
                    isDownloaded: true
                )
                try Task.checkCancellation()
                guard generation == self.downloadGeneration else { return }
                existingSignatures.insert(SubtitleStreamSignature(stream))
                engine.addExternalSubtitle(track)
                onTrackAdded?(stream)
                phase = .downloaded
            } catch is CancellationError {
                if generation == self.downloadGeneration { phase = .idle }
            } catch {
                guard generation == self.downloadGeneration else { return }
                var failure = SubtitleDownloadError.classify(error)
                // The provider answered 404 for the file itself and Jellyfin's
                // save then attached nothing: the result really has gone from
                // the provider, which is the one case the quota/removal
                // wording is earned.
                if failure == .notAvailable, directFailure == .server(404) {
                    failure = .providerUnavailable
                }
                phase = failure == .notPermitted
                    ? .notPermitted
                    : .downloadFailed(failure.localizedDescription)
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        searchGeneration &+= 1
        downloadGeneration &+= 1
    }

    /// Playback dismissal severs the coordinator's session-sized references
    /// immediately. Cancellation alone stops the work but otherwise leaves
    /// the client and completion closure alive until the controller dies.
    func detach() {
        cancel()
        client = nil
        engine = nil
        onTrackAdded = nil
        itemID = ""
        mediaSourceID = ""
        existingSignatures.removeAll()
        results.removeAll()
        phase = .idle
    }

    static func makeLanguageChoices(preferredLanguages: [String]) -> [String] {
        // Settings retains the exhaustive language catalogue. Inside active
        // playback, keep this list deliberately compact and stable.
        SubtitlePreferencesStore.deduplicated(
            preferredLanguages + SubtitlePreferencesStore.commonLanguageChoices
        )
    }
}

/// Jellyfin's subtitle route uses ISO 639-2 identifiers while Apple's
/// preference APIs normally return BCP-47/two-letter identifiers.
nonisolated enum JellyfinSubtitleLanguageCode {
    /// ISO 639-1 → ISO 639-2/T. Source: the Library of Congress's official
    /// ISO 639-2 table. Languages that only have a three-letter code pass
    /// through unchanged below.
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
        // ISO 639-2/B aliases still appear in older media libraries even
        // though Jellyfin normally emits the terminological form above.
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
