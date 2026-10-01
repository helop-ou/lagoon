import Foundation

/// How the server is asked to deliver a stream. Each rung costs the server
/// more, so descend only as far as a failure forces.
nonisolated enum PlaybackDelivery: String, Equatable, CaseIterable {
    /// Whatever the server picks unaided: direct play for anything inside
    /// `DeviceProfile.lagoon`.
    case negotiated
    /// Direct play refused, but the server may still copy the tracks.
    ///
    /// Not `SupportsDirectStream`: Jellyfin turns that off with direct play.
    /// The remux happens inside the returned `TranscodingUrl`, which wraps
    /// the existing bitstream in fMP4 with no encoder time. Rescues a file
    /// whose container libavformat choked on.
    case remux
    /// Video re-encoded. Minutes of server CPU per viewer, and the only rung
    /// that rescues a bitstream the engine cannot decode. Differs from
    /// `.remux` only by `allowVideoStreamCopy=false`.
    case transcode

    /// The PlaybackInfo flags for this rung. Jellyfin defaults all four to
    /// true.
    var flags: PlaybackDeliveryFlags {
        switch self {
        case .negotiated:
            PlaybackDeliveryFlags(
                enableDirectPlay: true,
                enableDirectStream: true,
                allowVideoStreamCopy: true,
                allowAudioStreamCopy: true
            )
        case .remux:
            PlaybackDeliveryFlags(
                enableDirectPlay: false,
                enableDirectStream: true,
                allowVideoStreamCopy: true,
                allowAudioStreamCopy: true
            )
        case .transcode:
            // Without this the server may copy the bitstream that failed.
            // Audio copy stays: the demuxer drops undecodable audio tracks,
            // so audio never causes this rung.
            PlaybackDeliveryFlags(
                enableDirectPlay: false,
                enableDirectStream: false,
                allowVideoStreamCopy: false,
                allowAudioStreamCopy: true
            )
        }
    }
}

nonisolated struct PlaybackDeliveryFlags: Equatable {
    let enableDirectPlay: Bool
    let enableDirectStream: Bool
    let allowVideoStreamCopy: Bool
    let allowAudioStreamCopy: Bool
}
