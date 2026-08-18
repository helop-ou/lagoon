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
    private(set) var selectedLanguage: String?

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private weak var engine: (any PlayerEngine)?
    @ObservationIgnored private var itemID = ""
    @ObservationIgnored private var mediaSourceID = ""
    @ObservationIgnored private var existingSignatures: Set<StreamSignature> = []
    @ObservationIgnored private var onTrackAdded: ((MediaStream) -> Void)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0

    var languageChoices: [String] {
        SubtitlePreferencesStore.deduplicated(preferredLanguages + SubtitlePreferencesStore.allLanguageChoices)
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
        self.onTrackAdded = onTrackAdded
        selectedLanguage = nil
        results = []
        phase = .idle
        existingSignatures = Set(streams.filter { $0.type == "Subtitle" }.map(StreamSignature.init))
        if missingMode == .automaticSearch, !hasSuitableLocalTrack {
            searchTask = Task { [weak self] in
                await self?.search()
            }
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

    func search() async {
        guard let client else { return }
        searchGeneration &+= 1
        let generation = searchGeneration
        phase = .searching
        results = []
        let requested = selectedLanguage.map { [$0] } ?? preferredLanguages
        let languages = requested.isEmpty ? SubtitlePreferencesStore.systemCaptionLanguages : requested
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
            phase = .idle
        } catch JellyfinError.server(status: 404) {
            phase = .noProvider
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func download(_ result: RemoteSubtitleInfo) async {
        guard let client, let engine else { return }
        phase = .downloading(result.id)
        do {
            try await client.downloadRemoteSubtitle(itemId: itemID, subtitleId: result.id)
            let playbackInfo = try await client.playbackInfo(itemId: itemID)
            guard let source = playbackInfo.mediaSources.first(where: { $0.id == mediaSourceID })
                    ?? playbackInfo.mediaSources.first else {
                throw JellyfinError.unplayable
            }
            let externalStreams = (source.mediaStreams ?? []).filter {
                $0.type == "Subtitle" && $0.isExternal == true
            }
            let requestedLanguage = SubtitlePreferencesStore.normalizedLanguage(
                result.threeLetterISOLanguageName ?? selectedLanguage ?? ""
            )
            let stream = externalStreams.first {
                !existingSignatures.contains(StreamSignature($0))
                    && (requestedLanguage == nil
                        || SubtitlePreferencesStore.normalizedLanguage($0.language ?? "") == requestedLanguage)
            } ?? externalStreams.first {
                !existingSignatures.contains(StreamSignature($0))
            }
            guard let stream,
                  let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else {
                throw JellyfinError.unplayable
            }
            existingSignatures.insert(StreamSignature(stream))
            engine.addExternalSubtitle(ExternalSubtitleTrack(
                url: url,
                title: stream.displayTitle ?? result.name,
                language: stream.language ?? result.threeLetterISOLanguageName,
                select: true,
                isForced: stream.isForced == true || result.isForced == true,
                isHearingImpaired: stream.isHearingImpaired == true || result.hearingImpaired == true,
                isDownloaded: true
            ))
            onTrackAdded?(stream)
            phase = .downloaded
        } catch {
            phase = .downloadFailed(error.localizedDescription)
        }
    }

    func cancel() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
    }

    private struct StreamSignature: Hashable {
        let index: Int?
        let deliveryURL: String?

        init(_ stream: MediaStream) {
            index = stream.index
            deliveryURL = stream.deliveryUrl
        }
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

    static func threeLetter(for identifier: String) -> String {
        let normalized = SubtitlePreferencesStore.normalizedLanguage(identifier) ?? identifier.lowercased()
        if normalized.count == 3 { return normalized }
        return common[normalized] ?? normalized
    }
}
