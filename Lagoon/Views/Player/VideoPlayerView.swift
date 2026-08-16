import AVKit
import Observation
import SwiftUI

/// Identifiable wrapper so `fullScreenCover(item:)` can present playback.
nonisolated struct PlayerItem: Identifiable {
    let id = UUID()
    let media: MediaItem
    var startFromBeginning = false
}

@Observable
final class PlaybackController {
    private(set) var player: AVPlayer?
    private(set) var mpvEngine: MPVPlayerEngine?
    private(set) var playerInfo: PlayerItemInfo?
    private(set) var errorMessage: String?
    private(set) var didFinish = false

    private var client: JellyfinClient?
    private var itemId = ""
    private var mediaSourceId = ""
    private var playSessionId: String?
    private var playMethod: PlayMethod = .directPlay
    private var progressTask: Task<Void, Never>?
    private var endObserverTask: Task<Void, Never>?
    private var didReportStop = false

    private(set) var hudLines: [String] = []
    private var hudTask: Task<Void, Never>?

    func start(media: MediaItem, startFromBeginning: Bool, client: JellyfinClient) async {
        self.client = client
        itemId = media.id
        do {
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

            // HEL-45: route MKV direct play to the mpv engine while it's
            // experimental (debug.mpvForMKV also widens the device profile,
            // which is what makes the server grant direct play for mkv).
            // Compiled into all builds so TestFlight can exercise it.
            let container = (source.container ?? "").lowercased()
            if UserDefaults.standard.bool(forKey: "debug.mpvForMKV"),
               method == .directPlay,
               container.split(separator: ",").contains(where: { $0 == "mkv" || $0 == "webm" }) {
                // Map the server's default stream choices (already filtered
                // through the user's language preferences) onto mpv's
                // per-type 1-based track ids: embedded streams keep their
                // demux order, so the ordinal within the type is the id.
                let streams = source.mediaStreams ?? []
                let embeddedAudio = streams.filter { $0.type == "Audio" }
                let embeddedSubtitles = streams.filter { $0.type == "Subtitle" && $0.isExternal != true }
                let externalSubtitles = streams.filter { $0.type == "Subtitle" && $0.isExternal == true }

                var initialAudioID: Int?
                if let index = source.defaultAudioStreamIndex,
                   let position = embeddedAudio.firstIndex(where: { $0.index == index }) {
                    initialAudioID = position + 1
                }
                var initialSubtitleID: Int?
                var defaultExternalIndex: Int?
                if let index = source.defaultSubtitleStreamIndex {
                    if let position = embeddedSubtitles.firstIndex(where: { $0.index == index }) {
                        initialSubtitleID = position + 1
                    } else if externalSubtitles.contains(where: { $0.index == index }) {
                        defaultExternalIndex = index
                    }
                }
                let sideloaded = externalSubtitles.compactMap { stream -> ExternalSubtitleTrack? in
                    guard let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else { return nil }
                    return ExternalSubtitleTrack(
                        url: url,
                        title: stream.displayTitle,
                        language: stream.language,
                        select: stream.index == defaultExternalIndex
                    )
                }

                playerInfo = itemInfo(for: media, source: source)

                let engine = MPVPlayerEngine()
                engine.prepare(
                    url: streamURL,
                    startSeconds: resumeSeconds,
                    initialAudioID: initialAudioID,
                    initialSubtitleID: initialSubtitleID,
                    externalSubtitles: sideloaded
                )
                engine.onFinished = { [weak self] in self?.didFinish = true }
                engine.onError = { [weak self] message in
                    guard let self else { return }
                    self.mpvEngine?.shutdown()
                    self.mpvEngine = nil
                    self.errorMessage = message
                }
                mpvEngine = engine

                try? await client.reportPlaybackStart(.init(
                    itemId: itemId,
                    mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId,
                    positionTicks: Ticks.ticks(resumeSeconds),
                    playMethod: playMethod.rawValue,
                    canSeek: true
                ))
                startProgressLoop()
                startHUD(source: source, method: method, playerItem: nil)
                return
            }

            let playerItem = AVPlayerItem(url: streamURL)
            // Metadata must be complete before playback starts — mutating it
            // after the player is active corrupts the info panel layout.
            playerItem.externalMetadata = await buildMetadata(for: media, client: client)

            let player = AVPlayer(playerItem: playerItem)
            self.player = player

            if resumeSeconds > 0 {
                await player.seek(
                    to: CMTime(seconds: resumeSeconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 5, preferredTimescale: 600)
                )
            }

            player.play()
            observeEnd(of: playerItem)
            startHUD(source: source, method: method, playerItem: playerItem)

            try? await client.reportPlaybackStart(.init(
                itemId: itemId,
                mediaSourceId: mediaSourceId,
                playSessionId: playSessionId,
                positionTicks: Ticks.ticks(player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0),
                playMethod: playMethod.rawValue,
                canSeek: true
            ))
            startProgressLoop()
        } catch {
            player = nil
            errorMessage = (error as? JellyfinError)?.errorDescription ?? "Playback failed."
        }
    }

    // Position/pause state read from whichever engine is active.
    private var currentSeconds: Double? {
        if let player {
            let seconds = player.currentTime().seconds
            return seconds.isFinite ? seconds : nil
        }
        if let mpvEngine {
            return mpvEngine.timePosition
        }
        return nil
    }

    private var currentlyPaused: Bool {
        if let player {
            return player.timeControlStatus != .playing
        }
        if let mpvEngine {
            return mpvEngine.isPaused
        }
        return true
    }

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let client = self.client, let seconds = self.currentSeconds else { return }
                try? await client.reportPlaybackProgress(.init(
                    itemId: self.itemId,
                    mediaSourceId: self.mediaSourceId,
                    playSessionId: self.playSessionId,
                    positionTicks: Ticks.ticks(seconds),
                    isPaused: self.currentlyPaused,
                    playMethod: self.playMethod.rawValue
                ))
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        endObserverTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                self?.didFinish = true
                return
            }
        }
    }

    func stop() async {
        progressTask?.cancel()
        endObserverTask?.cancel()
        hudTask?.cancel()
        guard let client, player != nil || mpvEngine != nil, !didReportStop else { return }
        didReportStop = true
        let seconds = currentSeconds ?? 0
        player?.pause()
        player = nil
        mpvEngine?.shutdown()
        mpvEngine = nil
        try? await client.reportPlaybackStopped(.init(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: Ticks.ticks(seconds)
        ))
    }

    private func buildMetadata(for media: MediaItem, client: JellyfinClient) async -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            metadataItem(.commonIdentifierTitle, value: (media.name ?? "") as NSString),
        ]
        if media.type == .episode, let seriesName = media.seriesName {
            let subtitle = [media.episodeLabel, seriesName].compactMap(\.self).joined(separator: " · ")
            items.append(metadataItem(.iTunesMetadataTrackSubTitle, value: subtitle as NSString))
        }
        if let overview = media.overview {
            items.append(metadataItem(.commonIdentifierDescription, value: overview as NSString))
        }
        if let posterURL = client.imageURL(for: media, kind: .primary, maxWidth: 600),
           let poster = await ImageCache.shared.load(posterURL, maxPixelSize: 600),
           let data = poster.jpegData(compressionQuality: 0.85) {
            items.append(metadataItem(.commonIdentifierArtwork, value: data as NSData))
        }
        return items
    }

    private func itemInfo(for media: MediaItem, source: MediaSource) -> PlayerItemInfo {
        var subtitle: String?
        if media.type == .episode, let seriesName = media.seriesName {
            subtitle = [media.episodeLabel, seriesName].compactMap(\.self).joined(separator: " · ")
        }
        var facts: [String] = []
        if let container = source.container {
            facts.append(container.uppercased())
        }
        let streams = source.mediaStreams ?? []
        if let video = streams.first(where: { $0.type == "Video" }) {
            var parts: [String] = []
            if let codec = video.codec { parts.append(codec.uppercased()) }
            if let range = video.videoRangeType { parts.append(range) }
            if let width = video.width, let height = video.height { parts.append("\(width)×\(height)") }
            if !parts.isEmpty { facts.append(parts.joined(separator: " · ")) }
        }
        let audioStreams = streams.filter { $0.type == "Audio" }
        if let audio = audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first {
            var parts: [String] = []
            if let codec = audio.codec { parts.append(codec.uppercased()) }
            if let channels = audio.channels { parts.append("\(channels)ch") }
            if !parts.isEmpty { facts.append(parts.joined(separator: " · ")) }
        }
        return PlayerItemInfo(
            title: media.name ?? "",
            subtitle: subtitle,
            overview: media.overview,
            facts: facts
        )
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    // MARK: Playback HUD (Settings → Debug → Playback HUD; ships in all
    // builds so TestFlight sessions can diagnose playback too)

    private func startHUD(source: MediaSource, method: PlayMethod, playerItem: AVPlayerItem?) {
        guard UserDefaults.standard.bool(forKey: "debug.playbackHUD") else { return }

        var negotiated = [
            "Method: \(method.rawValue)"
                + (method == .transcode ? " (\(source.transcodingSubProtocol ?? "?"))" : "")
                + (mpvEngine != nil ? " · mpv" : ""),
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
        hudTask = Task { [weak self, weak playerItem] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if let playerItem {
                    self.hudLines = negotiated + (await Self.liveHUDLines(for: playerItem))
                } else if let engine = self.mpvEngine {
                    self.hudLines = negotiated + Self.liveHUDLines(for: engine)
                } else {
                    return
                }
            }
        }
    }

    private static func liveHUDLines(for engine: MPVPlayerEngine) -> [String] {
        var lines: [String] = []
        if let size = engine.videoSize {
            lines.append("Playing: \(Int(size.width))×\(Int(size.height)) · mpv")
        } else {
            lines.append("Playing: not ready · \(engine.isBuffering ? "buffering" : "…") · mpv")
        }
        if engine.duration > 0 {
            lines.append("Time:    \(Int(engine.timePosition))/\(Int(engine.duration)) s")
        }
        return lines
    }

    private static func liveHUDLines(for item: AVPlayerItem) async -> [String] {
        var lines: [String] = []
        var delivered = ""
        let size = item.presentationSize
        if size != .zero {
            delivered = "\(Int(size.width))×\(Int(size.height))"
        }
        // The delivered fourCC tells remux truth from re-encode: dvh1 means
        // Dolby Vision actually survived to AVPlayer, hvc1 means plain HEVC.
        for track in item.tracks where track.assetTrack?.mediaType == .video {
            if let assetTrack = track.assetTrack,
               let desc = try? await assetTrack.load(.formatDescriptions).first {
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = String(
                    format: "%c%c%c%c",
                    (sub >> 24) & 0xFF, (sub >> 16) & 0xFF, (sub >> 8) & 0xFF, sub & 0xFF
                )
                delivered += delivered.isEmpty ? fourCC : " · \(fourCC)"
            }
        }
        if !delivered.isEmpty {
            lines.append("Playing: \(delivered)")
        } else {
            lines.append("Playing: not ready · buffer \(item.isPlaybackBufferEmpty ? "empty" : "ok")")
        }
        if let last = item.accessLog()?.events.last, last.indicatedBitrate > 0 {
            lines.append("Bitrate: \(mbps(Int(last.indicatedBitrate)))")
        }
        if let events = item.errorLog()?.events, let last = events.last {
            lines.append("Errors:  \(events.count) · \(last.errorStatusCode) \(last.errorDomain)")
            if let comment = last.errorComment {
                lines.append("  \(String(comment.prefix(64)))")
            }
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage = controller.errorMessage {
                // The player is gone on purpose: a dead AVPlayer swallows the
                // Menu press and there's no way to back out.
                errorOverlay(errorMessage)
            } else if let engine = controller.mpvEngine {
                CustomPlayerView(
                    engine: engine,
                    info: controller.playerInfo ?? PlayerItemInfo(
                        title: playerItem.media.name ?? "",
                        subtitle: episodeSubtitle,
                        overview: playerItem.media.overview,
                        facts: []
                    ),
                    onDismiss: { dismiss() }
                ) {
                    MPVVideoSurface(engine: engine)
                }
            } else if let player = controller.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                LoadingView()
            }

            if !controller.hudLines.isEmpty {
                playbackHUD
            }
        }
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

    private var episodeSubtitle: String? {
        guard playerItem.media.type == .episode, let seriesName = playerItem.media.seriesName else { return nil }
        return [playerItem.media.episodeLabel, seriesName].compactMap(\.self).joined(separator: " · ")
    }

    private var playbackHUD: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(controller.hudLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white.opacity(0.85))
        .padding(12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metrics.screenGutter)
        .allowsHitTesting(false)
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "play.slash")
                .font(.system(size: 56))
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
