import Foundation

/// Lagoon's own access to TMDB, used for one thing: title logos for the
/// titles Seerr shows (HEL-174). Seerr relays TMDB's posters and backdrops
/// but none of its logos, so the Discover hero and a Seerr title's page set
/// the name in type where a library title shows its artwork. TMDB's images
/// endpoint has the logos, keyed by the same ids Seerr uses.
///
/// TMDB issues one API key per application. The key is compiled in like the
/// Sentry DSN (`DiagnosticsConfiguration`); while it is empty the provider
/// answers nil without a request and every title keeps its name in type.
/// `-tmdb.apiKey <key>` overrides it for a run.
nonisolated enum TMDBConfiguration {
    static let apiKey = ""
    static let apiKeyOverrideKey = "tmdb.apiKey"
    static let apiURL = URL(string: "https://api.themoviedb.org/3/")!

    static var resolvedAPIKey: String? {
        let configured = UserDefaults.standard.string(forKey: apiKeyOverrideKey) ?? apiKey
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One logo as TMDB lists it. Snake-case on the wire, like the rest of TMDB.
nonisolated struct TMDBLogo: Decodable, Hashable {
    let filePath: String
    /// The language the wordmark is set in; nil for a mark with no words.
    let language: String?
    let voteAverage: Double
    let width: Int

    init(filePath: String, language: String?, voteAverage: Double = 0, width: Int = 0) {
        self.filePath = filePath
        self.language = language
        self.voteAverage = voteAverage
        self.width = width
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language)
        voteAverage = try container.decodeIfPresent(Double.self, forKey: .voteAverage) ?? 0
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case language = "iso_639_1"
        case voteAverage = "vote_average"
        case width
    }
}

nonisolated struct TMDBImages: Decodable {
    let logos: [TMDBLogo]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        logos = try container.decodeIfPresent([TMDBLogo].self, forKey: .logos) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case logos
    }
}

/// Which of a title's logos to show. Pure, so the unit suite pins it.
nonisolated enum TMDBLogoSelection {
    /// The languages worth asking TMDB for, most wanted first: the viewer's
    /// own, then English, then marks with no words at all (TMDB spells the
    /// last one `null`).
    static func requestedLanguages(preferred: String?) -> [String] {
        var languages: [String] = []
        if let preferred, !preferred.isEmpty, preferred != "en" {
            languages.append(preferred)
        }
        languages.append("en")
        languages.append("null")
        return languages
    }

    /// The best logo in the viewer's language, else in English, else a mark
    /// with no words; within a language the best-voted, then the largest.
    /// PNG only: TMDB lists SVG logos too, which the image loader cannot
    /// decode, and a title is better served by its name than a blank box.
    static func pick(from logos: [TMDBLogo], languages: [String]) -> TMDBLogo? {
        let usable = logos.filter { $0.filePath.lowercased().hasSuffix(".png") }
        for language in languages {
            let candidates = usable.filter { logo in
                language == "null" ? logo.language == nil || logo.language == "" : logo.language == language
            }
            if let best = candidates.max(by: { lhs, rhs in
                (lhs.voteAverage, lhs.width) < (rhs.voteAverage, rhs.width)
            }) {
                return best
            }
        }
        return nil
    }
}

/// Fetches and remembers title logos for the session. One lookup per title
/// however many views ask, and a title with no logo is remembered as such
/// so the hero does not ask again on every slide.
actor TMDBLogoProvider {
    static let shared = TMDBLogoProvider()

    private let session: URLSession
    private let apiKey: String?
    private let languages: [String]
    /// Answers TMDB has given: a path, or nil for a title with no logo. A
    /// failed request is not "no logo" and is not remembered, so the next
    /// page that asks gets another try.
    private var answers: [String: String?] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]

    private enum Lookup {
        case found(String)
        case none
        case failed
    }

    init(
        session: URLSession = URLSession(configuration: .default),
        apiKey: String? = TMDBConfiguration.resolvedAPIKey,
        preferredLanguage: String? = Locale.current.language.languageCode?.identifier
    ) {
        self.session = session
        self.apiKey = apiKey
        self.languages = TMDBLogoSelection.requestedLanguages(preferred: preferredLanguage)
    }

    /// Whether a key is configured at all. Callers skip the lookup and its
    /// state entirely when it is not.
    nonisolated var isEnabled: Bool { apiKey != nil }

    /// The TMDB image path of the title's logo, for `SeerrClient.imageURL`,
    /// or nil when there is none, the key is missing, or TMDB is unreachable.
    func logoPath(id: Int, mediaType: SeerrMediaType) async -> String? {
        guard apiKey != nil, mediaType != .person else { return nil }
        let key = "\(mediaType.rawValue):\(id)"
        if let answered = answers[key] { return answered }
        let task: Task<Lookup, Never>
        if let running = inFlight[key] {
            task = running
        } else {
            task = Task { await self.fetch(id: id, mediaType: mediaType) }
            inFlight[key] = task
        }
        let lookup = await task.value
        inFlight[key] = nil
        switch lookup {
        case .found(let path):
            answers[key] = path
            return path
        case .none:
            answers[key] = .some(nil)
            return nil
        case .failed:
            return nil
        }
    }

    private func fetch(id: Int, mediaType: SeerrMediaType) async -> Lookup {
        guard let apiKey else { return .failed }
        var components = URLComponents(
            url: TMDBConfiguration.apiURL.appending(path: "\(mediaType.rawValue)/\(id)/images"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "include_image_language", value: languages.joined(separator: ",")),
        ]
        guard let url = components?.url else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            // 404 is TMDB's answer for an id it does not know: nothing to
            // show, and nothing to retry.
            if http.statusCode == 404 { return .none }
            guard (200..<300).contains(http.statusCode) else { return .failed }
            let images = try JSONDecoder().decode(TMDBImages.self, from: data)
            if let logo = TMDBLogoSelection.pick(from: images.logos, languages: languages) {
                return .found(logo.filePath)
            }
            return .none
        } catch {
            return .failed
        }
    }
}
