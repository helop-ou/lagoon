import AVFAudio
import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// HEL-48 M1: the Lagoon playback engine — libavformat demux into
/// compressed CMSampleBuffers rendered by AVSampleBufferDisplayLayer /
/// AVSampleBufferAudioRenderer under an AVSampleBufferRenderSynchronizer.
/// The system does the decoding, color management, and audio output, which
/// is the whole point of this architecture (see HEL-48).
///
/// The app's only playback engine since 2026-08-16 (Jaagop's call: one
/// player for everything). Envelope: h264/hevc video passed through
/// compressed; aac/mp3/ac3/eac3 audio passed through compressed and
/// dts/truehd/flac/opus/vorbis decoded to LPCM via libavcodec (M4);
/// embedded + external subtitles as an overlay (M5) —
/// `DeviceProfile.lagoon` advertises exactly this, so anything outside it
/// arrives as an fMP4 HLS transcode that libavformat demuxes back into
/// the same envelope.
///
/// Threading: state and transport commands live on the main actor; the
/// demux loop runs on a dedicated serial queue, feeding two thread-safe
/// sample-buffer queues that the renderers' data pumps drain.
@Observable
final class SampleBufferPlayerEngine: PlayerEngine {
    private(set) var timePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var videoSize: CGSize?
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var currentSubtitleText: String?
    private(set) var currentSubtitleImages: [SubtitleImage] = []
    /// mpv convention (M6): positive delays the audio.
    private(set) var audioDelay: Double = 0
    /// Debug-HUD line: what the demuxer actually sees on the selected
    /// audio stream (codec, channels, FFmpeg's Atmos/JOC verdict) —
    /// readable without opening the track panel.
    private(set) var audioDiagnostic: String?
    private(set) var videoPerformance: VideoPerformanceSnapshot?
    private(set) var stallCount = 0
    /// Frame-loss bench progress/result for the HUD (HEL-64); nil unless
    /// Settings → Debug → Frame-loss bench is on.
    private(set) var benchStatus: String?
    /// The display-matching request for this video (HEL-64) — published
    /// once the demuxer knows the stream; the player view owns applying it.
    private(set) var displayMatchRequest: DisplayMatchRequest?

    var queueDepths: (video: Int, audio: Int) {
        (videoQueue.count, audioQueue.count)
    }

    /// Timestamp discontinuities in the audio feed — the measurable form
    /// of "the audio crackles" (HEL-64). Should read 0 during untouched
    /// playback; steady growth means the renderer is being handed a
    /// misaligned timeline.
    var audioTimingGapCount: Int {
        audioContinuity.gapCount
    }

    /// Proof the DoVi enhancement-layer strip experiment engaged, for the
    /// HUD — nil when the toggle is off or the stream has no EL.
    var enhancementLayerStripInfo: String? {
        guard let stats = demuxer.enhancementLayerStripStats else { return nil }
        return String(format: "%d pkts · %.1f MB removed", stats.units, Double(stats.bytes) / 1_000_000)
    }

    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    // MARK: Cross-thread state

    @ObservationIgnored nonisolated private let demuxer = FFmpegDemuxer()
    @ObservationIgnored nonisolated private let videoQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let audioQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let demuxQueue = DispatchQueue(label: "ee.helop.lagoon.demux", qos: .userInitiated)
    @ObservationIgnored nonisolated private let pumpQueue = DispatchQueue(label: "ee.helop.lagoon.pump", qos: .userInteractive)
    @ObservationIgnored nonisolated private let pumpKickState = PumpKickState()
    @ObservationIgnored nonisolated private let performanceSignpostID = OSSignpostID(log: PlaybackPerformance.log)
    @ObservationIgnored nonisolated private let audioContinuity = AudioContinuityMonitor()
    @ObservationIgnored private var bench: FrameLossBench?
    @ObservationIgnored private var benchEnabled = false
    @ObservationIgnored private var benchTickCount = 0

    // Written on main, read on the demux loop (or vice versa) — all simple
    // value types behind one lock.
    @ObservationIgnored nonisolated private let shared = SharedState()
    @ObservationIgnored nonisolated private let subtitleStore = SubtitleStore()

    @ObservationIgnored private var externalSubtitles: [ExternalSubtitleTrack] = []
    @ObservationIgnored private var embeddedSubtitleCount = 0
    // Bumped on every subtitle selection change so a stale external
    // download can't overwrite a newer choice's cues.
    @ObservationIgnored private var externalLoadToken = 0

    @ObservationIgnored nonisolated(unsafe) private var videoRenderer: AVSampleBufferVideoRenderer?
    @ObservationIgnored nonisolated(unsafe) private var audioRenderer: AVSampleBufferAudioRenderer?
    @ObservationIgnored nonisolated private let synchronizer = AVSampleBufferRenderSynchronizer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var stallRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var stallSignpostActive = false
    @ObservationIgnored private var shutdownRequested = false

    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingStartSeconds: Double = 0

    func prepare(
        url: URL,
        startSeconds: Double,
        initialAudioOrdinal: Int?,
        initialSubtitleOrdinal: Int? = nil,
        externalSubtitles: [ExternalSubtitleTrack] = []
    ) {
        pendingURL = url
        pendingStartSeconds = startSeconds
        self.externalSubtitles = externalSubtitles
        shared.withLock {
            $0.initialAudioOrdinal = initialAudioOrdinal
            $0.initialSubtitleOrdinal = initialSubtitleOrdinal
            $0.externalSubtitles = externalSubtitles
        }
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        guard videoRenderer == nil, let url = pendingURL else { return }

        // Debug switches, read once per playback like the HUD's: the strip
        // experiment must not change mid-A/B, and the bench arms in
        // beginPlayback.
        demuxer.stripEnhancementLayer = UserDefaults.standard.bool(forKey: "debug.stripDoviEL")
        benchEnabled = UserDefaults.standard.bool(forKey: "debug.frameLossBench")

        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Attach",
            signpostID: performanceSignpostID
        )

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Declares real multichannel content so the system's spatial
        // pipeline treats it as such on AirPods (M2).
        try? AVAudioSession.sharedInstance().setSupportsMultichannelContent(true)
        try? AVAudioSession.sharedInstance().setActive(true)

        let video = displayLayer.sampleBufferRenderer
        let audio = AVSampleBufferAudioRenderer()
        videoRenderer = video
        audioRenderer = audio
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)

        video.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpVideo()
        }
        audio.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpAudio()
        }

        // 0.1 s so subtitle cues land on time; timePosition still only
        // publishes on 0.25 s deltas.
        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.observeTime(time)
            }
        }

        shared.withLock { $0.pendingSeekSeconds = max(pendingStartSeconds, 0) }
        let startURL = url
        demuxQueue.async { [weak self] in
            self?.runDemuxLoop(url: startURL)
        }
    }

    // MARK: - Transport (PlayerEngine)

    func togglePause() {
        if synchronizer.rate > 0 {
            synchronizer.rate = 0
            isPaused = true
        } else {
            synchronizer.rate = 1
            isPaused = false
        }
        // Touching the transport ends a controlled measurement window;
        // the bench re-arms from wherever playback continues.
        rearmBench(at: timePosition)
    }

    func seek(by seconds: Double) {
        seek(to: timePosition + seconds)
    }

    func selectAudioTrack(id: Int?) {
        guard let id, id - 1 < audioTracks.count else { return }
        shared.withLock { $0.selectedAudioOrdinal = id }
        audioTracks = audioTracks.map {
            PlayerTrack(engineID: $0.engineID, kind: .audio, displayName: $0.displayName, isSelected: $0.engineID == id)
        }
        // Cleanest gapless-ish switch in M1: re-run the demux from the
        // current position with the new stream selected.
        seek(to: timePosition)
    }

    func setAudioDelay(_ seconds: Double) {
        let clamped = ((max(-5, min(5, seconds))) * 1000).rounded() / 1000
        guard clamped != audioDelay else { return }
        audioDelay = clamped
        shared.withLock { $0.audioDelaySeconds = clamped }
        // Compressed buffers carry their stamps from the demuxer — the
        // cheapest correct live apply is the audio-switch trick: re-demux
        // from here so every new buffer is stamped with the new offset.
        seek(to: timePosition)
    }

    func selectSubtitleTrack(id: Int?) {
        let ordinal = id ?? 0
        externalLoadToken += 1
        subtitleStore.removeAll()
        currentSubtitleText = nil
        currentSubtitleImages = []
        subtitleTracks = subtitleTracks.map {
            PlayerTrack(engineID: $0.engineID, kind: .subtitle, displayName: $0.displayName, isSelected: $0.engineID == ordinal)
        }
        if ordinal >= 1, ordinal <= embeddedSubtitleCount {
            shared.withLock { state in
                state.selectedSubtitleOrdinal = ordinal
                state.selectedSubtitleStreamIndex = state.embeddedSubtitleStreamIndices[ordinal - 1]
            }
            // Re-demux from the previous keyframe so a line that is
            // already on screen elsewhere appears immediately, not at the
            // next cue.
            seek(to: timePosition)
        } else {
            shared.withLock { state in
                state.selectedSubtitleOrdinal = ordinal
                state.selectedSubtitleStreamIndex = -1
            }
            if ordinal > embeddedSubtitleCount {
                loadExternalSubtitle(ordinal: ordinal)
            }
        }
    }

    /// Fetches and parses a Jellyfin external subtitle (vtt/srt delivery).
    private func loadExternalSubtitle(ordinal: Int) {
        let index = ordinal - embeddedSubtitleCount - 1
        guard externalSubtitles.indices.contains(index) else { return }
        let url = externalSubtitles[index].url
        let token = externalLoadToken
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            let cues = await Task.detached { SubtitleParser.cues(from: data) }.value
            guard let self, self.externalLoadToken == token else { return }
            self.subtitleStore.replaceAll(cues)
        }
    }

    func shutdown() {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        stallRecoveryTask?.cancel()
        if stallSignpostActive {
            stallSignpostActive = false
            os_signpost(
                .end,
                log: PlaybackPerformance.log,
                name: "Playback Stall",
                signpostID: performanceSignpostID,
                "outcome=shutdown"
            )
        }
        shared.withLock { $0.cancelled = true }
        // The demux loop may be asleep on queue backpressure while paused
        // or while AVFoundation's internal queues are full. Wake it so it
        // can observe cancellation and close immediately.
        videoQueue.interruptWaits()
        audioQueue.interruptWaits()
        // Aborts any av_* call blocked inside network I/O so the demux
        // loop can exit and close — without this a wedged open froze
        // teardown (seen in Jaagop's first test).
        demuxer.interrupt()
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        synchronizer.rate = 0

        let depths = queueDepths
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Renderer Teardown",
            signpostID: performanceSignpostID,
            "videoQueued=%{public}d audioQueued=%{public}d",
            depths.video,
            depths.audio
        )

        // requestMediaDataWhenReady and every enqueue already run on this
        // serial queue. Teardown belongs on the same queue: it removes a
        // race with an in-flight pump and, critically for HEL-57, keeps
        // renderer flushes and hundreds of CMSampleBuffer releases off the
        // main actor while the presenting screen animates back in.
        pumpQueue.async { [self] in
            finishRendererShutdown()
        }
    }

    func refreshVideoPerformanceMetrics() {
        guard !shutdownRequested, let renderer = videoRenderer else { return }
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let metrics else { return }
            let snapshot = VideoPerformanceSnapshot(
                totalFrames: metrics.totalNumberOfFrames,
                droppedFrames: metrics.numberOfDroppedFrames,
                corruptedFrames: metrics.numberOfCorruptedFrames
            )
            Task { @MainActor [weak self, snapshot] in
                guard let self, !self.shutdownRequested else { return }
                let previous = self.videoPerformance
                let droppedDelta = max(snapshot.droppedFrames - (previous?.droppedFrames ?? 0), 0)
                let corruptedDelta = max(snapshot.corruptedFrames - (previous?.corruptedFrames ?? 0), 0)
                self.feedBench(snapshot)
                if droppedDelta > 0 || corruptedDelta > 0 {
                    let depths = self.queueDepths
                    os_signpost(
                        .event,
                        log: PlaybackPerformance.log,
                        name: "Video Frame Loss",
                        signpostID: self.performanceSignpostID,
                        "droppedDelta=%{public}d droppedTotal=%{public}d corruptedDelta=%{public}d corruptedTotal=%{public}d frames=%{public}d position=%{public}.3f videoQueued=%{public}d audioQueued=%{public}d stalls=%{public}d",
                        droppedDelta,
                        snapshot.droppedFrames,
                        corruptedDelta,
                        snapshot.corruptedFrames,
                        snapshot.totalFrames,
                        self.timePosition,
                        depths.video,
                        depths.audio,
                        self.stallCount
                    )
                }
                self.videoPerformance = snapshot
            }
        }
    }

    nonisolated private func finishRendererShutdown() {
        // Nil first so any kickPumps block already queued behind this one
        // becomes a no-op instead of enqueueing after the flush.
        let video = videoRenderer
        let audio = audioRenderer
        videoRenderer = nil
        audioRenderer = nil

        video?.stopRequestingMediaData()
        audio?.stopRequestingMediaData()
        video?.flush()
        audio?.flush()
        videoQueue.reset()
        audioQueue.reset()

        // The synchronizer otherwise retains both renderers until the
        // main-actor engine dies. Removing them asynchronously lets their
        // decoder resources retire without hitching the returning UI.
        let removals = DispatchGroup()
        if let video {
            removals.enter()
            synchronizer.removeRenderer(video, at: CMTime(seconds: -1, preferredTimescale: 1)) { _ in
                removals.leave()
            }
        }
        if let audio {
            removals.enter()
            synchronizer.removeRenderer(audio, at: CMTime(seconds: -1, preferredTimescale: 1)) { _ in
                removals.leave()
            }
        }
        removals.notify(queue: pumpQueue) { [performanceSignpostID] in
            os_signpost(
                .end,
                log: PlaybackPerformance.log,
                name: "Renderer Teardown",
                signpostID: performanceSignpostID
            )
        }
    }

    // MARK: - Seeking

    func seek(to target: Double) {
        let clamped = max(0, duration > 0 ? min(target, duration - 1) : target)
        // Optimistic: the playhead moves the instant the seek is asked
        // for (HEL-39) — the engine will resume from exactly here.
        timePosition = clamped
        isBuffering = true
        synchronizer.rate = 0
        videoRenderer?.flush()
        audioRenderer?.flush()
        videoQueue.reset()
        audioQueue.reset()
        // The pts chain restarts at the target; the first buffer after a
        // flush must not read as a discontinuity.
        audioContinuity.reset()
        // Embedded cues re-arrive from the demuxer after the seek; leaving
        // the old ones would duplicate them. External cue lists are
        // complete and position-independent, so they stay.
        let embeddedSubtitleActive = shared.withLock { state -> Bool in
            state.pendingSeekSeconds = clamped
            return state.selectedSubtitleStreamIndex >= 0
        }
        if embeddedSubtitleActive {
            subtitleStore.removeAll()
        }
        currentSubtitleText = nil
        currentSubtitleImages = []
    }

    /// Demux primed after open/seek — start (or reposition, if paused) at
    /// the target position.
    private func beginPlayback(at seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        timePosition = seconds
        isBuffering = false
        synchronizer.setRate(isPaused ? 0 : 1, time: time)
        kickPumps()
        rearmBench(at: seconds)
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Playback Cushion Ready",
            signpostID: performanceSignpostID,
            "position=%{public}.3f",
            seconds
        )
    }

    private func observeTime(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        // 0.1 s granularity so the animated scrubber has fresh targets to
        // glide toward (HEL-39).
        if abs(seconds - timePosition) >= 0.1 {
            timePosition = seconds
        }
        refreshSubtitles(at: seconds)
        if !didFinish, duration > 0, seconds >= duration - 0.4,
           videoQueue.isFinished, audioQueue.isFinished,
           videoQueue.count == 0 {
            didFinish = true
            onFinished?()
        }
        // M6 stall detection: the clock has caught up to everything the
        // demuxer delivered and the queue is dry, but the file isn't over
        // — the network fell behind. Hold the clock instead of freezing
        // frames while it runs.
        if !isBuffering, !isPaused, !didFinish, !videoQueue.isFinished,
           videoQueue.count == 0,
           duration <= 0 || seconds < duration - 1,
           shared.withLock({ $0.videoBufferedTo }) - seconds < 0.2 {
            beginStallRecovery()
        }
        // Bench sampling piggybacks on this observer at ~1 Hz — the same
        // async metrics load the HUD uses, just driven while a window runs.
        if bench != nil {
            benchTickCount += 1
            if benchTickCount >= 10 {
                benchTickCount = 0
                refreshVideoPerformanceMetrics()
            }
        }
    }

    // MARK: - Frame-loss bench (HEL-64)

    /// (Re)start the controlled measurement window from `position` —
    /// called at playback start and whenever the transport is touched,
    /// because a window that survives a seek or pause is not a
    /// controlled measurement.
    private func rearmBench(at position: Double) {
        guard benchEnabled else { return }
        if bench == nil {
            bench = FrameLossBench(at: position)
        } else {
            bench?.rearm(at: position)
        }
        benchStatus = String(format: "arming @%.0fs", position)
    }

    private func feedBench(_ snapshot: VideoPerformanceSnapshot) {
        guard bench != nil else { return }
        let sample = FrameLossBench.Sample(
            position: timePosition,
            totalFrames: snapshot.totalFrames,
            droppedFrames: snapshot.droppedFrames,
            corruptedFrames: snapshot.corruptedFrames,
            stalls: stallCount,
            audioGaps: audioContinuity.gapCount,
            videoQueueDepth: videoQueue.count
        )
        if let result = bench!.record(sample) {
            benchStatus = String(
                format: "%.2f%% (%d/%d) · stalls %d · aGaps %d · minQ %d · @%.0f+%.0fs",
                result.lossPercent, result.dropped, result.frames,
                result.stalls, result.audioGaps, result.minVideoQueue,
                result.startPosition, result.windowSeconds
            )
            os_signpost(
                .event,
                log: PlaybackPerformance.log,
                name: "Bench Result",
                signpostID: performanceSignpostID,
                "dropped=%{public}d frames=%{public}d percent=%{public}.3f corrupted=%{public}d stalls=%{public}d audioGaps=%{public}d minVideoQueue=%{public}d start=%{public}.2f window=%{public}.2f",
                result.dropped,
                result.frames,
                result.lossPercent,
                result.corrupted,
                result.stalls,
                result.audioGaps,
                result.minVideoQueue,
                result.startPosition,
                result.windowSeconds
            )
        } else if case .warming(let measureFrom) = bench!.phase {
            benchStatus = String(format: "warming · measures @%.0fs", measureFrom)
        } else if case .measuring(let since) = bench!.phase {
            benchStatus = String(format: "measuring %.0f/%.0fs", timePosition - since, bench!.windowSeconds)
        }
    }

    /// Pause the synchronizer, then poll until the demuxer has rebuilt a
    /// safe cushion and restart. (The periodic observer stops firing at
    /// rate 0, so recovery needs its own loop.)
    private func beginStallRecovery() {
        isBuffering = true
        synchronizer.rate = 0
        stallCount += 1
        if !stallSignpostActive {
            stallSignpostActive = true
            os_signpost(
                .begin,
                log: PlaybackPerformance.log,
                name: "Playback Stall",
                signpostID: performanceSignpostID,
                "position=%{public}.3f count=%{public}d",
                timePosition,
                stallCount
            )
        }
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                // A seek or shutdown owns the restart from here.
                if self.shared.withLock({ $0.cancelled || $0.pendingSeekSeconds != nil }) { return }
                if self.videoQueue.count >= 12 || self.videoQueue.isFinished {
                    self.isBuffering = false
                    if self.stallSignpostActive {
                        self.stallSignpostActive = false
                        os_signpost(
                            .end,
                            log: PlaybackPerformance.log,
                            name: "Playback Stall",
                            signpostID: self.performanceSignpostID,
                            "outcome=recovered videoQueued=%{public}d",
                            self.videoQueue.count
                        )
                    }
                    if !self.isPaused {
                        self.synchronizer.rate = 1
                    }
                    return
                }
            }
        }
    }

    private func refreshSubtitles(at seconds: Double) {
        let active = subtitleStore.active(at: seconds)
        if active.text != currentSubtitleText {
            currentSubtitleText = active.text
        }
        if active.images != currentSubtitleImages {
            currentSubtitleImages = active.images
        }
    }

    private func publishStreams(
        duration: Double,
        videoSize: CGSize,
        displayMatch: DisplayMatchRequest?,
        tracks: [PlayerTrack],
        subtitles: [PlayerTrack],
        embeddedSubtitleCount: Int,
        activeSubtitleOrdinal: Int
    ) {
        self.duration = duration
        self.videoSize = videoSize
        displayMatchRequest = displayMatch
        audioTracks = tracks
        subtitleTracks = subtitles
        self.embeddedSubtitleCount = embeddedSubtitleCount
        // An initially-selected external track (server default pointing at
        // a sidecar file) starts its download once the counts are known.
        if activeSubtitleOrdinal > embeddedSubtitleCount {
            loadExternalSubtitle(ordinal: activeSubtitleOrdinal)
        }
    }

    // MARK: - Demux loop (demux queue only)

    nonisolated private func runDemuxLoop(url: URL) {
        do {
            try demuxer.open(url: url.absoluteString)
        } catch {
            let message = (error as? DemuxError)?.errorDescription ?? "The stream could not be opened."
            Task { @MainActor in self.onError?(message) }
            return
        }

        // Ordinals are 1-based positions in the demuxed audio list — the
        // same convention the server-default mapping uses. (Single lock
        // acquisition: nesting withLock deadlocks the non-recursive lock.)
        let initialOrdinal = shared.withLock { state -> Int in
            if state.selectedAudioOrdinal == 0 {
                state.selectedAudioOrdinal = state.initialAudioOrdinal ?? 1
            }
            return state.selectedAudioOrdinal
        }
        applyAudioSelection(ordinal: initialOrdinal)

        let streams = demuxer.audioStreams
        let demuxedDuration = demuxer.durationSeconds
        let size = videoDimensions()
        // Without a known rate there is no meaningful mode to request.
        let displayMatch: DisplayMatchRequest? = if demuxer.videoFrameRate > 0,
            let description = demuxer.videoStream?.formatDescription {
            DisplayMatchRequest(formatDescription: description, frameRate: Float(demuxer.videoFrameRate))
        } else {
            nil
        }
        let tracks = streams.enumerated().map { offset, stream in
            PlayerTrack(
                engineID: offset + 1,
                kind: .audio,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == initialOrdinal
            )
        }

        // Subtitle ordinal space: embedded streams in demux order, then
        // the external tracks — the same layout the controller used to map
        // the server's DefaultSubtitleStreamIndex.
        let embeddedSubtitles = demuxer.subtitleStreams
        let (externals, subtitleOrdinal) = shared.withLock { state -> ([ExternalSubtitleTrack], Int) in
            state.embeddedSubtitleStreamIndices = embeddedSubtitles.map(\.streamIndex)
            if state.selectedSubtitleOrdinal < 0 {
                state.selectedSubtitleOrdinal = state.initialSubtitleOrdinal ?? 0
            }
            let ordinal = state.selectedSubtitleOrdinal
            if ordinal >= 1, ordinal <= embeddedSubtitles.count {
                state.selectedSubtitleStreamIndex = embeddedSubtitles[ordinal - 1].streamIndex
            }
            return (state.externalSubtitles, ordinal)
        }
        let subtitleTracks = embeddedSubtitles.enumerated().map { offset, stream in
            PlayerTrack(
                engineID: offset + 1,
                kind: .subtitle,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == subtitleOrdinal
            )
        } + externals.enumerated().map { offset, track in
            PlayerTrack(
                engineID: embeddedSubtitles.count + offset + 1,
                kind: .subtitle,
                displayName: Self.externalTrackName(for: track),
                isSelected: embeddedSubtitles.count + offset + 1 == subtitleOrdinal
            )
        }
        Task { @MainActor in
            self.publishStreams(
                duration: demuxedDuration,
                videoSize: size,
                displayMatch: displayMatch,
                tracks: tracks,
                subtitles: subtitleTracks,
                embeddedSubtitleCount: embeddedSubtitles.count,
                activeSubtitleOrdinal: subtitleOrdinal
            )
        }

        // The demuxer-side discard state the loop last applied; compared
        // against the shared desired stream each pass so main-actor
        // subtitle switches land without a queue hop.
        var appliedSubtitleStreamIndex: Int32 = -1

        while !shared.withLock({ $0.cancelled }) {
            let desiredSubtitle = shared.withLock { $0.selectedSubtitleStreamIndex }
            if desiredSubtitle != appliedSubtitleStreamIndex {
                demuxer.selectSubtitle(streamIndex: desiredSubtitle >= 0 ? desiredSubtitle : nil)
                appliedSubtitleStreamIndex = desiredSubtitle
            }
            if let target = shared.withLock({ state -> Double? in
                defer {
                    if let target = state.pendingSeekSeconds {
                        // Everything buffered so far is being flushed.
                        state.videoBufferedTo = target
                        state.pendingSeekSeconds = nil
                    }
                }
                return state.pendingSeekSeconds
            }) {
                videoQueue.reset()
                audioQueue.reset()
                applyAudioSelection(ordinal: shared.withLock { $0.selectedAudioOrdinal })
                if target > 0.5 {
                    demuxer.seek(toSeconds: target)
                }
                primeAndStart(at: target)
                continue
            }

            if videoQueue.isFinished {
                // EOF reached; idle until a seek arrives or we shut down.
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            // Bound each stream independently. The old conjunction let one
            // queue grow without limit whenever the other happened to stay
            // below its cap, and polled every 30 ms while both were full.
            // Waiting for the renderer's dequeue signal removes that polling
            // and resumes at a low-water mark so demuxing happens in useful
            // batches instead of one packet per wakeup.
            if videoQueue.count >= 90 {
                videoQueue.waitUntilBelow(72)
                continue
            }
            if audioQueue.count >= 180 {
                audioQueue.waitUntilBelow(144)
                continue
            }
            step()
        }
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Demux Close",
            signpostID: performanceSignpostID
        )
        demuxer.close()
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Demux Close",
            signpostID: performanceSignpostID
        )
    }

    /// One av_read_frame worth of work; routes to the queues.
    nonisolated private func step() {
        switch demuxer.readNext() {
        case .video(let buffer):
            videoQueue.enqueue(buffer)
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if seconds.isFinite {
                // Stall detection compares the clock against this.
                shared.withLock { $0.videoBufferedTo = max($0.videoBufferedTo, seconds) }
            }
            kickPumps()
        case .audio(let buffers, let streamIndex):
            let (selected, delay) = shared.withLock { ($0.selectedAudioStreamIndex, $0.audioDelaySeconds) }
            if streamIndex == selected {
                for buffer in buffers {
                    // Watched pre-delay: the delay shifts every stamp
                    // uniformly, so continuity is the same either side.
                    audioContinuity.observe(buffer)
                    audioQueue.enqueue(delay == 0 ? buffer : Self.retimed(buffer, by: delay))
                }
                kickPumps()
            }
        case .subtitle(let events, let streamIndex):
            guard streamIndex == shared.withLock({ $0.selectedSubtitleStreamIndex }) else { break }
            for event in events {
                switch event {
                case .cue(let cue):
                    subtitleStore.add(cue)
                case .clear(let seconds):
                    subtitleStore.closeOpenCues(at: seconds)
                }
            }
        case .skipped:
            break
        case .endOfFile:
            videoQueue.markFinished()
            audioQueue.markFinished()
        case .failed(let message):
            videoQueue.markFinished()
            audioQueue.markFinished()
            Task { @MainActor in self.onError?("Playback failed in the Lagoon engine (\(message)).") }
            shared.withLock { $0.cancelled = true }
        }
    }

    /// Fill the queues enough that playback can start cleanly, then hand
    /// control back to the main actor to run the clock.
    nonisolated private func primeAndStart(at target: Double) {
        while videoQueue.count < 12, !videoQueue.isFinished, !shared.withLock({ $0.cancelled }) {
            if shared.withLock({ $0.pendingSeekSeconds != nil }) { return }
            step()
        }
        Task { @MainActor in self.beginPlayback(at: target) }
    }

    nonisolated private func applyAudioSelection(ordinal: Int) {
        let streams = demuxer.audioStreams
        guard !streams.isEmpty else { return }
        let index = min(max(ordinal - 1, 0), streams.count - 1)
        let stream = streams[index]
        shared.withLock { $0.selectedAudioStreamIndex = stream.streamIndex }
        demuxer.selectAudio(streamIndex: stream.streamIndex)

        var diagnostic = "\(stream.codecName) · \(stream.channels)ch"
        if stream.isAtmos {
            diagnostic += " · Atmos (JOC)"
        } else if stream.codecName == "eac3" {
            diagnostic += " · no JOC"
        }
        let publishedDiagnostic = diagnostic
        Task { @MainActor in self.audioDiagnostic = publishedDiagnostic }
    }

    /// Copy with all timestamps shifted — how the audio-delay option
    /// lands on compressed passthrough and LPCM buffers alike.
    nonisolated private static func retimed(_ buffer: CMSampleBuffer, by delay: Double) -> CMSampleBuffer {
        var entryCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else { return buffer }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entryCount)
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: entryCount, arrayToFill: &timings, entriesNeededOut: &entryCount
        ) == noErr else { return buffer }
        let offset = CMTime(seconds: delay, preferredTimescale: 90_000)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset
            }
        }
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimed
        ) == noErr, let retimed else { return buffer }
        return retimed
    }

    nonisolated private func videoDimensions() -> CGSize {
        // Format description dimensions come straight from codec parameters.
        guard let description = demuxer.videoStream?.formatDescription else { return .zero }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }

    nonisolated private static func trackName(for stream: DemuxedStream) -> String {
        let language = stream.language.flatMap {
            Locale.current.localizedString(forLanguageCode: $0) ?? $0.uppercased()
        }
        var detail = stream.title
        if detail == nil {
            var facts = Self.friendlyCodecName(stream.codecName)
            if let layout = Self.channelLabel(stream.channels) {
                facts += " \(layout)"
            }
            detail = facts
        }
        var name = [language, detail].compactMap(\.self).joined(separator: " · ")
        // Whether a track carries Atmos is invisible from most mux titles —
        // and it's the fact that decides which track lights the badge.
        if stream.isAtmos, !name.localizedCaseInsensitiveContains("atmos") {
            name += " · Atmos"
        }
        return name.isEmpty ? "Track \(stream.streamIndex)" : name
    }

    nonisolated private static func friendlyCodecName(_ codecName: String) -> String {
        switch codecName {
        case "eac3": "Dolby Digital+"
        case "ac3": "Dolby Digital"
        case "truehd": "Dolby TrueHD"
        case "dts": "DTS"
        default: codecName.uppercased()
        }
    }

    nonisolated private static func channelLabel(_ channels: Int) -> String? {
        switch channels {
        case 0: nil
        case 1: "1.0"
        case 2: "2.0"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels)ch"
        }
    }

    nonisolated private static func externalTrackName(for track: ExternalSubtitleTrack) -> String {
        track.title
            ?? track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            ?? String(localized: "External")
    }

    // MARK: - Renderer pumps (pump queue only)

    nonisolated private func kickPumps() {
        guard pumpKickState.request() else { return }
        pumpQueue.async { [weak self] in
            guard let self else { return }
            repeat {
                self.pumpVideo()
                self.pumpAudio()
            } while self.pumpKickState.completeCycle()
        }
    }

    nonisolated private func pumpVideo() {
        guard let renderer = videoRenderer else { return }
        while renderer.isReadyForMoreMediaData, let buffer = videoQueue.dequeue() {
            renderer.enqueue(buffer)
        }
    }

    nonisolated private func pumpAudio() {
        guard let renderer = audioRenderer else { return }
        while renderer.isReadyForMoreMediaData, let buffer = audioQueue.dequeue() {
            renderer.enqueue(buffer)
        }
    }
}

// MARK: - Support types

/// Mutable state crossed between the main actor, demux loop, and pumps —
/// tiny value types behind one lock.
nonisolated private final class SharedState: @unchecked Sendable {
    struct State {
        var cancelled = false
        var pendingSeekSeconds: Double?
        var selectedAudioOrdinal = 0
        var selectedAudioStreamIndex: Int32 = -1
        var initialAudioOrdinal: Int?
        /// -1 = not yet initialized (the demux loop applies the server
        /// default on open); 0 = subtitles off.
        var selectedSubtitleOrdinal = -1
        var selectedSubtitleStreamIndex: Int32 = -1
        var initialSubtitleOrdinal: Int?
        var embeddedSubtitleStreamIndices: [Int32] = []
        var externalSubtitles: [ExternalSubtitleTrack] = []
        /// Highest video pts the demuxer has delivered (M6 stall detection).
        var videoBufferedTo: Double = 0
        var audioDelaySeconds: Double = 0
    }

    private let lock = NSLock()
    private var state = State()

    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// Counts timestamp discontinuities in the audio buffers handed to the
/// renderer — the measurable form of "the audio crackles" (HEL-64). Each
/// buffer is expected to start exactly where the previous one ended; a
/// mismatch beyond 1 ms is the renderer being told to leave a gap or
/// overlap in the decoded stream. Written on the demux queue, read from
/// the main actor for the HUD and bench.
nonisolated private final class AudioContinuityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedNext: CMTime?
    private var gaps = 0

    var gapCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return gaps
    }

    /// Seek/flush: the next buffer starts a new chain, not a gap.
    func reset() {
        lock.lock()
        expectedNext = nil
        lock.unlock()
    }

    func observe(_ buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid else { return }
        let duration = CMSampleBufferGetDuration(buffer)
        lock.lock()
        if let expectedNext, abs(CMTimeSubtract(pts, expectedNext).seconds) > 0.001 {
            gaps += 1
        }
        expectedNext = duration.isValid ? CMTimeAdd(pts, duration) : nil
        lock.unlock()
    }
}

/// Thread-safe FIFO of ready-to-enqueue sample buffers.
nonisolated final class SampleBufferQueue: @unchecked Sendable {
    private let condition = NSCondition()
    // A head-indexed buffer avoids Array.removeFirst() shifting every
    // retained sample on every renderer dequeue. Consumed slots are nilled
    // immediately, then compacted in batches to keep memory bounded.
    private var buffers: [CMSampleBuffer?] = []
    private var head = 0
    private var finished = false
    private var waitsInterrupted = false

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffers.count - head
    }

    var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finished
    }

    func enqueue(_ buffer: CMSampleBuffer) {
        condition.lock()
        buffers.append(buffer)
        condition.unlock()
    }

    func dequeue() -> CMSampleBuffer? {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count else { return nil }
        let buffer = buffers[head]
        buffers[head] = nil
        head += 1
        if head >= 64, head * 2 >= buffers.count {
            buffers.removeFirst(head)
            head = 0
        }
        condition.signal()
        return buffer
    }

    func markFinished() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func reset() {
        condition.lock()
        buffers.removeAll()
        head = 0
        finished = false
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks the producer without polling until the consumer has drained
    /// a useful amount of work, EOF/reset occurs, or shutdown interrupts it.
    func waitUntilBelow(_ targetCount: Int) {
        condition.lock()
        while buffers.count - head >= targetCount, !finished, !waitsInterrupted {
            condition.wait()
        }
        condition.unlock()
    }

    func interruptWaits() {
        condition.lock()
        waitsInterrupted = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Coalesces the per-packet wakeups sent to the serial renderer queue.
/// Without it a fast demux pass can enqueue hundreds of pump blocks that
/// mostly discover an already-full AVFoundation renderer.
nonisolated private final class PumpKickState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    private var requestedAgain = false

    /// Returns true only for the request that must schedule the worker.
    func request() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if scheduled {
            requestedAgain = true
            return false
        }
        scheduled = true
        return true
    }

    /// Returns true when work arrived during the completed pump cycle.
    func completeCycle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if requestedAgain {
            requestedAgain = false
            return true
        }
        scheduled = false
        return false
    }
}
