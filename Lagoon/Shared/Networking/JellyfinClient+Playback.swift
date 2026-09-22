import CoreGraphics
import Foundation
import LagoonEngine

// Stream resolution and progress reporting.
extension JellyfinClient {
    nonisolated struct PlaybackInfoRequest: Encodable {
        let deviceProfile: DeviceProfile.Profile
        let autoOpenLiveStream: Bool
        let maxStreamingBitrate: Int
        /// Jellyfin defaults all four of these to true. They are sent
        /// explicitly so a retry can withdraw them one rung at a time
        /// rather than restating the whole profile.
        let enableDirectPlay: Bool
        let enableDirectStream: Bool
        let allowVideoStreamCopy: Bool
        let allowAudioStreamCopy: Bool

        init(
            deviceProfile: DeviceProfile.Profile,
            autoOpenLiveStream: Bool,
            maxStreamingBitrate: Int,
            delivery: PlaybackDelivery
        ) {
            self.deviceProfile = deviceProfile
            self.autoOpenLiveStream = autoOpenLiveStream
            self.maxStreamingBitrate = maxStreamingBitrate
            let flags = delivery.flags
            enableDirectPlay = flags.enableDirectPlay
            enableDirectStream = flags.enableDirectStream
            allowVideoStreamCopy = flags.allowVideoStreamCopy
            allowAudioStreamCopy = flags.allowAudioStreamCopy
        }
    }

    nonisolated struct PlaybackStartInfo: Encodable {
        let itemId: String
        let mediaSourceId: String
        let playSessionId: String?
        let positionTicks: Int64
        let playMethod: String
        let canSeek: Bool
    }

    nonisolated struct PlaybackProgressInfo: Encodable {
        let itemId: String
        let mediaSourceId: String
        let playSessionId: String?
        let positionTicks: Int64
        let isPaused: Bool
        let playMethod: String
    }

    nonisolated struct PlaybackStopInfo: Encodable {
        let itemId: String
        let mediaSourceId: String
        let playSessionId: String?
        let positionTicks: Int64
    }

    nonisolated struct SubtitleUploadRequest: Encodable {
        let data: String
        let language: String?
        let format: String
        let isForced: Bool
        let isHearingImpaired: Bool
    }

    /// Negotiates a stream. `delivery` is how hard the server is being asked
    /// to work: `.negotiated` lets it pick freely (direct play for anything
    /// inside the profile), while the lower rungs withdraw permissions after
    /// a playback failure so it reaches for a remux, then a re-encode.
    func playbackInfo(
        itemId: String,
        delivery: PlaybackDelivery = .negotiated
    ) async throws -> PlaybackInfoResponse {
        let userId = try requireUserId()
        // The rung shapes the profile as well as the flags: the bottom one
        // is the only place the server re-encodes, and it is bounded so it
        // asks for something an encoder can actually produce in realtime.
        #if DEBUG && targetEnvironment(simulator)
        let profile = UserDefaults.standard.bool(forKey: "debug.simulatorTranscode")
            ? DeviceProfile.simulatorRegression
            : DeviceProfile.lagoon(for: delivery)
        #else
        let profile = DeviceProfile.lagoon(for: delivery)
        #endif
        return try await post(
            "Items/\(itemId)/PlaybackInfo",
            query: [URLQueryItem(name: "UserId", value: userId)],
            body: PlaybackInfoRequest(
                deviceProfile: profile,
                autoOpenLiveStream: true,
                maxStreamingBitrate: profile.maxStreamingBitrate,
                delivery: delivery
            )
        )
    }

    /// Resolves a media source to a playable URL, preferring direct play,
    /// then direct stream, then the server-negotiated transcode.
    func streamURL(itemId: String, source: MediaSource) throws -> (url: URL, method: PlayMethod) {
        if source.supportsDirectPlay == true, accessToken != nil {
            return (
                try url(path: "Videos/\(itemId)/stream", query: staticStreamQuery(source: source)),
                .directPlay
            )
        }
        // Direct stream: the bytes are playable as-is but must be served
        // through the server (remote/.strm sources, static-bitrate limits).
        // jellyfin-web requests stream.{container} with static=true here;
        // the container can arrive as an ffprobe list ("mov,mp4,m4a").
        if source.supportsDirectStream == true, accessToken != nil,
           let container = source.container?.split(separator: ",").first {
            return (
                try url(path: "Videos/\(itemId)/stream.\(container)", query: staticStreamQuery(source: source)),
                .directStream
            )
        }
        if let transcodingUrl = source.transcodingUrl, serverURL != nil {
            // TranscodingUrl arrives server-relative, query string included,
            // and must keep the server's base path.
            guard let resolvedURL = serverRelativeURL(transcodingUrl) else {
                throw JellyfinError.unplayable
            }
            // The server may have stamped its own api_key/ApiKey into this
            // URL; strip it rather than send two credentials, and never
            // touch a cross-origin transcode URL at all.
            let url = mediaRequestAuthorization()?.sanitizedURL(resolvedURL) ?? resolvedURL
            return (url, .transcode)
        }
        throw JellyfinError.unplayable
    }

    /// Resolves an external subtitle stream's DeliveryUrl (server-relative,
    /// not always carrying credentials) into a fetchable absolute URL.
    func externalSubtitleURL(deliveryUrl: String?) -> URL? {
        guard let deliveryUrl, serverURL != nil, accessToken != nil,
              let url = serverRelativeURL(deliveryUrl) else { return nil }
        return mediaRequestAuthorization()?.sanitizedURL(url) ?? url
    }

    // MARK: - Remote subtitles

    /// Searches every subtitle provider configured on the Jellyfin server.
    /// Jellyfin expects an ISO language identifier and preserves provider
    /// ranking in the returned array.
    func searchRemoteSubtitles(itemId: String, language: String) async throws -> [RemoteSubtitleInfo] {
        try await get(
            ["Items", itemId, "RemoteSearch", "Subtitles", language],
            timeout: SubtitleRequestTimeout.provider
        )
    }

    /// Asks Jellyfin to download and attach a result. The file belongs to
    /// the server/library after this point; Lagoon then refreshes
    /// PlaybackInfo to obtain the authoritative stream index and URL.
    func downloadRemoteSubtitle(itemId: String, subtitleId: String) async throws {
        try await postVoid(
            ["Items", itemId, "RemoteSearch", "Subtitles", subtitleId],
            timeout: SubtitleRequestTimeout.provider
        )
    }

    /// Fetches the provider result itself. This is a live-playback fallback
    /// for servers that accept the save request but fail to expose the new
    /// sidecar during their queued library refresh.
    func remoteSubtitleFile(subtitleId: String) async throws -> (url: URL, data: Data) {
        guard accessToken != nil else { throw JellyfinError.notConfigured }
        let components = ["Providers", "Subtitles", "Subtitles", subtitleId]
        // The caller always has the bytes already (`getData` below); this URL
        // is kept only as the track's display/identity value, so it carries
        // no credential at all rather than one more copy of the token.
        let deliveryURL = try url(pathComponents: components)
        return (
            deliveryURL,
            try await getData(components, timeout: SubtitleRequestTimeout.provider, maximumBytes: DownloadLimit.subtitle)
        )
    }

    /// Persists provider bytes already fetched for immediate playback. This
    /// avoids asking the provider for the same file a second time and avoids
    /// Jellyfin's remote-download endpoint silently returning 204 after an
    /// internal provider/save failure (the behavior in Jellyfin 10.11.x).
    func uploadSubtitle(
        itemId: String,
        data: Data,
        language: String?,
        format: String,
        isForced: Bool,
        isHearingImpaired: Bool
    ) async throws {
        let normalizedFormat = format
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalizedFormat.isEmpty else { throw SubtitleDownloadError.unsupportedFile }
        try await postVoid(
            ["Videos", itemId, "Subtitles"],
            body: SubtitleUploadRequest(
                data: data.base64EncodedString(),
                language: language,
                format: normalizedFormat,
                isForced: isForced,
                isHearingImpaired: isHearingImpaired
            )
        )
    }

    private func staticStreamQuery(source: MediaSource) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: source.id),
            URLQueryItem(name: "deviceId", value: deviceId),
        ]
        if let eTag = source.eTag {
            query.append(URLQueryItem(name: "Tag", value: eTag))
        }
        return query
    }

    /// Every media consumer — the FFmpeg transport, the playback cache, the
    /// subtitle loader, the trickplay loader — attaches the credential itself
    /// via `MediaRequestAuthorization`, so no URL Lagoon builds carries the
    /// token (CFNetwork logs a failed task's full URL into the unified log, and
    /// a query token would leak into diagnostics where the header never does).
    /// Server-provided playback and subtitle URLs may still contain either
    /// legacy spelling (`api_key`/`ApiKey`); `sanitizedURL(_:)` strips it on
    /// the Jellyfin origin and leaves any other origin's URL untouched.

    // MARK: - Transport extras

    /// Chapters and trickplay geometry, as the item endpoint reports them.
    nonisolated struct PlaybackExtras: Decodable {
        let chapters: [ChapterInfo]
        let originalLanguage: String?
        /// Keyed by media source id, then by resolution width — verbatim,
        /// since the decoder's PascalCase strategy leaves dictionary keys
        /// alone (only `CodingKey`s are converted).
        let trickplay: [String: [String: TrickplayTileInfo]]

        static let none = PlaybackExtras(chapters: [], originalLanguage: nil, trickplay: [:])

        init(
            chapters: [ChapterInfo],
            originalLanguage: String? = nil,
            trickplay: [String: [String: TrickplayTileInfo]]
        ) {
            self.chapters = chapters
            self.originalLanguage = originalLanguage
            self.trickplay = trickplay
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            chapters = (try? c.decodeIfPresent([ChapterInfo].self, forKey: "chapters")) ?? []
            originalLanguage = try? c.decodeIfPresent(String.self, forKey: "originalLanguage")
            trickplay = (try? c.decodeIfPresent([String: [String: TrickplayTileInfo]].self, forKey: "trickplay")) ?? [:]
        }
    }

    /// Fetched separately from `playbackInfo` (which carries neither) and
    /// from the item the caller already holds: playback starts from rails
    /// too, and their list requests don't ask for these fields. Never
    /// throws — both features are garnish, and a server that hasn't
    /// generated them must simply go without.
    func playbackExtras(itemId: String) async -> PlaybackExtras {
        guard let userId else { return .none }
        return (try? await get("Users/\(userId)/Items/\(itemId)")) ?? .none
    }

    /// Resolves the trickplay tiles for a media source into everything the
    /// transport needs, or nil when the server has none for it.
    func trickplaySource(itemId: String, mediaSourceId: String, extras: PlaybackExtras) -> TrickplaySource? {
        // Match the source's own tiles; fall back to the only entry when the
        // keys disagree (transcodes report a different source id than the
        // file the tiles were generated from).
        let byWidth = extras.trickplay.first { $0.key.caseInsensitiveCompare(mediaSourceId) == .orderedSame }?.value
            ?? (extras.trickplay.count == 1 ? extras.trickplay.first?.value : nil)
        // Highest resolution the server generated; the decode caps the sheet
        // size anyway, so a big one costs quality, not memory.
        guard let info = byWidth?.values.max(by: { $0.width < $1.width }),
              info.width > 0, info.height > 0,
              info.tileWidth > 0, info.tileHeight > 0,
              info.thumbnailCount > 0, info.interval > 0 else { return nil }

        let perSheet = info.tileWidth * info.tileHeight
        let sheetCount = (info.thumbnailCount + perSheet - 1) / perSheet
        let urls = (0..<sheetCount).compactMap { index in
            trickplaySheetURL(itemId: itemId, width: info.width, index: index)
        }
        guard urls.count == sheetCount else { return nil }

        return TrickplaySource(
            sheetURLs: urls,
            tileSize: CGSize(width: info.width, height: info.height),
            columns: info.tileWidth,
            rows: info.tileHeight,
            interval: Double(info.interval) / 1000,
            thumbnailCount: info.thumbnailCount,
            authorization: mediaRequestAuthorization()
        )
    }

    /// Unlike `Items/…/Images/…`, the trickplay route is authenticated — it
    /// 401s without credentials. Like every other media URL Lagoon builds,
    /// this one carries no query token; the credential travels as a header
    /// instead.
    private func trickplaySheetURL(itemId: String, width: Int, index: Int) -> URL? {
        guard accessToken != nil else { return nil }
        return try? url(path: "Videos/\(itemId)/Trickplay/\(width)/\(index).jpg")
    }

    func reportPlaybackStart(_ info: PlaybackStartInfo) async throws {
        try await postVoid("Sessions/Playing", body: info)
    }

    func reportPlaybackProgress(_ info: PlaybackProgressInfo) async throws {
        try await postVoid("Sessions/Playing/Progress", body: info)
    }

    func reportPlaybackStopped(_ info: PlaybackStopInfo) async throws {
        try await postVoid("Sessions/Playing/Stopped", body: info)
    }
}

// MARK: - Media segments

extension JellyfinClient {
    private nonisolated struct MediaSegmentsPage: Decodable {
        struct Entry: Decodable {
            let id: String
            let type: String
            let startTicks: Int64
            let endTicks: Int64

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                id = (try? c.decode(String.self, forKey: "id")) ?? UUID().uuidString
                type = (try? c.decode(String.self, forKey: "type")) ?? ""
                startTicks = (try? c.decode(Int64.self, forKey: "startTicks")) ?? 0
                endTicks = (try? c.decode(Int64.self, forKey: "endTicks")) ?? 0
            }
        }

        let items: [Entry]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            items = (try? c.decodeIfPresent([Entry].self, forKey: "items")) ?? []
        }
    }

    /// Intro/recap/credit ranges, or an empty list when the server has none.
    ///
    /// Native to Jellyfin 10.10+, so no plugin-specific client code is
    /// needed even though a plugin is what populates it. Never throws —
    /// like chapters and trickplay this is garnish, and an older server
    /// simply goes without.
    ///
    /// The endpoint takes an optional `includeSegmentTypes`, deliberately
    /// unused here: it wants *repeated* query params and 400s on a
    /// comma-joined list, and filtering client-side costs nothing at these
    /// sizes.
    func mediaSegments(itemId: String) async -> [MediaSegment] {
        // 10.10+ only; an older server's 404 is an answer, not a fault.
        let page: MediaSegmentsPage? = try? await get("MediaSegments/\(itemId)", probe: true)
        return (page?.items ?? [])
            .map {
                MediaSegment(
                    id: $0.id,
                    kind: MediaSegment.Kind(rawValue: $0.type) ?? .other,
                    start: Ticks.seconds($0.startTicks),
                    end: Ticks.seconds($0.endTicks)
                )
            }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
    }
}
