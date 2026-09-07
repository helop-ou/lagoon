import Foundation
import Testing
@testable import Lagoon

@Suite("Subtitle provider", .serialized)
struct SubtitleProviderTests {
    // MARK: - Movie hash

    @Test func movieHashMatchesAnIndependentComputation() {
        // Cross-checked against a separate implementation of the documented
        // algorithm (file size + little-endian u64 sums of both chunks, with
        // unsigned wraparound) over the same synthetic chunks.
        let head = Self.patternChunk(seed: 3)
        let tail = Self.patternChunk(seed: 11)
        #expect(MovieHash.value(fileSize: 1_234_567_890, head: head, tail: tail)
            == "60a0df1fa935c2d2")
    }

    @Test func movieHashKeepsItsLeadingZeros() {
        // Empty chunks contribute nothing, so the hash is the file size and
        // the padded form is verifiable by hand. The provider matches on the
        // 16-character form, so a truncated one silently never matches.
        let zeros = Data(repeating: 0, count: MovieHash.chunkSize)
        #expect(MovieHash.value(fileSize: 131_072, head: zeros, tail: zeros)
            == "0000000000020000")
    }

    @Test func movieHashRefusesInputItCannotHash() {
        let chunk = Self.patternChunk(seed: 1)
        let short = Data(repeating: 0, count: MovieHash.chunkSize - 1)
        // Below the minimum the two chunks would overlap.
        #expect(MovieHash.value(fileSize: 131_071, head: chunk, tail: chunk) == nil)
        #expect(!MovieHash.supports(fileSize: 131_071))
        #expect(!MovieHash.supports(fileSize: MovieHash.maximumFileSize))
        // A truncated range response must not silently produce a wrong hash.
        #expect(MovieHash.value(fileSize: 500_000, head: short, tail: chunk) == nil)
        #expect(MovieHash.value(fileSize: 500_000, head: chunk, tail: short) == nil)
    }

    // MARK: - Query construction

    @Test func providerQuerySendsSortedFiltersAndNumericIdentifiers() {
        let query = OpenSubtitlesQuery(
            languages: ["en-US", "eng", "et"],
            movieHash: "0123456789abcdef",
            imdbID: "tt0133093",
            tmdbID: nil,
            title: "The Matrix",
            seasonNumber: nil,
            episodeNumber: nil,
            isEpisode: false
        )
        let items = OpenSubtitlesClient.queryItems(for: query)

        // The provider asks for sorted parameters so its cache is not split.
        #expect(items.map(\.name) == items.map(\.name).sorted())
        #expect(items.first { $0.name == "imdb_id" }?.value == "0133093")
        #expect(items.first { $0.name == "moviehash" }?.value == "0123456789abcdef")
        // en-US and eng are the same language and must not be sent twice.
        #expect(items.first { $0.name == "languages" }?.value == "en,et")
        // An identifier is a precise filter; adding the title alongside can
        // only lose matches on a spelling difference.
        #expect(!items.contains { $0.name == "query" })
    }

    @Test func providerQueryFallsBackToTitleAndEpisodeNumbers() {
        let query = OpenSubtitlesQuery(
            languages: ["en"],
            movieHash: nil,
            imdbID: nil,
            tmdbID: nil,
            title: "Rick and Morty",
            seasonNumber: 1,
            episodeNumber: 1,
            isEpisode: true
        )
        let items = OpenSubtitlesClient.queryItems(for: query)
        #expect(items.first { $0.name == "query" }?.value == "rick and morty")
        #expect(items.first { $0.name == "season_number" }?.value == "1")
        #expect(items.first { $0.name == "episode_number" }?.value == "1")

        // Nothing to match on would return the provider's popular list rather
        // than this title's subtitles.
        var empty = query
        empty.title = "   "
        #expect(!empty.isSearchable)
    }

    // MARK: - Search and download

    @Test func providerSearchMapsResultsAndRanksExactMatchesFirst() async throws {
        let client = Self.makeClient()
        OpenSubtitlesURLProtocol.reset()

        let results = try await client.search(OpenSubtitlesQuery(
            languages: ["en"],
            movieHash: nil,
            imdbID: "tt1",
            tmdbID: nil,
            title: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            isEpisode: false
        ))
        #expect(results.count == 4)

        let candidates = SubtitleCandidate.ranked(results.map(SubtitleCandidate.init))
        // A release-exact hash match is the most useful result there is, and
        // a machine translation the least.
        #expect(candidates.first?.isHashMatch == true)
        #expect(candidates.last?.isMachineTranslated == true)
        #expect(candidates.allSatisfy { $0.source == .openSubtitles })
        #expect(candidates.first?.providerFileID == 200)
        #expect(candidates.first?.jellyfinID == nil)

        // OpenSubtitles models "forced" as foreign-parts-only, but marks some
        // hearing-impaired uploads that way too.
        let forced = try #require(candidates.first { $0.providerFileID == 201 })
        #expect(forced.isForced)
        let sdh = try #require(candidates.first { $0.providerFileID == 202 })
        #expect(sdh.isHearingImpaired)
        #expect(!sdh.isForced)
    }

    @Test func providerDownloadFollowsTheTemporaryLinkAndTracksQuota() async throws {
        let client = Self.makeClient()
        OpenSubtitlesURLProtocol.reset()

        let data = try await client.download(fileID: 200)
        #expect(String(data: data, encoding: .utf8)?.contains("Provider cue") == true)
        #expect(client.remainingDownloads == 17)
        // Two steps by design: the link is short-lived, and the bytes come
        // from a plain GET that must not carry the API credentials.
        #expect(OpenSubtitlesURLProtocol.requests.contains { $0.path == "/api/v1/download" })
        #expect(OpenSubtitlesURLProtocol.requests.contains { $0.path == "/files/200.srt" })
        let fileRequest = try #require(
            OpenSubtitlesURLProtocol.requests.first { $0.path == "/files/200.srt" }
        )
        #expect(fileRequest.apiKey == nil)
    }

    @Test func exhaustedQuotaIsReportedAsQuotaAndInvitesSignIn() async {
        let client = Self.makeClient()
        OpenSubtitlesURLProtocol.reset()

        do {
            _ = try await client.download(fileID: 406)
            Issue.record("Expected the provider quota to be reported")
        } catch {
            let classified = OpenSubtitlesError.classify(error)
            #expect(classified == .quotaExhausted(resetTime: "5 hours"))
            // An account is the one thing that actually raises the allowance,
            // so this is the only failure worth turning into a prompt.
            #expect(classified.invitesSignIn)
            #expect(!OpenSubtitlesError.rateLimited.invitesSignIn)
            #expect(classified.localizedDescription.contains("5 hours"))
        }
    }

    @Test func oversizedProviderFileFailsWithTheDownloadLimit() async throws {
        let client = Self.makeClient()
        OpenSubtitlesURLProtocol.reset()
        do { _ = try await client.download(fileID: 413); Issue.record("Expected the subtitle byte limit") }
        catch SubtitleDownloadError.tooLarge {}
    }

    @Test func aRejectedTokenIsDroppedRatherThanRetriedForever() async {
        let client = Self.makeClient()
        OpenSubtitlesURLProtocol.reset()
        client.restoreSession(token: "stale-token", accountName: "tester")
        #expect(client.isSignedIn)

        _ = try? await client.download(fileID: 401)
        // Keeping a rejected token would make every later call fail the same
        // way; dropping it falls back to the anonymous allowance instead.
        #expect(!client.isSignedIn)
    }

    @Test func aMissingKeyIsItsOwnAnswerNotAFailedSearch() async {
        let client = OpenSubtitlesClient(session: Self.makeSession())
        #expect(!client.isConfigured)
        do {
            _ = try await client.search(OpenSubtitlesQuery(
                languages: ["en"], movieHash: nil, imdbID: "tt1", tmdbID: nil,
                title: nil, seasonNumber: nil, episodeNumber: nil, isEpisode: false
            ))
            Issue.record("Expected an unconfigured provider to refuse")
        } catch {
            #expect(OpenSubtitlesError.classify(error) == .notConfigured)
        }
    }

    // MARK: - Source policy

    @Test func jellyfinIsPreferredWhenevertItCanServeTheAccount() {
        // Jellyfin persists the sidecar for every client and costs the viewer
        // none of their personal provider quota, so it wins when available.
        #expect(SubtitleSourcePolicy.resolve(
            preference: .automatic, jellyfinAllowed: true, providerConfigured: true
        ) == .success(.jellyfin))
        // The case this whole ticket exists for: a shared server where the
        // account may not manage subtitles.
        #expect(SubtitleSourcePolicy.resolve(
            preference: .automatic, jellyfinAllowed: false, providerConfigured: true
        ) == .success(.openSubtitles))
        #expect(SubtitleSourcePolicy.resolve(
            preference: .automatic, jellyfinAllowed: false, providerConfigured: false
        ) == .failure(.jellyfinNotPermitted))
        // An explicit choice is never silently overridden.
        #expect(SubtitleSourcePolicy.resolve(
            preference: .jellyfin, jellyfinAllowed: false, providerConfigured: true
        ) == .failure(.jellyfinNotPermitted))
        #expect(SubtitleSourcePolicy.resolve(
            preference: .openSubtitles, jellyfinAllowed: true, providerConfigured: false
        ) == .failure(.providerNotConfigured))
        #expect(SubtitleSourcePolicy.resolve(
            preference: .openSubtitles, jellyfinAllowed: true, providerConfigured: true
        ) == .success(.openSubtitles))
    }

    // MARK: - Text decoding

    @Test func legacyEncodedSubtitlesDecodeInsteadOfTurningIntoMojibake() throws {
        // The previous chain ended in isoLatin1, which cannot fail — so this
        // Cyrillic file decoded to garbage and rendered with no error at all.
        let russian = "Привет, как дела?"
        let cp1251 = try #require(russian.data(
            using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
            ))
        ))
        #expect(SubtitleTextDecoder.text(from: cp1251, languageHint: "rus") == russian)
        #expect(SubtitleTextDecoder.text(from: cp1251, languageHint: "ru") == russian)

        // Documented limitation: with no hint this still decodes to mojibake.
        // Cyrillic bytes read as Latin-1 become accented Latin letters, which
        // are perfectly ordinary characters — telling that apart from real
        // Western-European text needs statistical models, and a cheap
        // heuristic that guessed would mis-decode German as Cyrillic, which is
        // worse than the status quo. The language is the mechanism; the
        // plausibility check is only a guard against control-character
        // garbage. Every path that fetches a subtitle now carries a language.
        let guessed = SubtitleTextDecoder.text(from: cp1251, languageHint: nil)
        #expect(guessed != russian)
        #expect(SubtitleTextDecoder.isPlausibleSubtitleText(guessed ?? ""))

        // What the guard does catch: bytes that decode to control characters.
        let binary = Data((0..<256).map { UInt8($0 % 32) })
        #expect(!SubtitleTextDecoder.isPlausibleSubtitleText(
            SubtitleTextDecoder.text(from: binary, languageHint: nil) ?? ""
        ))
    }

    @Test func utf8AndBOMsWinOverAnyLanguageHint() throws {
        let text = "Ordinary subtitle line"
        let utf8 = Data(text.utf8)
        // Valid UTF-8 is never accidental, so a wrong hint cannot corrupt it.
        #expect(SubtitleTextDecoder.text(from: utf8, languageHint: "rus") == text)

        let bom = Data([0xEF, 0xBB, 0xBF]) + utf8
        #expect(SubtitleTextDecoder.text(from: bom, languageHint: nil) == text)

        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try #require(text.data(using: .utf16LittleEndian)))
        #expect(SubtitleTextDecoder.text(from: utf16, languageHint: nil) == text)

        #expect(SubtitleTextDecoder.text(from: Data(), languageHint: nil) == nil)
    }

    @Test func cuesParseThroughTheLanguageAwareDecoder() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,000\r\nПривет\r\n"
        let cp1251 = try #require(srt.data(
            using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
            ))
        ))
        let cues = SubtitleParser.cues(from: cp1251, languageHint: "rus")
        #expect(cues.count == 1)
        #expect(cues.first?.text == "Привет")
    }

    // MARK: - Sidecar reuse

    @Test func aRepeatWatchIsServedFromDiskRatherThanSpendingAnotherDownload() throws {
        let itemID = "item-" + UUID().uuidString
        let candidateID = "opensubtitles:12345"
        #expect(SubtitleFileStore.cached(itemID: itemID, candidateID: candidateID) == nil)

        let payload = Data("1\n00:00:01,000 --> 00:00:02,000\nCached\n".utf8)
        let stored = try #require(SubtitleFileStore.store(
            payload, itemID: itemID, candidateID: candidateID
        ))
        defer { try? FileManager.default.removeItem(at: stored) }

        // The daily allowance is five downloads anonymously, so re-watching
        // an episode must not spend one.
        let cached = try #require(SubtitleFileStore.cached(itemID: itemID, candidateID: candidateID))
        #expect(cached.data == payload)
        #expect(cached.url == stored)
        // The candidate id carries a colon, which cannot go into a filename.
        #expect(!stored.lastPathComponent.contains(":"))
    }

    // MARK: - Helpers

    private static func patternChunk(seed: Int) -> Data {
        Data((0..<MovieHash.chunkSize).map { UInt8(($0 * 7 + seed) % 256) })
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenSubtitlesURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func makeClient() -> OpenSubtitlesClient {
        let client = OpenSubtitlesClient(session: makeSession())
        client.configure(apiKey: "test-key")
        return client
    }
}

private nonisolated struct RecordedProviderRequest: Sendable {
    let method: String
    let path: String
    let query: String?
    let apiKey: String?
    let authorization: String?
    let userAgent: String?
}

/// A deterministic OpenSubtitles transport. The real API cannot be reached
/// without a registered consumer key, so the wire format is pinned here.
private nonisolated final class OpenSubtitlesURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [RecordedProviderRequest] = []

    static var requests: [RecordedProviderRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host
        return host == "api.opensubtitles.com" || host == "files.opensubtitles.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.recorded.append(RecordedProviderRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: url.query,
            apiKey: request.value(forHTTPHeaderField: "Api-Key"),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            userAgent: request.value(forHTTPHeaderField: "User-Agent")
        ))
        Self.lock.unlock()

        let body = bodyString()
        let payload: Data
        let status: Int
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/api/v1/subtitles"):
            payload = Data(Self.searchPayload.utf8)
            status = 200
        case ("POST", "/api/v1/download") where body?.contains("\"file_id\":406") == true:
            payload = Data(#"{"requests":20,"remaining":0,"reset_time":"5 hours"}"#.utf8)
            status = 406
        case ("POST", "/api/v1/download") where body?.contains("\"file_id\":401") == true:
            payload = Data(#"{"message":"invalid token"}"#.utf8)
            status = 401
        case ("POST", "/api/v1/download") where body?.contains("\"file_id\":413") == true:
            payload = Data(#"{"link":"https://files.opensubtitles.test/files/oversized.srt"}"#.utf8)
            status = 200
        case ("POST", "/api/v1/download"):
            payload = Data(#"{"link":"https://files.opensubtitles.test/files/200.srt","file_name":"m.srt","requests":3,"remaining":17,"reset_time":"20 hours"}"#.utf8)
            status = 200
        case ("GET", "/files/200.srt"):
            payload = Data("1\n00:00:01,000 --> 00:00:03,000\nProvider cue\n".utf8)
            status = 200
        case ("GET", "/files/oversized.srt"):
            payload = Data(repeating: 65, count: DownloadLimit.subtitle + 1)
            status = 200
        default:
            payload = Data()
            status = 404
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": url.path.hasSuffix(".srt") ? "application/x-subrip" : "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty { client?.urlProtocol(self, didLoad: payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyString() -> String? {
        if let body = request.httpBody { return String(data: body, encoding: .utf8) }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }

    private static let searchPayload = #"""
    { "data": [
      { "attributes": { "language": "en", "release": "Machine translated",
          "download_count": 5, "machine_translated": true, "moviehash_match": false,
          "uploader": { "name": "bot" }, "files": [ { "file_id": 203 } ] } },
      { "attributes": { "language": "en", "release": "Forced signs",
          "download_count": 9, "foreign_parts_only": true, "moviehash_match": false,
          "uploader": { "name": "someone" }, "files": [ { "file_id": 201 } ] } },
      { "attributes": { "language": "en", "release": "SDH full",
          "download_count": 40, "hearing_impaired": true, "foreign_parts_only": true,
          "moviehash_match": false, "uploader": { "name": "someone" },
          "files": [ { "file_id": 202 } ] } },
      { "attributes": { "language": "en", "release": "Exact release",
          "download_count": 1200, "moviehash_match": true,
          "uploader": { "name": "someone" }, "files": [ { "file_id": 200 } ] } }
    ] }
    """#
}
