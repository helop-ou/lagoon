import Foundation

// Stream resolution and progress reporting.
extension JellyfinClient {
    nonisolated struct PlaybackInfoRequest: Encodable {
        let deviceProfile: DeviceProfile.Profile
        let autoOpenLiveStream: Bool
        let maxStreamingBitrate: Int
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

    func playbackInfo(itemId: String) async throws -> PlaybackInfoResponse {
        let userId = try requireUserId()
        let profile = DeviceProfile.current
        return try await post(
            "Items/\(itemId)/PlaybackInfo",
            query: [URLQueryItem(name: "UserId", value: userId)],
            body: PlaybackInfoRequest(
                deviceProfile: profile,
                autoOpenLiveStream: true,
                maxStreamingBitrate: profile.maxStreamingBitrate
            )
        )
    }

    /// Resolves a media source to a playable URL, preferring direct play,
    /// then direct stream, then the server-negotiated transcode.
    func streamURL(itemId: String, source: MediaSource) throws -> (url: URL, method: PlayMethod) {
        if source.supportsDirectPlay == true, let accessToken {
            return (
                try url(path: "Videos/\(itemId)/stream", query: staticStreamQuery(source: source, accessToken: accessToken)),
                .directPlay
            )
        }
        // Direct stream: the bytes are playable as-is but must be served
        // through the server (remote/.strm sources, static-bitrate limits).
        // jellyfin-web requests stream.{container} with static=true here;
        // the container can arrive as an ffprobe list ("mov,mp4,m4a").
        if source.supportsDirectStream == true, let accessToken,
           let container = source.container?.split(separator: ",").first {
            return (
                try url(path: "Videos/\(itemId)/stream.\(container)", query: staticStreamQuery(source: source, accessToken: accessToken)),
                .directStream
            )
        }
        if let transcodingUrl = source.transcodingUrl, let serverURL {
            // TranscodingUrl arrives server-relative, query string included.
            guard let url = URL(string: transcodingUrl, relativeTo: serverURL)?.absoluteURL else {
                throw JellyfinError.unplayable
            }
            return (url, .transcode)
        }
        throw JellyfinError.unplayable
    }

    private func staticStreamQuery(source: MediaSource, accessToken: String) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: source.id),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "api_key", value: accessToken),
        ]
        if let eTag = source.eTag {
            query.append(URLQueryItem(name: "Tag", value: eTag))
        }
        return query
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
