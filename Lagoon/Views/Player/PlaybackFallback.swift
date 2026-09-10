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

/// One descent of the ladder, kept for the playback HUD.
///
/// Two pieces rather than one string because the message is the only
/// unbounded part: a VideoToolbox status can run long enough to wrap the
/// overlay, so the HUD gives it a line of its own.
nonisolated struct PlaybackDeliveryFallbackRecord: Equatable {
    /// `negotiated→transcode · undecodable`
    let transition: String
    /// The engine's own account of what failed.
    let message: String
}

/// What the server is holding, as far as the delivery ladder cares.
///
/// A disc is the case Jellyfin describes accurately and then contradicts:
/// `VideoType` says `Iso`, `Container` reports the format probed *inside*
/// the disc (`ts` for a Blu-ray), and `SupportsDirectPlay` still comes back
/// true. What the static stream then serves is the image or the folder
/// itself — 64 GB of UDF for an image — and libavformat has no filesystem to
/// walk it with, so the open fails with `invalid data` every time (HEL-133).
nonisolated enum PlaybackSourceLayout: Equatable {
    /// One file, whose served bytes are the bytes to demux.
    case file
    /// A Blu-ray image, which Lagoon reads itself: it mounts the UDF
    /// filesystem over the same byte-range transport everything else uses and
    /// plays the main title's clips directly (HEL-133).
    case blurayImage
    /// A DVD image, read here as well: the same UDF reader mounts it, and
    /// `VIDEO_TS` needs no playlist because a title is simply its VOB files
    /// in order. Interlaced ones are deinterlaced on the way out (HEL-127).
    case dvdImage
    /// An image the server did not type, which is not assumed to be readable.
    case discImage
    /// A rip on the server's filesystem: `VideoType` `BluRay` or `Dvd`.
    case discFolder

    init(videoType: String?, isoType: String?) {
        switch videoType?.lowercased() {
        case "iso":
            // Named kinds only. An image the reader would decline is better
            // sent to the server at once than discovered a rung later.
            switch isoType?.lowercased() {
            case "bluray": self = .blurayImage
            case "dvd": self = .dvdImage
            default: self = .discImage
            }
        case "bluray", "dvd":
            self = .discFolder
        // An unrecognised value stays a file. The ladder already recovers
        // from an open that fails, which costs one attempt; assuming a disc
        // would silently spend a server transcode on something that might
        // have played perfectly.
        default:
            self = .file
        }
    }

    var isDisc: Bool { self != .file }

    /// Whether Lagoon opens this one itself rather than asking the server to
    /// rebuild it.
    var isReadableDisc: Bool {
        self == .blurayImage || self == .dvdImage
    }

    /// Why direct play is not worth attempting, for the playback HUD — nil
    /// for a file, and nil for the one kind of disc this client can open.
    var directPlayRefusal: (cause: String, message: String)? {
        switch self {
        case .file, .blurayImage, .dvdImage:
            nil
        case .discImage:
            ("disc image", "The server did not say what kind of disc this image holds.")
        case .discFolder:
            ("disc rip", "A disc rip is served as its folder, which has no single stream to open.")
        }
    }
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
    /// The best rung a source can be *tried* at, before anything has failed.
    /// A file plays from the bytes the negotiated rung serves, and so do the
    /// disc images Lagoon can now read. Anything else has to be rebuilt by
    /// the server, and starting above that spends an open which cannot
    /// succeed plus a second negotiation to learn what `VideoType` already
    /// said (HEL-133).
    static func start(for layout: PlaybackSourceLayout) -> PlaybackDelivery {
        switch layout {
        case .file, .blurayImage, .dvdImage: .negotiated
        case .discImage, .discFolder: .remux
        }
    }

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

/// Whether a video decode failure is a verdict on the stream or only on the
/// point playback was restarted from (HEL-151).
///
/// The ladder's `.undecodable` rung is expensive and one-way: it costs the
/// viewer three seconds of reload, the embedded subtitle tracks, and the
/// server minutes of CPU per viewer. It should answer "this device cannot
/// decode this bitstream", and a decode failure a few samples after a
/// renderer flush usually is not that — it is the decoder refusing where the
/// seek put it, on a stream whose every other second decodes perfectly. One
/// in-place retry (flush, re-seek to the same position) separates the two,
/// and costs a scrub a hiccup instead of a restart.
///
/// Bounded on purpose. Only one retry is allowed per playback generation, so
/// a stream that really is undecodable descends the ladder on its second
/// failure, exactly as it did before, one seek later.
nonisolated enum PlaybackRestartPointPolicy {
    /// How close to the flush a failure has to be. An open GOP's leading
    /// pictures arrive immediately behind the picture the seek landed on;
    /// three samples covers a B-pyramid's worth and nothing beyond it.
    static let samplesAfterFlush = 3

    static func shouldRetryInPlace(
        videoSamplesSinceFlush: Int,
        alreadyRetriedThisGeneration: Bool
    ) -> Bool {
        guard !alreadyRetriedThisGeneration else { return false }
        return videoSamplesSinceFlush <= samplesAfterFlush
    }
}
