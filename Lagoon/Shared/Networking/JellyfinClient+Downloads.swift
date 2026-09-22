import Foundation
import LagoonEngine

// Download URLs. No credential in the URL; the caller sends
// `mediaRequestAuthorization()` as a header.
extension JellyfinClient {
    /// The original file, via the route gated by "Allow media downloading".
    func downloadURL(itemId: String) throws -> URL {
        try url(path: "Items/\(itemId)/Download")
    }

    /// A progressive MPEG-TS transcode: one HTTP response, so a background
    /// `URLSession` carries it as one task.
    func progressiveTranscodeURL(
        itemId: String,
        source: MediaSource,
        videoBitrate: Int,
        maxWidth: Int,
        maxHeight: Int,
        capabilities: PlaybackCapabilities = .current
    ) throws -> URL {
        // Only this device decodes the file: without hardware HEVC
        // (simulator, older iPads) VideoToolbox refuses it (-12906).
        let videoCodec = capabilities.hardwareHEVC ? "hevc,h264" : "h264"
        return try url(path: "Videos/\(itemId)/stream.ts", query: [
            URLQueryItem(name: "static", value: "false"),
            URLQueryItem(name: "mediaSourceId", value: source.id),
            URLQueryItem(name: "deviceId", value: deviceId),
            // Fresh per request, or a restart gets an abandoned job's output.
            URLQueryItem(name: "playSessionId", value: UUID().uuidString.lowercased()),
            URLQueryItem(name: "videoCodec", value: videoCodec),
            URLQueryItem(name: "audioCodec", value: "eac3,aac"),
            URLQueryItem(name: "videoBitRate", value: String(videoBitrate)),
            URLQueryItem(name: "audioBitRate", value: "256000"),
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "maxAudioChannels", value: "6"),
            URLQueryItem(name: "transcodingMaxAudioChannels", value: "6"),
            // A stream copy would ignore the caps and keep the source bitrate.
            URLQueryItem(name: "enableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "allowVideoStreamCopy", value: "false"),
        ])
    }
}
