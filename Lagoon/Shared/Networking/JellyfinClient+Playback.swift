import CoreGraphics
import Foundation
import LagoonEngine

// Stream resolution and progress reporting.
extension JellyfinClient {
    nonisolated struct PlaybackInfoRequest: Encodable {
        let deviceProfile: DeviceProfile.Profile
        let autoOpenLiveStream: Bool
        let maxStreamingBitrate: Int
        /// Jellyfin defaults these to true. Sent explicitly so each ladder
        /// rung can withdraw them.
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

    /// Negotiates a stream. `.negotiated` lets the server pick freely; lower
    /// rungs withdraw permissions after a failure, forcing a remux, then a
    /// re-encode.
    func playbackInfo(
        itemId: String,
        delivery: PlaybackDelivery = .negotiated
    ) async throws -> PlaybackInfoResponse {
        let userId = try requireUserId()
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
        // Direct stream: playable bytes served through the server (.strm,
        // static-bitrate limits). The container can be an ffprobe list
        // ("mov,mp4,m4a"); use the first.
        if source.supportsDirectStream == true, accessToken != nil,
           let container = source.container?.split(separator: ",").first {
            return (
                try url(path: "Videos/\(itemId)/stream.\(container)", query: staticStreamQuery(source: source)),
                .directStream
            )
        }
        if let transcodingUrl = source.transcodingUrl, serverURL != nil {
            guard let resolvedURL = serverRelativeURL(transcodingUrl) else {
                throw JellyfinError.unplayable
            }
            // Strip a server-stamped api_key/ApiKey; the header carries the
            // credential. Cross-origin URLs are left alone.
            let url = mediaRequestAuthorization()?.sanitizedURL(resolvedURL) ?? resolvedURL
            return (url, .transcode)
        }
        throw JellyfinError.unplayable
    }

    /// An external subtitle's DeliveryUrl as a fetchable absolute URL.
    func externalSubtitleURL(deliveryUrl: String?) -> URL? {
        guard let deliveryUrl, serverURL != nil, accessToken != nil,
              let url = serverRelativeURL(deliveryUrl) else { return nil }
        return mediaRequestAuthorization()?.sanitizedURL(url) ?? url
    }

    // MARK: - Remote subtitles

    /// Searches the server's subtitle providers. `language` is an ISO code;
    /// results keep provider ranking.
    func searchRemoteSubtitles(itemId: String, language: String) async throws -> [RemoteSubtitleInfo] {
        try await get(
            ["Items", itemId, "RemoteSearch", "Subtitles", language],
            timeout: SubtitleRequestTimeout.provider
        )
    }

    /// Asks Jellyfin to download and attach a result. Refresh PlaybackInfo
    /// afterwards for the real stream index and URL.
    func downloadRemoteSubtitle(itemId: String, subtitleId: String) async throws {
        try await postVoid(
            ["Items", itemId, "RemoteSearch", "Subtitles", subtitleId],
            timeout: SubtitleRequestTimeout.provider
        )
    }

    /// Fetches the provider file directly: a fallback for servers that
    /// accept the save but do not expose the new sidecar in time.
    func remoteSubtitleFile(subtitleId: String) async throws -> (url: URL, data: Data) {
        guard accessToken != nil else { throw JellyfinError.notConfigured }
        let components = ["Providers", "Subtitles", "Subtitles", subtitleId]
        // Identity only; the bytes come from `getData`, so no credential.
        let deliveryURL = try url(pathComponents: components)
        return (
            deliveryURL,
            try await getData(components, timeout: SubtitleRequestTimeout.provider, maximumBytes: DownloadLimit.subtitle)
        )
    }

    /// Uploads provider bytes already fetched. Avoids a second provider
    /// request, and Jellyfin 10.11's remote download, which can return 204
    /// after failing to save.
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

    // No URL Lagoon builds carries the token: media consumers send it as a
    // header via `MediaRequestAuthorization`, because CFNetwork logs failed
    // URLs. `sanitizedURL(_:)` strips `api_key`/`ApiKey` from server URLs on
    // the Jellyfin origin.

    // MARK: - Transport extras

    /// Chapters and trickplay geometry, as the item endpoint reports them.
    nonisolated struct PlaybackExtras: Decodable {
        let chapters: [ChapterInfo]
        let originalLanguage: String?
        /// Media source id, then width. Dictionary keys arrive verbatim; the
        /// key strategy only converts `CodingKey`s.
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

    /// Fetched separately: neither `playbackInfo` nor rail items carry these.
    /// Never throws; playback goes on without them.
    func playbackExtras(itemId: String) async -> PlaybackExtras {
        guard let userId else { return .none }
        return (try? await get("Users/\(userId)/Items/\(itemId)")) ?? .none
    }

    /// Trickplay tiles for a media source, or nil when there are none.
    func trickplaySource(itemId: String, mediaSourceId: String, extras: PlaybackExtras) -> TrickplaySource? {
        // Fall back to the only entry: transcodes report a different
        // source id than the tiles were made from.
        let byWidth = extras.trickplay.first { $0.key.caseInsensitiveCompare(mediaSourceId) == .orderedSame }?.value
            ?? (extras.trickplay.count == 1 ? extras.trickplay.first?.value : nil)
        // Highest resolution; the decode caps sheet size, so no memory cost.
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

    /// Authenticated route (401 without credentials); the header carries
    /// the token, never the URL.
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

    /// Intro/recap/credit ranges (Jellyfin 10.10+), empty when none. Never
    /// throws. `includeSegmentTypes` is unused: it 400s on a comma-joined
    /// list, and filtering here is free.
    func mediaSegments(itemId: String) async -> [MediaSegment] {
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
