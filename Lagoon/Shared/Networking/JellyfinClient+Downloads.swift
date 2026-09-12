import Foundation

// URLs for taking a title off the server (HEL-166). Both carry no credential;
// the caller attaches `mediaRequestAuthorization()` as a header exactly as
// every other media consumer does.
extension JellyfinClient {
    /// The original file, through the route the server gates on the user's
    /// "Allow media downloading" policy and records in its activity log.
    func downloadURL(itemId: String) throws -> URL {
        try url(path: "Items/\(itemId)/Download")
    }

    /// The server's progressive transcode of a title as one MPEG-TS stream:
    /// a single HTTP response ffmpeg writes as it encodes, playable while
    /// incomplete, which is what lets a background `URLSession` carry a
    /// whole transcode as one task. Bitrate and size caps bound the encode;
    /// the codec lists match the transcode rung of the device profile.
    func progressiveTranscodeURL(
        itemId: String,
        source: MediaSource,
        videoBitrate: Int,
        maxWidth: Int,
        maxHeight: Int,
        capabilities: PlaybackCapabilities = .current
    ) throws -> URL {
        // The file is decoded by this device alone, so the codec follows its
        // hardware: HEVC keeps HDR where a decoder exists, and a device
        // without one (the simulator, older iPads) asks for H.264 rather
        // than downloading a file VideoToolbox then refuses (-12906).
        let videoCodec = capabilities.hardwareHEVC ? "hevc,h264" : "h264"
        return try url(path: "Videos/\(itemId)/stream.ts", query: [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "mediaSourceId", value: source.id),
            URLQueryItem(name: "deviceId", value: deviceId),
            // A fresh session id per request: the server keys transcode jobs
            // on it, and without one a restart is handed whatever output an
            // abandoned earlier job left behind.
            URLQueryItem(name: "playSessionId", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "videoCodec", value: videoCodec),
            URLQueryItem(name: "audioCodec", value: "eac3,aac"),
            URLQueryItem(name: "videoBitRate", value: String(videoBitrate)),
            URLQueryItem(name: "audioBitRate", value: "256000"),
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "maxAudioChannels", value: "6"),
            URLQueryItem(name: "transcodingMaxAudioChannels", value: "6"),
            // The caps are the point: a stream copy of a 4K source would
            // hand back the original bitrate.
            URLQueryItem(name: "enableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "allowVideoStreamCopy", value: "false"),
        ])
    }
}
