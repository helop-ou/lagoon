import AVFAudio
import Foundation
import Libmpv
import QuartzCore

/// libmpv playback engine for containers/codecs AVPlayer can't open (HEL-45):
/// true MKV direct play with DTS/TrueHD decoded to multichannel LPCM.
///
/// Threading model (mirrors the MPVKit demo): commands and property writes
/// happen on the main actor — libmpv is thread-safe — while the wakeup
/// callback fires on an arbitrary mpv thread and events are drained on a
/// private serial queue, hopping back to the main actor for state updates.
@Observable
final class MPVPlayerEngine: PlayerEngine {
    private(set) var timePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var videoSize: CGSize?
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []

    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored nonisolated(unsafe) private var mpv: OpaquePointer?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingStartSeconds: Double = 0
    @ObservationIgnored private var initialAudioID: Int?
    @ObservationIgnored private var initialSubtitleID: Int?
    @ObservationIgnored private var attachedLayer: MetalVideoLayer?
    // Set once in prepare (before the handle exists), read from the event
    // queue when the file loads.
    @ObservationIgnored nonisolated(unsafe) private var externalSubtitles: [ExternalSubtitleTrack] = []
    // Touched only on `queue` — throttles time-pos hops to the main actor.
    @ObservationIgnored nonisolated(unsafe) private var lastDeliveredTime: Double = -1

    nonisolated private let queue = DispatchQueue(label: "ee.helop.lagoon.mpv", qos: .userInitiated)

    /// Remembers what to play; the mpv handle is only created once the
    /// Metal layer exists (`attachAndPlay`), because `wid` must be set
    /// before `mpv_initialize`. Initial track ids are mpv's per-type
    /// 1-based ids (a nil subtitle id means subtitles start off — the
    /// server already applied the user's language preferences when it
    /// picked the default stream indices).
    func prepare(
        url: URL,
        startSeconds: Double,
        initialAudioID: Int? = nil,
        initialSubtitleID: Int? = nil,
        externalSubtitles: [ExternalSubtitleTrack] = []
    ) {
        pendingURL = url
        pendingStartSeconds = startSeconds
        self.initialAudioID = initialAudioID
        self.initialSubtitleID = initialSubtitleID
        self.externalSubtitles = externalSubtitles
    }

    func attachAndPlay(layer: MetalVideoLayer) {
        guard mpv == nil, let url = pendingURL else { return }
        attachedLayer = layer

        // VideoPlayer manages the audio session for AVPlayer; mpv does not.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        guard let handle = mpv_create() else {
            onError?("The mpv engine could not be created.")
            return
        }

        #if DEBUG
        mpv_request_log_messages(handle, "warn")
        #else
        mpv_request_log_messages(handle, "no")
        #endif

        // wid carries the CAMetalLayer's address as an int64; gpu-next
        // renders into it through MoltenVK. hwdec stays VideoToolbox.
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "gpu-api", "vulkan")
        mpv_set_option_string(handle, "gpu-context", "moltenvk")
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        // Ask the display to adapt to the source's color space (HDR10 → EDR
        // on capable screens). Must be set before playback starts; cannot be
        // toggled at runtime.
        mpv_set_option_string(handle, "target-colorspace-hint", "yes")
        mpv_set_option_string(handle, "cache", "yes")
        mpv_set_option_string(handle, "keep-open", "no")
        // Initial tracks come from the server's default stream choice (the
        // user's Jellyfin language preferences), not mpv's own heuristics.
        if let initialAudioID {
            mpv_set_option_string(handle, "aid", "\(initialAudioID)")
        }
        mpv_set_option_string(handle, "sid", initialSubtitleID.map { "\($0)" } ?? "no")
        if pendingStartSeconds > 1 {
            mpv_set_option_string(handle, "start", "\(pendingStartSeconds)")
        }

        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            onError?("The mpv engine failed to initialize.")
            return
        }
        mpv = handle

        mpv_observe_property(handle, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(handle, { ctx in
            guard let ctx else { return }
            Unmanaged<MPVPlayerEngine>.fromOpaque(ctx).takeUnretainedValue().wake()
        }, Unmanaged.passUnretained(self).toOpaque())

        command("loadfile", args: [url.absoluteString, "replace"])
    }

    // MARK: - Transport

    func togglePause() {
        setFlag("pause", !isPaused)
    }

    func seek(by seconds: Double) {
        command("seek", args: ["\(seconds)", "relative+exact"])
    }

    // Track switching is instant and fully client-side: every embedded MKV
    // track is already in the demuxed file, so this is just an aid/sid flip.
    func selectAudioTrack(id: Int?) {
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "aid", id.map { "\($0)" } ?? "no")
        refreshTracks()
    }

    func selectSubtitleTrack(id: Int?) {
        guard let handle = mpv else { return }
        mpv_set_property_string(handle, "sid", id.map { "\($0)" } ?? "no")
        refreshTracks()
    }

    /// Tears the handle down; safe to call more than once. The pump exits on
    /// the nil handle and the destroy runs behind it on the same queue.
    func shutdown() {
        guard let handle = mpv else { return }
        mpv = nil
        mpv_set_wakeup_callback(handle, nil, nil)
        queue.async {
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: - Commands

    private func command(_ name: String, args: [String]) {
        guard let handle = mpv else { return }
        commandFromPump(name, args: args, on: handle)
    }

    // libmpv commands are thread-safe; this variant runs from the event
    // queue too (external subtitle side-loading on FILE_LOADED).
    nonisolated private func commandFromPump(_ name: String, args: [String], on handle: OpaquePointer) {
        var cargs: [UnsafePointer<CChar>?] = ([name] + args).map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        defer {
            for arg in cargs where arg != nil {
                free(UnsafeMutablePointer(mutating: arg))
            }
        }
        let status = mpv_command(handle, &cargs)
        if status < 0 {
            debugLog("mpv command \(name) failed: \(String(cString: mpv_error_string(status)))")
        }
    }

    private func setFlag(_ property: String, _ value: Bool) {
        guard let handle = mpv else { return }
        var flag: Int32 = value ? 1 : 0
        mpv_set_property(handle, property, MPV_FORMAT_FLAG, &flag)
    }

    // MARK: - Event pump

    nonisolated private func wake() {
        queue.async { [weak self] in
            self?.drainEvents()
        }
    }

    nonisolated private func drainEvents() {
        while let handle = mpv {
            guard let event = mpv_wait_event(handle, 0),
                  event.pointee.event_id != MPV_EVENT_NONE else { return }
            handleEvent(event, on: handle)
        }
    }

    nonisolated private func handleEvent(_ event: UnsafeMutablePointer<mpv_event>, on handle: OpaquePointer) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = UnsafePointer<mpv_event_property>(OpaquePointer(event.pointee.data))?.pointee else { return }
            handlePropertyChange(property)

        case MPV_EVENT_VIDEO_RECONFIG:
            var width: Int64 = 0
            var height: Int64 = 0
            mpv_get_property(handle, "dwidth", MPV_FORMAT_INT64, &width)
            mpv_get_property(handle, "dheight", MPV_FORMAT_INT64, &height)
            if width > 0, height > 0 {
                let size = CGSize(width: CGFloat(width), height: CGFloat(height))
                Task { @MainActor in self.videoSize = size }
            }

        case MPV_EVENT_FILE_LOADED:
            // Side-load Jellyfin's external subtitle streams — they aren't
            // in the container, so mpv can't see them on its own.
            for subtitle in externalSubtitles {
                var args = [subtitle.url.absoluteString, subtitle.select ? "select" : "auto"]
                if let title = subtitle.title {
                    args.append(title)
                    if let language = subtitle.language {
                        args.append(language)
                    }
                }
                commandFromPump("sub-add", args: args, on: handle)
            }
            refreshTracks()

        case MPV_EVENT_PLAYBACK_RESTART:
            Task { @MainActor in self.isBuffering = false }

        case MPV_EVENT_END_FILE:
            guard let end = UnsafePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data))?.pointee else { return }
            if end.reason == MPV_END_FILE_REASON_ERROR {
                let message = String(cString: mpv_error_string(end.error))
                Task { @MainActor in self.onError?("Playback failed in the mpv engine (\(message)).") }
            } else if end.reason == MPV_END_FILE_REASON_EOF {
                Task { @MainActor in self.onFinished?() }
            }

        case MPV_EVENT_LOG_MESSAGE:
            if let message = UnsafePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data))?.pointee {
                debugLog("mpv [\(String(cString: message.prefix))] \(String(cString: message.text))", terminator: "")
            }

        case MPV_EVENT_SHUTDOWN:
            mpv_terminate_destroy(handle)

        default:
            break
        }
    }

    nonisolated private func handlePropertyChange(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch name {
        case "time-pos":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            // time-pos fires constantly; only bother the main actor when the
            // displayed second would change.
            guard abs(value - lastDeliveredTime) >= 0.5 else { return }
            lastDeliveredTime = value
            Task { @MainActor in self.timePosition = value }
        case "duration":
            guard let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee else { return }
            Task { @MainActor in self.duration = value }
        case "pause":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee else { return }
            Task { @MainActor in self.isPaused = value != 0 }
        case "paused-for-cache":
            guard let value = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee else { return }
            Task { @MainActor in self.isBuffering = value != 0 }
        default:
            break
        }
    }

    nonisolated private func debugLog(_ message: String, terminator: String = "\n") {
        #if DEBUG
        print(message, terminator: terminator)
        #endif
    }

    // MARK: - Tracks

    // mpv serializes node properties as JSON when read as a string. These
    // are mpv's kebab-case keys, not Jellyfin's PascalCase — the global
    // no-CodingKeys rule doesn't apply here.
    nonisolated private struct MPVTrack: Decodable {
        let id: Int
        let type: String
        let title: String?
        let lang: String?
        let codec: String?
        let selected: Bool?
        let isDefault: Bool?
        let forced: Bool?
        let channelCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, type, title, lang, codec, selected, forced
            case isDefault = "default"
            case channelCount = "demux-channel-count"
        }
    }

    /// Reads `track-list` and republishes it as `PlayerTrack`s. Safe from
    /// the main actor and the event queue (property reads are thread-safe).
    nonisolated private func refreshTracks() {
        guard let handle = mpv, let cString = mpv_get_property_string(handle, "track-list") else { return }
        defer { mpv_free(cString) }
        guard let raw = try? JSONDecoder().decode([MPVTrack].self, from: Data(String(cString: cString).utf8)) else {
            return
        }
        let audio = raw.filter { $0.type == "audio" }.map { Self.playerTrack(from: $0, kind: .audio) }
        let subtitles = raw.filter { $0.type == "sub" }.map { Self.playerTrack(from: $0, kind: .subtitle) }
        Task { @MainActor in
            self.audioTracks = audio
            self.subtitleTracks = subtitles
        }
    }

    nonisolated private static func playerTrack(from track: MPVTrack, kind: PlayerTrack.Kind) -> PlayerTrack {
        // "English · TrueHD Atmos 7.1" / "Estonian · SRT (Forced)" — prefer
        // the author's track title as detail, fall back to codec facts.
        let language = track.lang.flatMap { Locale.current.localizedString(forLanguageCode: $0) ?? $0.uppercased() }
        var detail = track.title
        if detail == nil, let codec = track.codec {
            var facts = codec.uppercased()
            if kind == .audio, let channels = track.channelCount {
                facts += " · \(channels)ch"
            }
            detail = facts
        }
        var name = [language, detail].compactMap(\.self).joined(separator: " · ")
        if name.isEmpty {
            name = "Track \(track.id)"
        }
        if track.forced == true {
            name += " (Forced)"
        }
        return PlayerTrack(
            engineID: track.id,
            kind: kind,
            displayName: name,
            isSelected: track.selected == true
        )
    }
}
