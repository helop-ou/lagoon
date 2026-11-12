import Foundation
import Observation

/// What the viewer is told when the server converts what plays. Pure, so a
/// test can walk every branch. A remux copies the picture and sound, so it
/// says nothing (docs/playback.md).
nonisolated enum PlaybackTranscodeNotice: Equatable, Sendable {
    /// A bitrate cap made the server convert a file this device plays as it
    /// is. The viewer may play the original instead.
    case capped(PlaybackOffer.Cap, probedBitsPerSecond: Int?, maxBitrate: Int)
    /// Converted for a reason playing the original would not get past.
    case converting(Reason)

    enum Reason: Equatable, Sendable {
        case video
        case audio
        case subtitles
        /// Above the device's own envelope, with no cap set.
        case bitrate
        /// A cap in a Watch Together group, where a restart is the group's.
        case qualityLimit
        /// The engine could not play the file, and the ladder reached the
        /// re-encode.
        case playbackProblem
        case other
    }

    static let bitrateReasons: Set<String> = [
        "ContainerBitrateExceedsLimit", "VideoBitrateNotSupported", "AudioBitrateNotSupported",
    ]
    /// A container rewrite keeps the picture and sound as they are.
    static let remuxReasons: Set<String> = ["ContainerNotSupported"]

    static func notice(
        method: PlayMethod,
        delivery: PlaybackDelivery,
        offer: PlaybackOffer?,
        transcodeReasons: [String],
        isDownload: Bool,
        isInGroup: Bool
    ) -> PlaybackTranscodeNotice? {
        guard !isDownload, method == .transcode else { return nil }
        // The rung only a failure reaches: the video is re-encoded because
        // the original would not play here.
        if delivery == .transcode { return .converting(.playbackProblem) }
        let reasons = Set(transcodeReasons).subtracting(remuxReasons)
        guard !reasons.isEmpty else { return nil }
        guard reasons.isSubset(of: bitrateReasons) else { return .converting(reason(for: reasons)) }
        guard let offer else { return .converting(.bitrate) }
        switch offer.cap {
        case .auto, .setting, .metered:
            guard !isInGroup else { return .converting(.qualityLimit) }
            return .capped(offer.cap, probedBitsPerSecond: offer.probedBitsPerSecond, maxBitrate: offer.maxStreamingBitrate)
        case .lowered:
            // The viewer asked for less after stalls.
            return nil
        case .none:
            return .converting(.bitrate)
        }
    }

    /// The picture outranks the sound, and both outrank subtitles.
    private static func reason(for reasons: Set<String>) -> Reason {
        if reasons.contains(where: isVideoReason) { return .video }
        if reasons.contains(where: isAudioReason) { return .audio }
        if reasons.contains("SubtitleCodecNotSupported") { return .subtitles }
        return .other
    }

    private static func isVideoReason(_ reason: String) -> Bool {
        (reason.hasPrefix("Video") && !bitrateReasons.contains(reason))
            || ["RefFramesNotSupported", "AnamorphicVideoNotSupported", "InterlacedVideoNotSupported",
                "UnknownVideoStreamInfo"].contains(reason)
    }

    private static func isAudioReason(_ reason: String) -> Bool {
        (reason.hasPrefix("Audio") && !bitrateReasons.contains(reason))
            || ["SecondaryAudioNotSupported", "UnknownAudioStreamInfo"].contains(reason)
    }

    /// The `TranscodeReasons` query item, in order, without repeats.
    static func reasons(in transcodingURL: String?) -> [String] {
        guard let transcodingURL,
              let value = URLComponents(string: transcodingURL)?.queryItems?
                .first(where: { $0.name == "TranscodeReasons" })?.value else { return [] }
        var seen = Set<String>()
        return value.split(separator: ",").map(String.init).filter { seen.insert($0).inserted }
    }

    var offersOriginal: Bool {
        if case .capped = self { true } else { false }
    }
}

/// The notice as the player draws it. The controller decides when it is up
/// and what playing the original does.
@Observable
@MainActor
final class PlaybackTranscodeNoticePrompt {
    /// An offer stays as long as the lower-quality one. Information goes
    /// sooner: there is nothing to answer.
    static let offerVisibleSeconds: Double = PlaybackQualityOffer.visibleSeconds
    static let informationVisibleSeconds: Double = 8

    private(set) var notice: PlaybackTranscodeNotice?

    var isVisible: Bool { notice != nil }

    @ObservationIgnored var onPlayOriginal: (() -> Void)?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func present(_ notice: PlaybackTranscodeNotice) {
        self.notice = notice
        expiry?.cancel()
        let seconds = notice.offersOriginal ? Self.offerVisibleSeconds : Self.informationVisibleSeconds
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.withdraw()
        }
    }

    /// Select, or a tap on Play Original. Only an offer has one.
    func playOriginal() {
        guard notice?.offersOriginal == true else { return }
        withdraw()
        onPlayOriginal?()
    }

    /// Back, Keep or the close button. False when there was nothing to
    /// dismiss, so Back can go on to its next meaning.
    @discardableResult
    func dismiss() -> Bool {
        guard isVisible else { return false }
        withdraw()
        return true
    }

    func withdraw() {
        expiry?.cancel()
        expiry = nil
        notice = nil
    }
}
