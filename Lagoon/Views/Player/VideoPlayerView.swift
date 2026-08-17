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

    private(set) var hudLines: [String] = []
    private var hudTask: Task<Void, Never>?

    private var client: JellyfinClient?
    private var itemId = ""
    private var mediaSourceId = ""
    private var playSessionId: String?
    private var playMethod: PlayMethod = .directPlay
    private var progressTask: Task<Void, Never>?
    private var didReportStop = false
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

            playerInfo = itemInfo(for: media, source: source, client: client, extras: await extras)

            // The server's default audio choice (user language preferences
            // applied server-side) maps to the demuxer's per-type 1-based
            // ordinal: embedded streams keep their demux order.
            let embeddedAudio = (source.mediaStreams ?? []).filter { $0.type == "Audio" }
            var initialAudioOrdinal: Int?
            if let index = source.defaultAudioStreamIndex,
               let position = embeddedAudio.firstIndex(where: { $0.index == index }) {
                initialAudioOrdinal = position + 1
            }

            // Subtitles share the ordinal convention, with external
            // (sidecar) streams appended after the embedded ones — the
            // engine lists them in the same order (HEL-48 M5).
            let allSubtitles = (source.mediaStreams ?? []).filter { $0.type == "Subtitle" }
            let embeddedSubtitles = allSubtitles.filter { $0.isExternal != true }
            let externalTracks: [ExternalSubtitleTrack] = allSubtitles
                .filter { $0.isExternal == true }
                .compactMap { stream in
                    guard let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else { return nil }
                    return ExternalSubtitleTrack(
                        url: url,
                        title: stream.displayTitle,
                        language: stream.language,
                        select: stream.index == source.defaultSubtitleStreamIndex
                    )
                }
            var initialSubtitleOrdinal: Int?
            if let index = source.defaultSubtitleStreamIndex {
                if let position = embeddedSubtitles.firstIndex(where: { $0.index == index }) {
                    initialSubtitleOrdinal = position + 1
                } else if let position = externalTracks.firstIndex(where: \.select) {
                    initialSubtitleOrdinal = embeddedSubtitles.count + position + 1
                }
            }

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
        } catch {
            engine = nil
            errorMessage = (error as? JellyfinError)?.errorDescription ?? "Playback failed."
        }
    }

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let client = self.client, let engine = self.engine else { return }
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
        extras: JellyfinClient.PlaybackExtras
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
            trickplay: client.trickplaySource(itemId: media.id, mediaSourceId: source.id, extras: extras)
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
        lines.append("Queues:  V \(depths.video) · A \(depths.audio) · stalls \(engine.stallCount)")
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
                    onPanelToggle: { panelOpen = $0 }
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
            if finished {
                dismiss()
            }
        }
        .onDisappear {
            Task { await controller.stop() }
        }
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
