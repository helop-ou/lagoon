import Foundation
import Observation

nonisolated enum SubtitleSearchPhase: Equatable {
    case idle
    case searching
    case noProvider
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

nonisolated enum SubtitleDownloadError: LocalizedError {
    case notAvailable
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Jellyfin did not make this subtitle available. The provider may have failed; try another result."
        case .unsupportedFile:
            "The subtitle provider returned a file Lagoon couldn't read. Try another result."
        }
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
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var downloadGeneration = 0

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
        searchTask = Task { [weak self] in
            guard let self else { return }
            var merged: [RemoteSubtitleInfo] = []
            var seen: Set<String> = []
            do {
                for language in languages {
                    try Task.checkCancellation()
                    let code = JellyfinSubtitleLanguageCode.threeLetter(for: language)
                    let matches = try await client.searchRemoteSubtitles(itemId: itemID, language: code)
                    guard generation == searchGeneration else { return }
                    for match in matches where seen.insert(match.id).inserted {
                        merged.append(match)
                    }
                }
                guard generation == searchGeneration else { return }
                results = merged
                phase = merged.isEmpty ? .noResults : .idle
            } catch is CancellationError {
                if generation == searchGeneration { phase = .idle }
            } catch JellyfinError.server(status: 404) {
                if generation == searchGeneration { phase = .noProvider }
            } catch {
                if generation == searchGeneration { phase = .failed(error.localizedDescription) }
            }
        }
    }

    func startDownload(_ result: RemoteSubtitleInfo) {
        guard let client, let engine, !phase.isBusy else { return }
        downloadGeneration &+= 1
        let generation = downloadGeneration
        phase = .downloading(result.id)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.downloadRemoteSubtitle(itemId: itemID, subtitleId: result.id)
                let requestedLanguage = SubtitlePreferencesStore.normalizedLanguage(
                    result.threeLetterISOLanguageName ?? selectedLanguage ?? ""
                )
                var attachedStream: MediaStream?
                let track: ExternalSubtitleTrack
                do {
                    let stream = try await DownloadedSubtitlePoller().waitForStream(
                        mediaSourceID: mediaSourceID,
                        existingSignatures: existingSignatures,
                        requestedLanguage: requestedLanguage
                    ) {
                        try await client.playbackInfo(itemId: self.itemID)
                    }
                    guard let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else {
                        throw SubtitleDownloadError.notAvailable
                    }
                    attachedStream = stream
                    track = ExternalSubtitleTrack(
                        url: url,
                        title: stream.displayTitle ?? result.name,
                        language: stream.language ?? result.threeLetterISOLanguageName,
                        select: true,
                        isForced: stream.isForced == true || result.isForced == true,
                        isHearingImpaired: stream.isHearingImpaired == true || result.hearingImpaired == true,
                        isDownloaded: true
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The POST endpoint can return success before a queued
                    // refresh exposes the sidecar (and even when server-side
                    // saving failed). Validate the provider file before the
                    // engine advertises it as selected.
                    let file: (url: URL, data: Data)
                    do {
                        file = try await client.remoteSubtitleFile(subtitleId: result.id)
                    } catch {
                        throw SubtitleDownloadError.notAvailable
                    }
                    let hasCues = await Task.detached {
                        !SubtitleParser.cues(from: file.data).isEmpty
                    }.value
                    guard hasCues else { throw SubtitleDownloadError.unsupportedFile }
                    track = ExternalSubtitleTrack(
                        url: file.url,
                        preloadedData: file.data,
                        title: result.name,
                        language: result.threeLetterISOLanguageName,
                        select: true,
                        isForced: result.isForced == true,
                        isHearingImpaired: result.hearingImpaired == true,
                        isDownloaded: true
                    )
                }
                try Task.checkCancellation()
                guard generation == downloadGeneration else { return }
                if let attachedStream {
                    existingSignatures.insert(SubtitleStreamSignature(attachedStream))
                }
                engine.addExternalSubtitle(track)
                if let attachedStream { onTrackAdded?(attachedStream) }
                phase = .downloaded
            } catch is CancellationError {
                if generation == downloadGeneration { phase = .idle }
            } catch {
                if generation == downloadGeneration { phase = .downloadFailed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        searchGeneration &+= 1
        downloadGeneration &+= 1
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
