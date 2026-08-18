import Observation
import OSLog
import SwiftUI

/// Identifiable wrapper so `fullScreenCover(item:)` can present playback.
nonisolated struct PlayerItem: Identifiable {
    let id = UUID()
    let media: MediaItem
    var startFromBeginning = false
}

/// Negotiates the stream with Jellyfin, runs the Lagoon engine (the app's
/// only player since HEL-48 went all-in), and owns progress reporting.
@Observable
final class PlaybackController {
    private(set) var engine: SampleBufferPlayerEngine?
    private(set) var playerInfo: PlayerItemInfo?
    private(set) var errorMessage: String?
    private(set) var didFinish = false

    /// The episode queued behind this one, resolved once at start so the Up
    /// Next card can appear the instant the credits do (HEL-66). Nil for
    /// movies and at the end of a series.
    private(set) var nextUp: MediaItem?

    private(set) var hudLines: [String] = []
    private var hudTask: Task<Void, Never>?

    private var client: JellyfinClient?
    private var itemId = ""
    private var mediaSourceId = ""
    private var playSessionId: String?
    private var playMethod: PlayMethod = .directPlay
    private var progressTask: Task<Void, Never>?
    private var didReportStop = false
    private var nextUpTask: Task<Void, Never>?
    /// Guards the hand-off: `didFinish` and an expiring countdown can both
    /// arrive at the end of a file, and advancing twice would skip an
    /// episode outright.
    private var isAdvancing = false
    /// What the viewer picked in the track panel, carried into the next
    /// episode (HEL-66). Nil on a first load — there is nothing to carry.
    private var trackPreference: TrackPreference?
    /// The current item's streams in the order the engine numbers them, so
    /// a selected track can be named rather than just counted. Audio is the
    /// embedded list; subtitles are embedded first, then external.
    private var audioStreams: [MediaStream] = []
    private var orderedSubtitleStreams: [MediaStream] = []

    /// A track choice described by what it *is* rather than where it sat.
    ///
    /// Matching by language and title rather than by ordinal because two
    /// episodes of one show usually share a stream layout, and "usually" is
    /// not "always": a commentary track on one episode would shift every
    /// choice below it and hand the viewer the wrong language.
    private struct TrackPreference {
        var audioLanguage: String?
        var audioTitle: String?
        var subtitleLanguage: String?
        var subtitleTitle: String?
        /// Subtitles deliberately turned off, which is a choice to carry
        /// like any other — otherwise the next episode reinstates whatever
        /// the server thinks the default is.
        var subtitlesOff: Bool
    }
    @ObservationIgnored private let performanceSignpostID = OSSignpostID(log: PlaybackPerformance.log)

    func start(media: MediaItem, startFromBeginning: Bool, client: JellyfinClient) async {
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Playback Controller Start",
            signpostID: performanceSignpostID,
            "item=%{public}s",
            media.id
        )
        defer {
            os_signpost(
                .end,
                log: PlaybackPerformance.log,
                name: "Playback Controller Start",
                signpostID: performanceSignpostID
            )
        }
        self.client = client
        itemId = media.id
        do {
            // Chapters and trickplay ride alongside the negotiation rather
            // than after it — neither is in PlaybackInfo, and waiting for a
            // second round trip would delay the first frame (HEL-39).
            async let extras = client.playbackExtras(itemId: media.id)
            async let segments = client.mediaSegments(itemId: media.id)
            let info = try await client.playbackInfo(itemId: media.id)
            guard info.errorCode == nil, let source = info.mediaSources.first else {
                throw JellyfinError.unplayable
            }
            mediaSourceId = source.id
            playSessionId = info.playSessionId

            let (streamURL, method) = try client.streamURL(itemId: media.id, source: source)
            playMethod = method

            var resumeSeconds: Double = 0
            if !startFromBeginning, let ticks = media.userData?.playbackPositionTicks, ticks > 0 {
                resumeSeconds = Ticks.seconds(ticks)
            }

            playerInfo = itemInfo(
                for: media,
                source: source,
                client: client,
                extras: await extras,
                segments: await segments
            )

            // The server's default audio choice (user language preferences
            // applied server-side) maps to the demuxer's per-type 1-based
            // ordinal: embedded streams keep their demux order.
            let embeddedAudio = (source.mediaStreams ?? []).filter { $0.type == "Audio" }
            var initialAudioOrdinal: Int?
            if let index = source.defaultAudioStreamIndex,
               let position = embeddedAudio.firstIndex(where: { $0.index == index }) {
                initialAudioOrdinal = position + 1
            }
            // A choice carried in from the previous episode outranks the
            // server's default: the viewer overrode it once already.
            if let preference = trackPreference,
               let carried = Self.ordinal(
                   matchingLanguage: preference.audioLanguage,
                   title: preference.audioTitle,
                   in: embeddedAudio
               ) {
                initialAudioOrdinal = carried
            }

            // Subtitles share the ordinal convention, with external
            // (sidecar) streams appended after the embedded ones — the
            // engine lists them in the same order (HEL-48 M5).
            let allSubtitles = (source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
            let embeddedSubtitles = allSubtitles.filter { $0.isExternal != true }
            // Kept paired with their streams: a sidecar whose URL won't
            // resolve is dropped from what the engine is given, so the
            // stream list has to lose it too or every ordinal past it
            // would name the wrong track.
            let externalPairs: [(stream: MediaStream, track: ExternalSubtitleTrack)] = allSubtitles
                .filter { $0.isExternal == true }
                .compactMap { stream in
                    guard let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else { return nil }
                    return (stream, ExternalSubtitleTrack(
                        url: url,
                        title: stream.displayTitle,
                        language: stream.language,
                        select: stream.index == source.defaultSubtitleStreamIndex
                    ))
                }
            let externalTracks = externalPairs.map(\.track)
            let orderedSubtitles = embeddedSubtitles + externalPairs.map(\.stream)
            var initialSubtitleOrdinal: Int?
            if let index = source.defaultSubtitleStreamIndex {
                if let position = embeddedSubtitles.firstIndex(where: { $0.index == index }) {
                    initialSubtitleOrdinal = position + 1
                } else if let position = externalTracks.firstIndex(where: \.select) {
                    initialSubtitleOrdinal = embeddedSubtitles.count + position + 1
                }
            }
            if let preference = trackPreference {
                // 0 is the engine's "no subtitles" ordinal.
                if preference.subtitlesOff {
                    initialSubtitleOrdinal = 0
                } else if let carried = Self.ordinal(
                    matchingLanguage: preference.subtitleLanguage,
                    title: preference.subtitleTitle,
                    in: orderedSubtitles
                ) {
                    initialSubtitleOrdinal = carried
                }
            }
            audioStreams = embeddedAudio
            orderedSubtitleStreams = orderedSubtitles

            let engine = SampleBufferPlayerEngine()
            engine.prepare(
                url: streamURL,
                startSeconds: resumeSeconds,
                initialAudioOrdinal: initialAudioOrdinal,
                initialSubtitleOrdinal: initialSubtitleOrdinal,
                externalSubtitles: externalTracks
            )
            engine.onFinished = { [weak self] in self?.didFinish = true }
            engine.onError = { [weak self] message in
                guard let self else { return }
                self.engine?.shutdown()
                self.engine = nil
                self.errorMessage = message
            }
            self.engine = engine

            try? await client.reportPlaybackStart(.init(
                itemId: itemId,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                positionTicks: Ticks.ticks(resumeSeconds),
                playMethod: playMethod.rawValue,
                canSeek: true
            ))
            startProgressLoop()
            startHUD(source: source, method: method)
            resolveNextUp(after: media, client: client)
        } catch {
            engine = nil
            errorMessage = (error as? JellyfinError)?.errorDescription ?? "Playback failed."
        }
    }

    /// Looks up what plays next, off the critical path.
    ///
    /// Deliberately after the engine is running rather than alongside the
    /// negotiation: nothing on screen needs it for another forty minutes,
    /// and `start` is the one place in the app where a round trip costs a
    /// visibly later first frame (HEL-39).
    private func resolveNextUp(after media: MediaItem, client: JellyfinClient) {
        nextUpTask?.cancel()
        nextUp = nil
        guard media.type == .episode else { return }
        nextUpTask = Task { [weak self] in
            let next = try? await client.episodeAfter(media)
            guard !Task.isCancelled else { return }
            self?.nextUp = next
        }
    }

    /// Roll into the queued episode without leaving the player (HEL-66).
    ///
    /// The order is the whole of it: the finished episode's stop report has
    /// to land *before* the next one starts. Jellyfin marks an item played
    /// off that report, and starting a second session for the same device
    /// first leaves the one just finished unresolved.
    func playNextEpisode() async {
        guard !isAdvancing, let next = nextUp, let client else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        captureTrackPreference()
        await stop()
        didFinish = false
        didReportStop = false
        errorMessage = nil
        hudLines = []
        playerInfo = nil
        // Resume rather than restart: `episodeAfter` walks the series in
        // order, so the next one along can carry a position of its own.
        await start(media: next, startFromBeginning: false, client: client)
    }

    /// Reads the live selection back off the engine before it is torn down.
    private func captureTrackPreference() {
        guard let engine else { return }
        let audio = engine.audioTracks.first(where: \.isSelected)
        let subtitle = engine.subtitleTracks.first(where: \.isSelected)
        let audioStream = audio.flatMap { Self.stream(at: $0.engineID, in: audioStreams) }
        let subtitleStream = subtitle.flatMap { Self.stream(at: $0.engineID, in: orderedSubtitleStreams) }
        trackPreference = TrackPreference(
            audioLanguage: audioStream?.language,
            audioTitle: audioStream?.displayTitle,
            subtitleLanguage: subtitleStream?.language,
            subtitleTitle: subtitleStream?.displayTitle,
            // No selected subtitle track is the engine's way of saying off.
            subtitlesOff: subtitle == nil
        )
    }

    /// Engine ordinals are 1-based and count per kind.
    private static func stream(at ordinal: Int, in streams: [MediaStream]) -> MediaStream? {
        let index = ordinal - 1
        return streams.indices.contains(index) ? streams[index] : nil
    }

    /// Where the carried-over choice lands in this item's streams, or nil to
    /// leave the server's default alone — which is the right answer when the
    /// next episode simply hasn't got the track the last one did.
    private static func ordinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [MediaStream]
    ) -> Int? {
        guard language != nil || title != nil else { return nil }
        if let exact = streams.firstIndex(where: { $0.language == language && $0.displayTitle == title }) {
            return exact + 1
        }
        // Titles carry episode-specific noise ("English (SDH) - Forced");
        // language alone is the durable half of the match.
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
    }

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let client = self.client, let engine = self.engine else { return }
                // Rides the progress loop because it needs no extra timer and
                // 10 s is ample to see a leak's slope (HEL-58 shipped one that
                // climbed ~2.3 MB/s into the per-process limit).
                let memory = MemorySnapshot.current()
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Playback Memory",
                    signpostID: self.performanceSignpostID,
                    "footprintMB=%{public}.1f availableMB=%{public}.1f position=%{public}.3f",
                    memory.footprintMB,
                    memory.availableMB,
                    engine.timePosition
                )
                try? await client.reportPlaybackProgress(.init(
                    itemId: self.itemId,
                    mediaSourceId: self.mediaSourceId,
                    playSessionId: self.playSessionId,
                    positionTicks: Ticks.ticks(engine.timePosition),
                    isPaused: engine.isPaused,
                    playMethod: self.playMethod.rawValue
                ))
            }
        }
    }

    func stop() async {
        progressTask?.cancel()
        hudTask?.cancel()
        nextUpTask?.cancel()
        guard let client, let engine, !didReportStop else { return }
        didReportStop = true
        let seconds = engine.timePosition

        // Keep the dismissal-critical main-actor phase measurable and tiny.
        // The engine now serializes renderer flushing and queued-buffer
        // release on its existing pump queue (HEL-57).
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Dismiss Main Actor Cleanup",
            signpostID: performanceSignpostID
        )
        engine.shutdown()
        self.engine = nil
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Dismiss Main Actor Cleanup",
            signpostID: performanceSignpostID
        )

        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Playback Stopped Report",
            signpostID: performanceSignpostID
        )
        try? await client.reportPlaybackStopped(.init(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: Ticks.ticks(seconds)
        ))
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Playback Stopped Report",
            signpostID: performanceSignpostID
        )
    }

    // Builds the Infuse-style facts line: runtime, year, size, video, audio,
    // bitrate, fps, genres, rating — skipping anything the server didn't know.
    private func itemInfo(
        for media: MediaItem,
        source: MediaSource,
        client: JellyfinClient,
        extras: JellyfinClient.PlaybackExtras,
        segments: [MediaSegment] = []
    ) -> PlayerItemInfo {
        let streams = source.mediaStreams ?? []
        let video = streams.first(where: { $0.type == "Video" })
        let audioStreams = streams.filter { $0.type == "Audio" }
        let audio = audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first

        var facts: [String] = []
        if let runtime = media.runtimeLabel { facts.append(runtime) }
        if let year = media.productionYear { facts.append("\(year)") }
        if let size = source.size {
            facts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let videoToken = Self.videoToken(for: video) { facts.append(videoToken) }
        if let audioToken = Self.audioToken(for: audio) { facts.append(audioToken) }
        if let bitrate = source.bitrate {
            facts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
        }
        if let fps = video?.realFrameRate {
            facts.append("\(String(format: "%g", fps)) fps")
        }
        if let genres = media.genres, !genres.isEmpty {
            facts.append(genres.prefix(3).joined(separator: ", "))
        }
        if let rating = media.officialRating { facts.append(rating) }

        var videoSummary: String?
        if let video {
            var parts: [String] = []
            if let codec = video.codec { parts.append(codec.uppercased()) }
            if let width = video.width {
                parts.append(Self.resolutionClass(width: width))
            }
            if let range = video.videoRangeType, range != "SDR" {
                parts.append(Self.rangeLabel(range))
            }
            if let width = video.width, let height = video.height { parts.append("\(width)×\(height)") }
            if let fps = video.realFrameRate { parts.append("\(String(format: "%g", fps)) fps") }
            videoSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        // Kept whole, opening chapter included: it's a jump target even
        // though the transport draws no tick at 0:00.
        let chapters = extras.chapters
            .enumerated()
            .map { PlayerChapter(id: $0.offset, name: $0.element.name, start: Ticks.seconds($0.element.startPositionTicks)) }
            .sorted { $0.start < $1.start }

        return PlayerItemInfo(
            title: media.railTitle,
            subtitle: media.railSubtitle,
            overview: media.overview,
            facts: facts,
            videoSummary: videoSummary,
            posterURL: client.imageURL(for: media, kind: .primary, maxWidth: 400),
            chapters: chapters,
            trickplay: client.trickplaySource(itemId: media.id, mediaSourceId: source.id, extras: extras),
            segments: segments
        )
    }

    // "HEVC (4K DV)" — codec plus resolution class and dynamic range.
    private static func videoToken(for video: MediaStream?) -> String? {
        guard let video, let codec = video.codec else { return nil }
        var qualifiers: [String] = []
        if let width = video.width { qualifiers.append(resolutionClass(width: width)) }
        if let range = video.videoRangeType, range != "SDR" { qualifiers.append(rangeLabel(range)) }
        var token = codec.uppercased()
        if !qualifiers.isEmpty {
            token += " (\(qualifiers.joined(separator: " ")))"
        }
        return token
    }

    // "Dolby Digital+ Atmos 5.1" — marketing codec name, Atmos when the
    // server's stream profile says so, channel layout.
    private static func audioToken(for audio: MediaStream?) -> String? {
        guard let audio, let codec = audio.codec else { return nil }
        var name = switch codec.lowercased() {
        case "eac3": "Dolby Digital+"
        case "ac3": "Dolby Digital"
        case "truehd": "Dolby TrueHD"
        case "dts": "DTS"
        default: codec.uppercased()
        }
        if audio.profile?.localizedCaseInsensitiveContains("atmos") == true {
            name += " Atmos"
        }
        let layout: String? = switch audio.channels {
        case 8: "7.1"
        case 6: "5.1"
        case 2: "2.0"
        case 1: "1.0"
        default: audio.channels.map { "\($0)ch" }
        }
        return [name, layout].compactMap(\.self).joined(separator: " ")
    }

    // Shared with the detail page's badge row so the two can't disagree
    // about what 4K or Dolby Vision means (see MediaQuality).
    private static func resolutionClass(width: Int) -> String {
        MediaQuality.resolutionClass(width: width)
    }

    private static func rangeLabel(_ range: String) -> String {
        MediaQuality.rangeLabel(range)
    }

    // MARK: Playback HUD (Settings → Debug → Playback HUD; ships in all
    // builds so TestFlight sessions can diagnose playback too)

    private func startHUD(source: MediaSource, method: PlayMethod) {
        guard UserDefaults.standard.bool(forKey: "debug.playbackHUD") else { return }

        var negotiated = [
            "Method: \(method.rawValue)"
                + (method == .transcode ? " (\(source.transcodingSubProtocol ?? "?"))" : ""),
        ]
        var sourceLine = "Source: \(source.container ?? "?")"
        if let bitrate = source.bitrate {
            sourceLine += " · \(Self.mbps(bitrate))"
        }
        negotiated.append(sourceLine)
        if let video = source.mediaStreams?.first(where: { $0.type == "Video" }) {
            var line = "Video:  \(video.codec ?? "?")"
            if let profile = video.profile { line += " \(profile.lowercased())" }
            if let range = video.videoRangeType { line += " · \(range)" }
            if let width = video.width, let height = video.height { line += " · \(width)×\(height)" }
            negotiated.append(line)
        }
        let audioStreams = source.mediaStreams?.filter { $0.type == "Audio" } ?? []
        if let audio = audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first {
            var line = "Audio:  \(audio.codec ?? "?")"
            if let channels = audio.channels { line += " · \(channels)ch" }
            negotiated.append(line)
        }

        hudLines = negotiated
        hudTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let engine = self.engine else { return }
                engine.refreshVideoPerformanceMetrics()
                self.hudLines = negotiated + Self.liveHUDLines(for: engine)
            }
        }
    }

    private static func liveHUDLines(for engine: SampleBufferPlayerEngine) -> [String] {
        var lines: [String] = []
        if let size = engine.videoSize {
            lines.append("Playing: \(Int(size.width))×\(Int(size.height))")
        } else {
            lines.append("Playing: not ready · \(engine.isBuffering ? "buffering" : "…")")
        }
        if let audio = engine.audioDiagnostic {
            lines.append("Track:   \(audio)")
        }
        if engine.duration > 0 {
            lines.append("Time:    \(Int(engine.timePosition))/\(Int(engine.duration)) s")
        }
        let depths = engine.queueDepths
        lines.append("Queues:  V \(depths.video) · A \(depths.audio) · stalls \(engine.stallCount) · aGaps \(engine.audioTimingGapCount)")
        if let videoTiming = engine.videoTimingDiagnostic {
            lines.append("Vtime:   \(videoTiming)")
        }
        if let strip = engine.enhancementLayerStripInfo {
            lines.append("EL strip: \(strip)")
        }
        #if os(tvOS)
        // Every gate between the request and the glass: the app's Debug
        // toggle and the system's Match Content setting. A photo of this
        // line is what makes a hardware A/B run self-describing.
        if let request = engine.displayMatchRequest {
            let appToggleOn = UserDefaults.standard.object(forKey: "debug.matchContent") == nil
                || UserDefaults.standard.bool(forKey: "debug.matchContent")
            lines.append(String(
                format: "Display: request %.3f Hz · app %@ · %@",
                request.frameRate,
                appToggleOn ? "on" : "off",
                DisplayModeMatcher.statusDescription
            ))
        }
        #endif
        if let bench = engine.benchStatus {
            lines.append("Bench:   \(bench)")
        }
        let memory = MemorySnapshot.current()
        var memoryLine = String(format: "Memory:  %.0f MB", memory.footprintMB)
        if memory.availableBytes > 0 {
            memoryLine += String(format: " · %.0f MB free", memory.availableMB)
        }
        lines.append(memoryLine)
        if let metrics = engine.videoPerformance {
            lines.append(
                "Frames:  \(metrics.droppedFrames) dropped / \(metrics.totalFrames)"
                    + (metrics.corruptedFrames > 0 ? " · \(metrics.corruptedFrames) corrupt" : "")
            )
        }
        return lines
    }

    private static func mbps(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }
}

struct VideoPlayerView: View {
    let playerItem: PlayerItem

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PlaybackController()
    @State private var panelOpen = false
    @AppStorage("debug.matchContent") private var matchContent = true
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("playback.autoplayMode") private var autoplayModeRaw = AutoplayMode.autoDelay.rawValue
    /// Back was pressed on the Up Next card. Outlives the card itself,
    /// because the episode still has its credits to run and the end of the
    /// file must not undo the answer that was already given.
    @State private var autoplayCancelled = false

    private var autoplayMode: AutoplayMode { AutoplayMode(rawValue: autoplayModeRaw) ?? .autoDelay }

    /// What the Up Next card draws, or nil when there is nothing queued.
    private var nextUpEpisode: NextUpEpisode? {
        guard let next = controller.nextUp else { return nil }
        return NextUpEpisode(
            title: next.name ?? "",
            subtitle: next.episodeLabel,
            imageURL: session.client.imageURL(for: next, kind: .thumb, maxWidth: 480)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage = controller.errorMessage {
                // The engine is gone on purpose: the error overlay carries
                // its own focus and exit handling so Menu never strands.
                errorOverlay(errorMessage)
            } else if let engine = controller.engine {
                CustomPlayerView(
                    engine: engine,
                    info: fallbackInfo,
                    onDismiss: { dismiss() },
                    onPanelToggle: { panelOpen = $0 },
                    nextUp: nextUpEpisode,
                    onPlayNext: { advance() },
                    onCancelNextUp: { autoplayCancelled = true }
                ) {
                    SampleBufferVideoSurface(engine: engine)
                }
            } else {
                LoadingView()
            }

            if !controller.hudLines.isEmpty, !panelOpen {
                playbackHUD
            }
        }
        .interactiveDismissDisabled()
        .task {
            await controller.start(
                media: playerItem.media,
                startFromBeginning: playerItem.startFromBeginning,
                client: session.client
            )
        }
        .onChange(of: controller.didFinish) { _, finished in
            guard finished else { return }
            // A countdown still running when the file ran out finishes the
            // job here — without an `Outro` segment to anchor it the two
            // land within a frame of each other, and whichever arrives
            // first should win. `playNextEpisode` is guarded against being
            // taken up on it twice.
            if autoplayMode == .autoDelay, !autoplayCancelled, controller.nextUp != nil {
                advance()
            } else {
                // `.card` means never acting alone, so an offer that went
                // unanswered closes the player exactly as `.off` does.
                dismiss()
            }
        }
        .onChange(of: controller.engine?.displayMatchRequest) { _, request in
            applyDisplayMatch(request)
        }
        // Live so an A/B can flip mid-playback (expect the TV's mode
        // switch flash) and so the HUD's app on/off always tells the
        // truth about what is applied.
        .onChange(of: matchContent) { _, _ in
            applyDisplayMatch(controller.engine?.displayMatchRequest)
        }
        // Backgrounding mid-playback must hand the display back — the
        // home screen has no business running at the content's mode — and
        // returning re-requests it (HEL-64).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                applyDisplayMatch(nil)
            case .active:
                applyDisplayMatch(controller.engine?.displayMatchRequest)
            @unknown default:
                break
            }
        }
        // Harness hook (debug.benchAutoExit): a completed bench window
        // leaves the player through the clean teardown path — stop
        // report, renderer teardown, display-mode restore — so scripted
        // device runs never kill the app mid-playback again.
        .onChange(of: controller.engine?.benchCompleted) { _, completed in
            if completed == true, UserDefaults.standard.bool(forKey: "debug.benchAutoExit") {
                dismiss()
            }
        }
        .onDisappear {
            applyDisplayMatch(nil)
            Task { await controller.stop() }
        }
    }

    /// tvOS Match Content (HEL-64): ask the display for the video's own
    /// frame rate and dynamic range instead of letting the compositor
    /// cadence-convert and tone-map every full-4K frame. Behind a Debug
    /// switch (default on) so hardware A/Bs can hold it still; the
    /// system's own Match Content settings gate it beneath that.
    private func applyDisplayMatch(_ request: DisplayMatchRequest?) {
        #if os(tvOS)
        DisplayModeMatcher.apply(matchContent ? request : nil)
        #endif
    }

    /// The next episode starts with a clean slate: a "no" belongs to the
    /// episode it was said during, not to the rest of the binge.
    private func advance() {
        autoplayCancelled = false
        Task { await controller.playNextEpisode() }
    }

    private var fallbackInfo: PlayerItemInfo {
        controller.playerInfo ?? PlayerItemInfo(
            title: playerItem.media.railTitle,
            subtitle: playerItem.media.railSubtitle,
            overview: playerItem.media.overview,
            facts: [],
            videoSummary: nil,
            posterURL: nil
        )
    }

    private var playbackHUD: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            ForEach(Array(controller.hudLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white.opacity(0.85))
        .padding(Metrics.Space.m)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metrics.screenGutter)
        .allowsHitTesting(false)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: Metrics.Space.l) {
            Image(systemName: "play.slash")
                .font(Typography.largeGlyph)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 700)
                .multilineTextAlignment(.center)
            Button("Back") {
                dismiss()
            }
            .buttonStyle(.glass)
        }
        #if os(tvOS)
        .onExitCommand {
            dismiss()
        }
        #endif
    }
}
