import Foundation
import LagoonEngine

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

/// One descent of the ladder, for the playback HUD. The message is kept
/// apart because it can be long enough to need its own line.
nonisolated struct PlaybackDeliveryFallbackRecord: Equatable {
    /// `negotiated→transcode · undecodable`
    let transition: String
    /// The engine's own account of what failed.
    let message: String
}

/// What the server holds, as far as the delivery ladder cares.
///
/// For a disc, Jellyfin says `VideoType` `Iso` but still reports
/// `SupportsDirectPlay` true and a `Container` probed inside the disc. The
/// static stream then serves the raw image or folder, which libavformat
/// cannot open.
nonisolated enum PlaybackSourceLayout: Equatable {
    /// One file, whose served bytes are the bytes to demux.
    case file
    /// A Blu-ray image Lagoon reads itself: UDF over the byte-range
    /// transport, playing the main title's clips.
    case blurayImage
    /// A DVD image, read by the same UDF reader. A title is its VOB files in
    /// order.
    case dvdImage
    /// An image the server did not type, which is not assumed to be readable.
    case discImage
    /// A rip on the server's filesystem: `VideoType` `BluRay` or `Dvd`.
    case discFolder

    init(videoType: String?, isoType: String?) {
        switch videoType?.lowercased() {
        case "iso":
            // Named kinds only, so an unreadable image goes to the server at
            // once.
            switch isoType?.lowercased() {
            case "bluray": self = .blurayImage
            case "dvd": self = .dvdImage
            default: self = .discImage
            }
        case "bluray", "dvd":
            self = .discFolder
        // Unknown stays a file: a failed open costs one attempt, a wrong
        // disc guess costs a server transcode.
        default:
            self = .file
        }
    }

    var isDisc: Bool { self != .file }

    /// Whether Lagoon opens this itself.
    var isReadableDisc: Bool {
        self == .blurayImage || self == .dvdImage
    }

    /// Why direct play is not worth attempting, for the HUD. Nil when it is.
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
/// Descend one rung at a time, and only on the engine's verdict: a transcode
/// is minutes of server CPU per viewer. Both lower rungs arrive as HLS and
/// lose the embedded subtitle tracks. A `.delivery` verdict never skips to
/// the re-encode.
nonisolated enum PlaybackFallbackPolicy {
    /// The best rung to try before anything has failed. Sources Lagoon
    /// cannot open start at `.remux` rather than spend a doomed open.
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
            // A remux hands the decoder the same samples, so skip it. This
            // is one-way: never reach it without a verdict on the samples.
            .transcode
        case (.remux, _):
            .transcode
        case (.transcode, _):
            nil
        }
    }
}

