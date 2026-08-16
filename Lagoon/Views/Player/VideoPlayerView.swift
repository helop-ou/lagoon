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

    #if DEBUG
    private(set) var hudLines: [String] = []
    private var hudTask: Task<Void, Never>?
    #endif

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

            let playerItem = AVPlayerItem(url: streamURL)
            // Metadata must be complete before playback starts — mutating it
            // after the player is active corrupts the info panel layout.
            playerItem.externalMetadata = await buildMetadata(for: media, client: client)

            let player = AVPlayer(playerItem: playerItem)
            self.player = player

            if !startFromBeginning, let ticks = media.userData?.playbackPositionTicks, ticks > 0 {
                await player.seek(
                    to: CMTime(seconds: Ticks.seconds(ticks), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 5, preferredTimescale: 600)
                )
            }

            player.play()
            observeEnd(of: playerItem)
            #if DEBUG
            startHUD(source: source, method: method, playerItem: playerItem)
            #endif

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

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let player = self.player, let client = self.client else { return }
                let seconds = player.currentTime().seconds
                guard seconds.isFinite else { continue }
                try? await client.reportPlaybackProgress(.init(
                    itemId: self.itemId,
                    mediaSourceId: self.mediaSourceId,
                    playSessionId: self.playSessionId,
                    positionTicks: Ticks.ticks(seconds),
                    isPaused: player.timeControlStatus != .playing,
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
        #if DEBUG
        hudTask?.cancel()
        #endif
        guard let player, let client, !didReportStop else { return }
        didReportStop = true
        let seconds = player.currentTime().seconds
        player.pause()
        self.player = nil
        try? await client.reportPlaybackStopped(.init(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: Ticks.ticks(seconds.isFinite ? seconds : 0)
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

    private func metadataItem(_ identifier: AVMetadataIdentifier, value: any NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    #if DEBUG
    // MARK: Playback HUD (DEBUG builds, Settings → Debug → Playback HUD)

    private func startHUD(source: MediaSource, method: PlayMethod, playerItem: AVPlayerItem) {
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
        hudTask = Task { [weak self, weak playerItem] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let playerItem else { return }
                self.hudLines = negotiated + (await Self.liveHUDLines(for: playerItem))
            }
        }
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
    #endif
}

struct VideoPlayerView: View {
    let playerItem: PlayerItem

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PlaybackController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = controller.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let errorMessage = controller.errorMessage {
                // The player is gone on purpose: a dead AVPlayer swallows the
                // Menu press and there's no way to back out.
                errorOverlay(errorMessage)
            } else {
                LoadingView()
            }

            #if DEBUG
            if !controller.hudLines.isEmpty {
                playbackHUD
            }
            #endif
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

    #if DEBUG
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
    #endif

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
