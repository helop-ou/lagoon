import Foundation
import LagoonEngine

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

/// Dolby Vision outside Dolby's spec, which Jellyfin calls `DOVIInvalid`:
/// profile 8.6, or colour tags that disagree with the profile. The device
/// profile accepts it because no condition can see the transfer, so direct
/// play is refused here unless the base layer is PQ, as Jellyfin's own
/// `IsDoviWithHdr10Bl` reads it.
nonisolated enum DolbyVisionBaseLayer {
    /// Why the server's direct play is not worth attempting, for the HUD.
    /// Nil when it is, or when the server offered none.
    static func directPlayRefusal(for source: MediaSource) -> (cause: String, message: String)? {
        guard source.supportsDirectPlay == true,
              let video = source.videoStream,
              video.videoRangeType == "DOVIInvalid",
              video.colorTransfer?.lowercased() != "smpte2084" else { return nil }
        return ("dolby vision", "This Dolby Vision stream is outside Dolby's spec and has no HDR10 base layer.")
    }
}

/// A read failure no other rung can fix. Remux and transcode come from the
/// same server with the same credential over the same network, so a refused
/// sign-in, a missing file, an untrusted certificate or a lost network fails
/// them all, and the viewer would wait through three failures for the same
/// answer.
nonisolated enum PlaybackSourceRefusal: Equatable {
    case signedOut
    case forbidden
    case missing
    case untrustedCertificate
    case offline
    case unreachable

    /// Nil for anything a lower rung might still get past, a 5xx or a
    /// dropped connection included.
    init?(_ transport: PlaybackTransportFailure?) {
        switch transport {
        case .httpStatus(401): self = .signedOut
        case .httpStatus(403): self = .forbidden
        case .httpStatus(404), .httpStatus(410): self = .missing
        case .urlError(let code) where Self.certificateErrors.contains(code): self = .untrustedCertificate
        case .urlError(let code) where Self.offlineErrors.contains(code): self = .offline
        case .urlError(let code) where Self.unreachableErrors.contains(code): self = .unreachable
        default: return nil
        }
    }

    var message: String {
        switch self {
        case .signedOut: "The server no longer accepts this sign-in. Sign in again and try once more."
        case .forbidden: "The server refused to play this item for this account."
        case .missing: "The server could not find this item's file."
        case .untrustedCertificate: "The server's certificate isn't trusted, so the video could not load."
        case .offline: "You're offline. Connect to the internet and try again."
        case .unreachable: "The server can't be reached. Check that it's running and try again."
        }
    }

    /// `NSURLErrorServerCertificate…` and `NSURLErrorSecureConnectionFailed`,
    /// `NSURLErrorClientCertificate…`.
    private static let certificateErrors: Set<Int> = [-1200, -1201, -1202, -1203, -1204, -1205, -1206]
    /// Not connected, roaming off, data not allowed.
    private static let offlineErrors: Set<Int> = [-1009, -1018, -1020]
    /// Cannot find or connect to the host.
    private static let unreachableErrors: Set<Int> = [-1003, -1004]
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

    /// The rung to start on instead when the server's offer for `source`
    /// is not worth attempting, and why. Nil when it is.
    static func refusal(
        of source: MediaSource
    ) -> (rung: PlaybackDelivery, refusal: (cause: String, message: String))? {
        let layout = PlaybackSourceLayout(videoType: source.videoType, isoType: source.isoType)
        if let refusal = layout.directPlayRefusal {
            return (start(for: layout), refusal)
        }
        if let refusal = DolbyVisionBaseLayer.directPlayRefusal(for: source) {
            return (.remux, refusal)
        }
        return nil
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

