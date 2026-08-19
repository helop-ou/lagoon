import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OSLog

/// HEL-48 M1: the Lagoon playback engine — libavformat demux into
/// CMSampleBuffers rendered by AVSampleBufferDisplayLayer /
/// AVSampleBufferAudioRenderer under an AVSampleBufferRenderSynchronizer.
/// VideoToolbox/libavcodec and AVFoundation perform codec work, color
/// management, presentation, and audio output (see HEL-48).
///
/// The app's only playback engine since 2026-08-16 (Jaagop's call: one
/// player for everything). Envelope: h264 video passed through compressed;
/// HEVC is hardware-decoded ahead with VideoToolbox; VC-1 is software-decoded
/// into Core Video frames; aac/mp3/ac3/eac3 audio passed through compressed and
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
    /// Flips true the moment a bench window freezes its result — the
    /// harness's auto-exit hook (debug.benchAutoExit), so scripted runs
    /// can leave the player through the clean teardown path instead of
    /// being killed mid-playback.
    private(set) var benchCompleted = false
    /// The display-matching request for this video (HEL-64) — published
    /// once the demuxer knows the stream; the player view owns applying it.
    private(set) var displayMatchRequest: DisplayMatchRequest?
    /// "grid 24000/1001" when video pts are snapped to the exact frame
    /// grid, nil when container stamps pass through (HEL-64 gate check).
    private(set) var videoTimingDiagnostic: String?

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
    @ObservationIgnored var onTrackSelectionChanged: (() -> Void)?

    // MARK: Cross-thread state

    @ObservationIgnored nonisolated private let demuxer = FFmpegDemuxer()
    @ObservationIgnored nonisolated private let videoQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let audioQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let demuxQueue = DispatchQueue(label: "ee.helop.lagoon.demux", qos: .userInitiated)
    @ObservationIgnored nonisolated private let pumpQueue = DispatchQueue(label: "ee.helop.lagoon.pump", qos: .userInteractive)
    @ObservationIgnored nonisolated private let pumpKickState = PumpKickState()
    @ObservationIgnored nonisolated private let performanceSignpostID = OSSignpostID(log: PlaybackPerformance.log)
    @ObservationIgnored nonisolated private let lifecycleID = UUID()
    @ObservationIgnored nonisolated private let audioContinuity = AudioContinuityMonitor()
    @ObservationIgnored nonisolated(unsafe) private var videoDecoder: VideoToolboxDecoder?
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
    @ObservationIgnored private var finishObserver: Any?
    @ObservationIgnored private var didFinish = false
    @ObservationIgnored private var stallRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var stallSignpostActive = false
    @ObservationIgnored private var shutdownRequested = false
    @ObservationIgnored private var rendererNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var rendererRecoveryInProgress = false

    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingStartSeconds: Double = 0

    init() {
        PlaybackLifecycleDiagnostics.engineCreated(lifecycleID)
    }

    deinit {
        PlaybackLifecycleDiagnostics.engineDestroyed(lifecycleID)
    }

    func prepare(
        url: URL,
        startSeconds: Double,
        initialAudioOrdinal: Int?,
        initialSubtitleOrdinal: Int? = nil,
        audioTrackMetadata: [PlayerTrackMetadata] = [],
        embeddedSubtitleMetadata: [PlayerTrackMetadata] = [],
        externalSubtitles: [ExternalSubtitleTrack] = []
    ) {
        pendingURL = url
        pendingStartSeconds = startSeconds
        self.externalSubtitles = externalSubtitles
        shared.withLock {
            $0.initialAudioOrdinal = initialAudioOrdinal
            $0.initialSubtitleOrdinal = initialSubtitleOrdinal
            $0.audioTrackMetadata = audioTrackMetadata
            $0.embeddedSubtitleMetadata = embeddedSubtitleMetadata
            $0.externalSubtitles = externalSubtitles
        }
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        guard videoRenderer == nil, let url = pendingURL else { return }

        // Debug switches, read once per playback like the HUD's: the strip
        // experiment must not change mid-A/B, and the bench arms in
        // beginPlayback.
        demuxer.stripEnhancementLayer = UserDefaults.standard.bool(forKey: "debug.stripDoviEL")
        demuxer.markDroppableFrames = UserDefaults.standard.bool(forKey: "debug.markDroppableFrames")
        benchEnabled = UserDefaults.standard.bool(forKey: "debug.frameLossBench")

        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Attach",
            signpostID: performanceSignpostID
        )

        let video = displayLayer.sampleBufferRenderer
        let audio = AVSampleBufferAudioRenderer()
        videoRenderer = video
        audioRenderer = audio
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)
        PlaybackLifecycleDiagnostics.renderersAttached(lifecycleID)
        observeVideoRenderer(video)

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

        shared.withLock {
            $0.pendingSeekSeconds = max(pendingStartSeconds, 0)
            $0.playbackGeneration += 1
        }
        let startURL = url
        let recommendedPixelBufferAttributes = video.recommendedPixelBufferAttributes
        PlaybackLifecycleDiagnostics.demuxStarted(lifecycleID)
        let demuxLifecycleID = lifecycleID
        demuxQueue.async { [weak self] in
            guard let self else {
                // An immediate dismissal can release an engine before this
                // serial block begins. No demuxer was opened in that case,
                // but the diagnostic start still needs an exact counterpart.
                PlaybackLifecycleDiagnostics.demuxEnded(demuxLifecycleID)
                return
            }
            self.runDemuxLoop(
                url: startURL,
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
            )
        }
    }

    // MARK: - Transport (PlayerEngine)

    func play() {
        guard isPaused || synchronizer.rate == 0 else { return }
        isPaused = false
        // A buffering engine resumes when its queue gate is satisfied;
        // forcing rate 1 here would run its timebase ahead of the samples.
        if !isBuffering {
            synchronizer.rate = 1
        }
        rearmBench(at: timePosition)
    }

    func pause() {
        guard !isPaused || synchronizer.rate > 0 else { return }
        synchronizer.rate = 0
        isPaused = true
        rearmBench(at: timePosition)
    }

    func togglePause() {
        if isPaused {
            play()
        } else {
            pause()
        }
        // Touching the transport ends a controlled measurement window;
        // the bench re-arms from wherever playback continues.
    }

    func seek(by seconds: Double) {
        seek(to: timePosition + seconds)
    }

    func selectAudioTrack(id: Int?) {
        guard let id, id - 1 < audioTracks.count else { return }
        shared.withLock { $0.selectedAudioOrdinal = id }
        audioTracks = audioTracks.map {
            PlayerTrack(
                engineID: $0.engineID,
                kind: .audio,
                displayName: $0.displayName,
                isSelected: $0.engineID == id,
                languageTag: $0.languageTag,
                isForced: $0.isForced,
                isHearingImpaired: $0.isHearingImpaired,
                source: $0.source
            )
        }
        onTrackSelectionChanged?()
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
            PlayerTrack(
                engineID: $0.engineID,
                kind: .subtitle,
                displayName: $0.displayName,
                isSelected: $0.engineID == ordinal,
                languageTag: $0.languageTag,
                isForced: $0.isForced,
                isHearingImpaired: $0.isHearingImpaired,
                source: $0.source
            )
        }
        onTrackSelectionChanged?()
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
        let track = externalSubtitles[index]
        let token = externalLoadToken
        Task { [weak self] in
            let data: Data
            if let preloadedData = track.preloadedData {
                data = preloadedData
            } else {
                guard let response = try? await URLSession.shared.data(from: track.url) else { return }
                data = response.0
            }
            let cues = await Task.detached { SubtitleParser.cues(from: data) }.value
            guard let self, self.externalLoadToken == token else { return }
            self.subtitleStore.replaceAll(cues)
        }
    }

    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {
        guard !shutdownRequested else { return }
        externalSubtitles.append(track)
        shared.withLock { $0.externalSubtitles = externalSubtitles }
        let ordinal = embeddedSubtitleCount + externalSubtitles.count
        subtitleTracks = subtitleTracks.map {
            PlayerTrack(
                engineID: $0.engineID,
                kind: .subtitle,
                displayName: $0.displayName,
                isSelected: false,
                languageTag: $0.languageTag,
                isForced: $0.isForced,
                isHearingImpaired: $0.isHearingImpaired,
                source: $0.source
            )
        } + [PlayerTrack(
            engineID: ordinal,
            kind: .subtitle,
            displayName: Self.externalTrackName(for: track),
            isSelected: true,
            languageTag: track.language,
            isForced: track.isForced,
            isHearingImpaired: track.isHearingImpaired,
            source: track.isDownloaded ? .downloaded : .external
        )]
        selectSubtitleTrack(id: ordinal)
    }

    func shutdown() {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        PlaybackLifecycleDiagnostics.engineShutdownStarted(lifecycleID)
        for token in rendererNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        rendererNotificationTokens.removeAll()
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
        removeFinishObserver()
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
                corruptedFrames: metrics.numberOfCorruptedFrames,
                optimizedCompositingFrames: metrics.numberOfFramesDisplayedUsingOptimizedCompositing,
                accumulatedFrameDelay: metrics.totalAccumulatedFrameDelay
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
        removals.notify(queue: pumpQueue) { [performanceSignpostID, lifecycleID] in
            PlaybackLifecycleDiagnostics.renderersDetached(lifecycleID)
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
        didFinish = false
        removeFinishObserver()
        isBuffering = true
        synchronizer.rate = 0
        shared.withLock {
            $0.pendingSeekSeconds = clamped
            $0.playbackGeneration += 1
        }
        // Enqueue, flush, and queue reset share the pump queue. This makes
        // Apple's post-flush keyframe rule deterministic: an in-flight old
        // sample cannot race in after the flush.
        pumpQueue.sync { [self] in
            videoRenderer?.flush()
            audioRenderer?.flush()
            videoQueue.reset()
            audioQueue.reset()
            shared.withLock { $0.firstEnqueuedVideoPTS = nil }
        }
        // The pts chain restarts at the target; the first buffer after a
        // flush must not read as a discontinuity.
        audioContinuity.reset()
        // Embedded cues re-arrive from the demuxer after the seek; leaving
        // the old ones would duplicate them. External cue lists are
        // complete and position-independent, so they stay.
        let embeddedSubtitleActive = shared.withLock { state -> Bool in
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
    private func beginPlayback(at seconds: Double, firstVideoPTS: CMTime?) {
        // High-precision anchor: at a display matched to the content rate
        // every frame has one vsync of slack, and a coarse (600/s) anchor
        // already spends up to 1.7 ms of it before playback begins.
        let time = PlaybackClockAnchor.mediaTime(
            targetSeconds: seconds,
            firstVideoPTS: firstVideoPTS
        )
        timePosition = time.seconds
        isBuffering = false
        if isPaused {
            synchronizer.setRate(0, time: time)
        } else {
            // Apple's recommended custom-playback start: bind media time to
            // a near-future host time so queued renderers reach the first
            // presentation deadline together instead of starting late.
            let hostTime = CMTimeAdd(
                CMClockGetTime(CMClockGetHostTimeClock()),
                CMTime(seconds: 0.1, preferredTimescale: 1_000_000_000)
            )
            synchronizer.setRate(1, time: time, atHostTime: hostTime)
        }
        kickPumps()
        rearmBench(at: time.seconds)
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Playback Cushion Ready",
            signpostID: performanceSignpostID,
            "position=%{public}.3f",
            time.seconds
        )
    }

    /// EOF is a renderer-timeline event, not a queue-depth heuristic. The
    /// demuxer can finish while AVFoundation still owns buffered media; a
    /// boundary observer lets those samples present before advancing.
    private func armFinishBoundary(at seconds: Double, generation: Int) {
        guard !shutdownRequested, !didFinish, seconds.isFinite else { return }
        let isCurrent = shared.withLock { !$0.cancelled && $0.playbackGeneration == generation }
        guard isCurrent else { return }
        removeFinishObserver()
        if timePosition >= seconds {
            finishPlayback(generation: generation)
            return
        }
        let boundary = CMTime(seconds: seconds, preferredTimescale: 240_000)
        finishObserver = synchronizer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundary)],
            queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishPlayback(generation: generation)
            }
        }
    }

    private func finishPlayback(generation: Int) {
        let isCurrent = shared.withLock { !$0.cancelled && $0.playbackGeneration == generation }
        guard isCurrent, !didFinish else { return }
        didFinish = true
        removeFinishObserver()
        onFinished?()
    }

    private func removeFinishObserver() {
        guard let finishObserver else { return }
        synchronizer.removeTimeObserver(finishObserver)
        self.finishObserver = nil
    }

    // MARK: - Renderer recovery

    private func observeVideoRenderer(_ renderer: AVSampleBufferVideoRenderer) {
        let center = NotificationCenter.default
        rendererNotificationTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] _ in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                self.recoverVideoRendererIfRequired(renderer)
            }
        })
        rendererNotificationTokens.append(center.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] notification in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                self.handleVideoRendererFailure(renderer, notification: notification)
            }
        })
    }

    private func recoverVideoRendererIfRequired(_ renderer: AVSampleBufferVideoRenderer) {
        guard !shutdownRequested,
              renderer === videoRenderer,
              renderer.requiresFlushToResumeDecoding,
              !rendererRecoveryInProgress else { return }
        rendererRecoveryInProgress = true
        let recoveryPosition = timePosition
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=requiresFlush",
            recoveryPosition
        )
        seek(to: recoveryPosition)
        rendererRecoveryInProgress = false
    }

    private func handleVideoRendererFailure(
        _ renderer: AVSampleBufferVideoRenderer,
        notification: Notification
    ) {
        guard !shutdownRequested, renderer === videoRenderer else { return }
        if renderer.requiresFlushToResumeDecoding {
            recoverVideoRendererIfRequired(renderer)
            return
        }
        let notificationError = notification.userInfo?[
            AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey
        ] as? Error
        let detail = notificationError?.localizedDescription
            ?? renderer.error?.localizedDescription
            ?? "unknown renderer error"
        onError?("Playback failed in the Lagoon video renderer (\(detail)).")
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
        benchCompleted = false
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
            videoQueueDepth: videoQueue.count,
            optimizedFrames: snapshot.optimizedCompositingFrames,
            accumulatedDelay: snapshot.accumulatedFrameDelay
        )
        if let result = bench!.record(sample) {
            benchStatus = String(
                format: "%.2f%% (%d/%d) · stalls %d · aGaps %d · minQ %d · @%.0f+%.0fs",
                result.lossPercent, result.dropped, result.frames,
                result.stalls, result.audioGaps, result.minVideoQueue,
                result.startPosition, result.windowSeconds
            )
            // Plain stdout beside the signpost: `devicectl ... --console`
            // streams this from a real device, where the unified log is
            // out of reach for a headless harness (HEL-64). Carries the
            // gate states so a remote run is self-describing.
            var gates = "vtime=\"\(videoTimingDiagnostic ?? "container")\""
            gates += " droppable=\"\(demuxer.markDroppableFrames ? "on" : "off")\""
            if let stats = demuxer.enhancementLayerStripStats {
                gates += " elStrip=\"on \(stats.units) units \(stats.bytes) bytes\""
            } else {
                gates += " elStrip=\"off\""
            }
            gates += " hud=\"\(UserDefaults.standard.bool(forKey: "debug.playbackHUD") ? "on" : "off")\""
            #if os(tvOS)
            gates += " display=\"\(DisplayModeMatcher.statusDescription)\""
            #endif
            print("BenchResult dropped=\(result.dropped) frames=\(result.frames) "
                + String(format: "percent=%.3f", result.lossPercent)
                + " corrupted=\(result.corrupted) stalls=\(result.stalls)"
                + " audioGaps=\(result.audioGaps) minVideoQueue=\(result.minVideoQueue)"
                + " optimized=\(result.optimizedFrames)"
                + String(format: " delayMs=%.1f", result.accumulatedDelay * 1000)
                + String(format: " start=%.2f window=%.2f ", result.startPosition, result.windowSeconds)
                + gates)
            benchCompleted = true
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
        let recoveryStarted = ContinuousClock.now
        stallRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                // A seek or shutdown owns the restart from here.
                if self.shared.withLock({ $0.cancelled || $0.pendingSeekSeconds != nil }) { return }
                let decision = StallRecoveryPolicy.decision(
                    elapsed: ContinuousClock.now - recoveryStarted,
                    videoQueueCount: self.videoQueue.count,
                    videoQueueFinished: self.videoQueue.isFinished
                )
                switch decision {
                case .wait:
                    continue
                case .resume:
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
                case .reprime:
                    let recoveryPosition = self.timePosition
                    if self.stallSignpostActive {
                        self.stallSignpostActive = false
                        os_signpost(
                            .end,
                            log: PlaybackPerformance.log,
                            name: "Playback Stall",
                            signpostID: self.performanceSignpostID,
                            "outcome=reprime videoQueued=%{public}d",
                            self.videoQueue.count
                        )
                    }
                    os_signpost(
                        .event,
                        log: PlaybackPerformance.log,
                        name: "Playback Stall Reprime",
                        signpostID: self.performanceSignpostID,
                        "position=%{public}.3f count=%{public}d",
                        recoveryPosition,
                        self.stallCount
                    )
                    // A bounded seek rebuilds both renderer queues and the
                    // clock anchor. This prevents a slow or lost network
                    // read from leaving rate=0 in an endless polling task.
                    self.seek(to: recoveryPosition)
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
        videoTiming: String?,
        tracks: [PlayerTrack],
        subtitles: [PlayerTrack],
        embeddedSubtitleCount: Int,
        activeSubtitleOrdinal: Int
    ) {
        self.duration = duration
        self.videoSize = videoSize
        displayMatchRequest = displayMatch
        videoTimingDiagnostic = videoTiming
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

    nonisolated private func runDemuxLoop(
        url: URL,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes
    ) {
        defer {
            PlaybackLifecycleDiagnostics.demuxEnded(lifecycleID)
        }
        do {
            try demuxer.open(
                url: url.absoluteString,
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
            )
        } catch {
            let message = (error as? DemuxError)?.errorDescription ?? "The stream could not be opened."
            Task { @MainActor in self.onError?(message) }
            return
        }
        if demuxer.videoStream?.codecName == "hevc",
           let description = demuxer.videoStream?.formatDescription {
            do {
                videoDecoder = try VideoToolboxDecoder(
                    formatDescription: description,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                    reportedReorderDepth: demuxer.videoStream?.videoReorderDepth ?? 0,
                    outputHandler: { [weak self] buffer in
                        self?.acceptDecodedVideo(buffer)
                    },
                    errorHandler: { [weak self] error in
                        self?.failVideoDecode(error)
                    }
                )
            } catch {
                failVideoDecode(error)
                demuxer.close()
                return
            }
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
        let audioMetadata = shared.withLock { $0.audioTrackMetadata }
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
            let metadata = audioMetadata.indices.contains(offset) ? audioMetadata[offset] : nil
            return PlayerTrack(
                engineID: offset + 1,
                kind: .audio,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == initialOrdinal,
                languageTag: metadata?.languageTag ?? stream.language,
                isForced: metadata?.isForced ?? false,
                isHearingImpaired: metadata?.isHearingImpaired ?? false
            )
        }

        // Subtitle ordinal space: embedded streams in demux order, then
        // the external tracks — the same layout the controller used to map
        // the server's DefaultSubtitleStreamIndex.
        let embeddedSubtitles = demuxer.subtitleStreams
        let (externals, subtitleMetadata, subtitleOrdinal) = shared.withLock { state -> ([ExternalSubtitleTrack], [PlayerTrackMetadata], Int) in
            state.embeddedSubtitleStreamIndices = embeddedSubtitles.map(\.streamIndex)
            if state.selectedSubtitleOrdinal < 0 {
                state.selectedSubtitleOrdinal = state.initialSubtitleOrdinal ?? 0
            }
            let ordinal = state.selectedSubtitleOrdinal
            if ordinal >= 1, ordinal <= embeddedSubtitles.count {
                state.selectedSubtitleStreamIndex = embeddedSubtitles[ordinal - 1].streamIndex
            }
            return (state.externalSubtitles, state.embeddedSubtitleMetadata, ordinal)
        }
        let subtitleTracks = embeddedSubtitles.enumerated().map { offset, stream in
            let metadata = subtitleMetadata.indices.contains(offset) ? subtitleMetadata[offset] : nil
            return PlayerTrack(
                engineID: offset + 1,
                kind: .subtitle,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == subtitleOrdinal,
                languageTag: metadata?.languageTag ?? stream.language,
                isForced: metadata?.isForced ?? false,
                isHearingImpaired: metadata?.isHearingImpaired ?? false
            )
        } + externals.enumerated().map { offset, track in
            PlayerTrack(
                engineID: embeddedSubtitles.count + offset + 1,
                kind: .subtitle,
                displayName: Self.externalTrackName(for: track),
                isSelected: embeddedSubtitles.count + offset + 1 == subtitleOrdinal,
                languageTag: track.language,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                source: track.isDownloaded ? .downloaded : .external
            )
        }
        Task { @MainActor in
            self.publishStreams(
                duration: demuxedDuration,
                videoSize: size,
                displayMatch: displayMatch,
                videoTiming: demuxer.videoGridDescription.map {
                    if demuxer.outputsDecodedVideo {
                        "grid \($0) · libavcodec VC-1 SW"
                    } else if let videoDecoder {
                        "grid \($0) · VideoToolbox HW · reorder \(videoDecoder.reorderDepth)"
                    } else {
                        "grid \($0)"
                    }
                },
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
        // Opening at zero is already positioned correctly. Every later
        // request—including a seek back to exactly zero—must reposition so
        // the first compressed sample after Apple's renderer flush is a
        // clean random-access point.
        var hasPrimedPlayback = false

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
                        state.mediaEndSeconds = target
                        state.pendingSeekSeconds = nil
                    }
                }
                return state.pendingSeekSeconds
            }) {
                if hasPrimedPlayback || target > 0 {
                    do {
                        try demuxer.seek(toSeconds: target)
                    } catch {
                        let message = (error as? DemuxError)?.errorDescription
                            ?? "The stream could not seek to that position."
                        shared.withLock { $0.cancelled = true }
                        videoQueue.markFinished()
                        audioQueue.markFinished()
                        Task { @MainActor in self.onError?(message) }
                        break
                    }
                }
                do {
                    try videoDecoder?.reset()
                } catch {
                    failVideoDecode(error)
                    break
                }
                videoQueue.reset()
                audioQueue.reset()
                applyAudioSelection(ordinal: shared.withLock { $0.selectedAudioOrdinal })
                hasPrimedPlayback = true
                primeAndStart(at: target)
                continue
            }

            if videoQueue.isFinished {
                // EOF reached; idle until a seek arrives or we shut down.
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            // The streams are interleaved behind one demux cursor. Blocking
            // solely because video is full also prevents later audio packets
            // from being read. On three-second VC-1 transcode fragments that
            // let the audio renderer run dry while video still held nearly
            // two seconds. The policy keeps the useful batched hysteresis,
            // but yields a soft limit when the other stream needs data. Hard
            // limits still bound compressed packets and decoded 4K surfaces.
            switch DemuxBackpressurePolicy.decision(
                videoCount: videoQueue.count,
                audioCount: audioQueue.count,
                audioBufferedSeconds: audioQueue.bufferedDuration,
                videoFrameRate: demuxer.videoFrameRate,
                videoIsDecoded: videoDecoder != nil || demuxer.outputsDecodedVideo,
                hasAudio: !demuxer.audioStreams.isEmpty
            ) {
            case .read:
                step()
            case .waitForVideo(let target):
                videoQueue.waitUntilBelow(target)
            case .waitForAudio(let target):
                audioQueue.waitUntilBelow(target)
            }
        }
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Demux Close",
            signpostID: performanceSignpostID
        )
        videoDecoder?.invalidate()
        videoDecoder = nil
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
            recordMediaEnd(buffer)
            if let videoDecoder {
                do {
                    try videoDecoder.decode(buffer)
                } catch {
                    failVideoDecode(error)
                }
            } else {
                videoQueue.enqueue(buffer)
                kickPumps()
            }
            let seconds = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            if seconds.isFinite {
                // Stall detection compares the clock against this.
                shared.withLock { $0.videoBufferedTo = max($0.videoBufferedTo, seconds) }
            }
        case .audio(let buffers, let streamIndex):
            let (selected, delay) = shared.withLock { ($0.selectedAudioStreamIndex, $0.audioDelaySeconds) }
            if streamIndex == selected {
                for buffer in buffers {
                    // Watched pre-delay: the delay shifts every stamp
                    // uniformly, so continuity is the same either side.
                    audioContinuity.observe(buffer)
                    let output = delay == 0 ? buffer : Self.retimed(buffer, by: delay)
                    recordMediaEnd(output)
                    audioQueue.enqueue(output)
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
            do {
                try videoDecoder?.finish()
            } catch {
                failVideoDecode(error)
                return
            }
            videoQueue.markFinished()
            audioQueue.markFinished()
            let (sampledEnd, generation) = shared.withLock { ($0.mediaEndSeconds, $0.playbackGeneration) }
            if let end = PlaybackEndBoundary.endTime(
                sampledEnd: sampledEnd,
                declaredDuration: demuxer.durationSeconds
            ) {
                Task { @MainActor in
                    self.armFinishBoundary(at: end, generation: generation)
                }
            }
        case .failed(let message):
            videoQueue.markFinished()
            audioQueue.markFinished()
            Task { @MainActor in self.onError?("Playback failed in the Lagoon engine (\(message)).") }
            shared.withLock { $0.cancelled = true }
        }
    }

    nonisolated private func acceptDecodedVideo(_ buffer: CMSampleBuffer) {
        let shouldDrop = shared.withLock { $0.cancelled || $0.pendingSeekSeconds != nil }
        guard !shouldDrop else { return }
        videoQueue.enqueue(buffer)
        kickPumps()
    }

    nonisolated private func recordMediaEnd(_ buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid, pts.seconds.isFinite else { return }
        let sampleDuration = CMSampleBufferGetDuration(buffer)
        let end = sampleDuration.isValid && sampleDuration.seconds.isFinite
            ? CMTimeAdd(pts, sampleDuration).seconds
            : pts.seconds
        guard end.isFinite else { return }
        shared.withLock { $0.mediaEndSeconds = max($0.mediaEndSeconds, end) }
    }

    nonisolated private func failVideoDecode(_ error: Error) {
        let wasAlreadyCancelled = shared.withLock { state -> Bool in
            let previous = state.cancelled
            state.cancelled = true
            return previous
        }
        guard !wasAlreadyCancelled else { return }
        videoQueue.markFinished()
        audioQueue.markFinished()
        videoQueue.interruptWaits()
        audioQueue.interruptWaits()
        demuxer.interrupt()
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Task { @MainActor in
            self.onError?("Playback failed in the Lagoon engine (\(detail)).")
        }
    }

    /// Fill the queues enough that playback can start cleanly, then hand
    /// control back to the main actor to run the clock.
    nonisolated private func primeAndStart(at target: Double) {
        let generation = shared.withLock { $0.playbackGeneration }
        let hasAudio = !demuxer.audioStreams.isEmpty
        let videoHardLimit = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: videoDecoder != nil || demuxer.outputsDecodedVideo
        )
        while (videoQueue.count < 12 || (hasAudio && audioQueue.bufferedDuration < 1.25)),
              videoQueue.count < videoHardLimit,
              !videoQueue.isFinished,
              !shared.withLock({ $0.cancelled }) {
            if shared.withLock({ $0.pendingSeekSeconds != nil }) { return }
            step()
        }
        // Run after any already-scheduled pump blocks. If the renderer can
        // accept data, this records the real first enqueued video PTS for the
        // host-clock anchor; otherwise the target remains the safe fallback.
        pumpQueue.async { [weak self] in
            guard let self else { return }
            let isCurrentGeneration = self.shared.withLock {
                !$0.cancelled
                    && $0.pendingSeekSeconds == nil
                    && $0.playbackGeneration == generation
            }
            guard isCurrentGeneration else { return }
            self.pumpVideo()
            self.pumpAudio()
            let firstVideoPTS = self.shared.withLock { $0.firstEnqueuedVideoPTS }
            Task { @MainActor in
                let isStillCurrent = self.shared.withLock {
                    !$0.cancelled
                        && $0.pendingSeekSeconds == nil
                        && $0.playbackGeneration == generation
                }
                guard isStillCurrent else { return }
                self.beginPlayback(at: target, firstVideoPTS: firstVideoPTS)
            }
        }
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
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts.isValid {
                shared.withLock { state in
                    if state.firstEnqueuedVideoPTS == nil {
                        state.firstEnqueuedVideoPTS = pts
                    }
                }
            }
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

nonisolated enum StallRecoveryDecision: Equatable {
    case wait
    case resume
    case reprime
}

/// Pure policy behind the asynchronous recovery loop so an infinite stall is
/// a deterministic unit-test failure. Twelve decoded frames matches the
/// demuxer's low-water cushion; five seconds is long enough for the normal
/// network refill path but bounded well below a visibly frozen player.
nonisolated enum StallRecoveryPolicy {
    static let resumeVideoCount = 12
    static let reprimeAfter: Duration = .seconds(5)

    static func decision(
        elapsed: Duration,
        videoQueueCount: Int,
        videoQueueFinished: Bool
    ) -> StallRecoveryDecision {
        if videoQueueCount >= resumeVideoCount || videoQueueFinished {
            return .resume
        }
        if elapsed >= reprimeAfter {
            return .reprime
        }
        return .wait
    }
}

/// Mutable state crossed between the main actor, demux loop, and pumps —
/// tiny value types behind one lock.
nonisolated private final class SharedState: @unchecked Sendable {
    struct State {
        var cancelled = false
        var pendingSeekSeconds: Double?
        /// Invalidates an already-primed start when a newer seek is issued.
        var playbackGeneration = 0
        var selectedAudioOrdinal = 0
        var selectedAudioStreamIndex: Int32 = -1
        var initialAudioOrdinal: Int?
        /// -1 = not yet initialized (the demux loop applies the server
        /// default on open); 0 = subtitles off.
        var selectedSubtitleOrdinal = -1
        var selectedSubtitleStreamIndex: Int32 = -1
        var initialSubtitleOrdinal: Int?
        var audioTrackMetadata: [PlayerTrackMetadata] = []
        var embeddedSubtitleMetadata: [PlayerTrackMetadata] = []
        var embeddedSubtitleStreamIndices: [Int32] = []
        var externalSubtitles: [ExternalSubtitleTrack] = []
        /// Highest video pts the demuxer has delivered (M6 stall detection).
        var videoBufferedTo: Double = 0
        /// Furthest presentation end observed across audio and video. EOF
        /// uses this as the renderer boundary even without container duration.
        var mediaEndSeconds: Double = 0
        var audioDelaySeconds: Double = 0
        /// First sample actually accepted by the renderer after attach/flush.
        var firstEnqueuedVideoPTS: CMTime?
    }

    private let lock = NSLock()
    private var state = State()

    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// Chooses the media-time side of Apple's host-clock playback anchor. A seek
/// may enqueue pre-target reference frames, so only advance to the first
/// enqueued PTS when it is at or beyond the requested position.
nonisolated enum PlaybackClockAnchor {
    static func mediaTime(targetSeconds: Double, firstVideoPTS: CMTime?) -> CMTime {
        let target = CMTime(seconds: max(targetSeconds, 0), preferredTimescale: 240_000)
        guard let firstVideoPTS,
              firstVideoPTS.isValid,
              firstVideoPTS.seconds.isFinite,
              CMTimeCompare(firstVideoPTS, target) >= 0 else { return target }
        return firstVideoPTS
    }
}

/// Resolves EOF against media actually observed. A container duration is a
/// fallback only: it can be absent for a finite stream or outlive a truncated
/// input, while the last sample end is the renderer's real timeline boundary.
nonisolated enum PlaybackEndBoundary {
    static func endTime(sampledEnd: Double, declaredDuration: Double) -> Double? {
        if sampledEnd.isFinite, sampledEnd > 0 {
            return sampledEnd
        }
        if declaredDuration.isFinite, declaredDuration >= 0 {
            return declaredDuration
        }
        return nil
    }
}

nonisolated enum DemuxBackpressureDecision: Equatable {
    case read
    case waitForVideo(below: Int)
    case waitForAudio(below: Int)
}

/// Balances two streams read through one interleaved demux cursor. Soft
/// limits drain queues in batches when both streams are healthy. If one side
/// is short, the fuller side may grow only to a hard limit and is then paced
/// one dequeue at a time so the cursor can still reach packets for the side
/// that needs them.
nonisolated enum DemuxBackpressurePolicy {
    private static let audioHighWater = 180
    private static let audioLowWater = 144
    private static let audioHardWater = 270
    private static let audioSafetySeconds = 1.25

    static func videoHardLimit(videoIsDecoded: Bool) -> Int {
        videoIsDecoded ? 30 : 120
    }

    static func decision(
        videoCount: Int,
        audioCount: Int,
        audioBufferedSeconds: Double,
        videoFrameRate: Double,
        videoIsDecoded: Bool,
        hasAudio: Bool
    ) -> DemuxBackpressureDecision {
        let videoHighWater = videoIsDecoded ? 18 : 90
        let videoLowWater = videoIsDecoded ? 12 : 72
        let videoHardWater = videoHardLimit(videoIsDecoded: videoIsDecoded)
        let safeFrameRate = videoFrameRate.isFinite && videoFrameRate >= 1
            ? videoFrameRate
            : 24

        if videoCount >= videoHighWater {
            let drainSeconds = Double(max(videoCount - videoLowWater, 0)) / safeFrameRate
            let audioCanCoverDrain = !hasAudio
                || audioBufferedSeconds >= audioSafetySeconds + drainSeconds
            if audioCanCoverDrain {
                return .waitForVideo(below: videoLowWater)
            }
            if videoCount >= videoHardWater {
                // Wait for one slot, not a full batch: demuxing at playback
                // cadence keeps reaching interleaved audio without exceeding
                // the absolute video-memory limit.
                return .waitForVideo(below: videoHardWater)
            }
            return .read
        }

        if hasAudio, audioCount >= audioHighWater {
            let videoSafetyCount = videoIsDecoded ? 12 : 36
            if videoCount >= videoSafetyCount {
                return .waitForAudio(below: audioLowWater)
            }
            if audioCount >= audioHardWater {
                return .waitForAudio(below: audioHardWater)
            }
        }

        return .read
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

    /// Presentation time covered by buffers that have not yet reached the
    /// renderer. Audio uses monotonic PTS, so the first and last entries give
    /// a codec-independent safety reserve (AAC and AC-3 packet counts differ).
    var bufferedDuration: Double {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count,
              let first = buffers[head],
              let last = buffers.last ?? nil else { return 0 }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        guard firstPTS.isValid, lastPTS.isValid,
              firstPTS.seconds.isFinite, lastPTS.seconds.isFinite else { return 0 }
        let duration = CMSampleBufferGetDuration(last)
        let end = duration.isValid && duration.seconds.isFinite
            ? CMTimeAdd(lastPTS, duration).seconds
            : lastPTS.seconds
        return max(end - firstPTS.seconds, 0)
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
