import Foundation

/// Why playback stopped, in the only terms the fallback ladder cares about.
///
/// The distinction is not severity. It is whether *redelivering the same
/// samples* could help: a container libavformat could not open may play
/// perfectly once the server has rewritten it, while a bitstream the
/// decoders refuse will refuse just as firmly inside a new container.
nonisolated struct PlaybackEngineFailure: Equatable {
    enum Cause: Equatable {
        /// The samples themselves cannot be decoded here — a codec outside
        /// the envelope, a decoder session the hardware declined, a decode
        /// that failed. Only a re-encode changes what the decoder is given.
        case undecodable
        /// The container, the transport, or an AVFoundation object failed.
        /// The same media may well play when it arrives another way.
        case delivery
    }

    let cause: Cause
    /// What the viewer is told if the ladder runs out of rungs.
    let message: String

    init(cause: Cause, message: String) {
        self.cause = cause
        self.message = message
    }
}

/// How the server is being asked to deliver a stream. Each rung costs the
/// server more than the one above it, so the ladder is descended only as far
/// as a failure actually forces.
nonisolated enum PlaybackDelivery: String, Equatable, CaseIterable {
    /// Whatever the server picks unaided, which for anything inside
    /// `DeviceProfile.lagoon` is direct play: the original file, no server
    /// work at all.
    case negotiated
    /// Direct play refused, but the server may still copy the tracks rather
    /// than re-encode them.
    ///
    /// Not `SupportsDirectStream`: Jellyfin couples the two, and withdrawing
    /// direct play turns direct stream off with it (verified against 10.11 —
    /// both come back false). What comes back instead is a `TranscodingUrl`,
    /// and the remux happens inside it: with video stream copy still
    /// permitted the server wraps the existing bitstream in fMP4 segments
    /// and spends no encoder time. This is the rung that rescues a file
    /// whose container libavformat choked on.
    case remux
    /// Stream copy refused as well, so the video has to be re-encoded. The
    /// expensive rung — minutes of server CPU per viewer — and the only one
    /// that can rescue a bitstream the engine cannot decode.
    ///
    /// Its `TranscodingUrl` differs from the rung above by exactly one
    /// parameter, `allowVideoStreamCopy=false`. That single flag is the
    /// whole distinction between a remux and a transcode, which is why the
    /// two rungs are worth keeping apart.
    case transcode

    /// The PlaybackInfo flags this rung asks for. Jellyfin defaults all four
    /// to true, so `.negotiated` sends exactly what the server would have
    /// assumed on its own.
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
            // Video stream copy has to go too, or the server may satisfy a
            // transcode request by copying the very bitstream that failed.
            // Audio copy stays: an audio track the engine cannot decode
            // never reaches this code — the demuxer drops undecodable audio
            // streams from the track list rather than failing playback — so
            // re-encoding audio here would be server cost for nothing.
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

/// Which rung to try after a failure, or nil when the ladder is spent.
///
/// Descending one rung at a time is deliberate: a transcode is minutes of
/// server CPU per viewer and the reason most of this client exists is to
/// avoid asking for one. The ladder only skips to the bottom when the rung
/// in between provably cannot help.
///
/// Both lower rungs arrive as HLS, which costs the embedded subtitle track:
/// the engine cannot demux subtitles out of a Jellyfin transcode. One more
/// reason the ladder is only ever descended after a real failure.
nonisolated enum PlaybackFallbackPolicy {
    static func next(
        after delivery: PlaybackDelivery,
        cause: PlaybackEngineFailure.Cause
    ) -> PlaybackDelivery? {
        switch (delivery, cause) {
        case (.negotiated, .delivery):
            .remux
        case (.negotiated, .undecodable):
            // A remux hands the decoder the same samples in a different
            // wrapper. Whatever refused them will refuse them again, so
            // spending a server remux to prove it is pure latency.
            .transcode
        case (.remux, _):
            .transcode
        case (.transcode, _):
            nil
        }
    }
}
