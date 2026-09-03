import Synchronization
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
/// HEVC and hardware-supported AV1 are decoded ahead with VideoToolbox;
/// AV1 otherwise, VP9, and the legacy video codecs are software-decoded into
/// NV12/P010 Core Video frames; aac/mp3/ac3/eac3 audio passes through
/// compressed and dts/truehd/flac/opus/vorbis decodes to LPCM via libavcodec
/// (M4);
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
    private(set) var rate: Double = 1
    private(set) var videoSize: CGSize?
    private(set) var audioTracks: [PlayerTrack] = []
    private(set) var subtitleTracks: [PlayerTrack] = []
    private(set) var currentSubtitleText: String?
    private(set) var currentSubtitleCues: [SubtitleTextCue] = []
    private(set) var currentSubtitleImages: [SubtitleImage] = []
    /// mpv convention (M6): positive delays the audio.
    private(set) var audioDelay: Double = 0
    /// Debug-HUD line: what the demuxer actually sees on the selected
    /// audio stream (codec, channels, FFmpeg's Atmos/JOC verdict) —
    /// readable without opening the track panel.
    private(set) var audioDiagnostic: String?
    private(set) var audioOutputPathDiagnostic = "compressed"
    private(set) var videoPerformance: VideoPerformanceSnapshot?
    private(set) var stallCount = 0
    /// Stalls confirmed as audio-caused, a subset of `stallCount`, which
    /// keeps counting every confirmed stall regardless of cause.
    private(set) var audioStallCount = 0
    /// Episodes where the renderer has no audio scheduled ahead of the
    /// media clock (HEL-123). Counted regardless of
    /// `buffersOnAudioStarvation`; the mode only decides whether an episode
    /// also stops the clock, not whether it's counted.
    private(set) var audioStarvationCount = 0
    /// Off by default. While off, audio starvation is counted (`aDry`) and
    /// never stops the clock. The floor `PlaybackStarvationPolicy
    /// .audioFloorSeconds` was chosen in the simulator, and build 66 is why
    /// this mode stays off until a hardware pass shows a healthy title's
    /// lead sitting well above it.
    let buffersOnAudioStarvation = UserDefaults.standard.bool(forKey: "debug.bufferOnAudioStarvation")
    /// Bounded stall recovery should normally refill in place. Count the
    /// five-second seek fallback separately so HEL-124 can prove whether it
    /// really needed one rather than inferring that from the playhead.
    private(set) var stallReprimeCount = 0
    /// Route/output recovery counters are intentionally session-scoped. The
    /// regression probe uses them to prove that an injected AVFoundation
    /// event took the same path as a real notification.
    private(set) var audioRendererRecoveryCount = 0
    private(set) var mediaServicesResetRecoveryCount = 0
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

    /// Seconds of audio still waiting on Lagoon's side of the renderer. This
    /// is a demux-backpressure input only. Neither the count nor these seconds
    /// can diagnose starvation because AVFoundation normally drains both to
    /// zero while retaining its own presentation queue.
    var audioBufferedSeconds: Double { audioQueue.bufferedDuration }
    /// Media time already handed to AVFoundation beyond the current clock.
    /// This is the starvation signal: unlike `audioBufferedSeconds`, it stays
    /// positive after the app-side queue has been drained into the renderer.
    var audioDeliveryLeadSeconds: Double {
        guard let deliveredThrough = shared.withLock({ $0.lastEnqueuedAudioEndSeconds }) else {
            return -1
        }
        return deliveredThrough - timePosition
    }
    var audioRendererReadyForPlayback: Bool {
        audioRenderer?.hasSufficientMediaDataForReliablePlaybackStart ?? false
    }
    #if DEBUG
    private(set) var audioDeliverySuspendedForDiagnostics = false
    private(set) var demuxDeliverySuspendedForDiagnostics = false
    /// `onPlaybackStarted` also runs after a seek. A diagnostic selected in
    /// Settings is one bounded experiment for this engine, not a new outage
    /// every time playback re-primes.
    @ObservationIgnored private var didSimulateAudioStarvation = false
    @ObservationIgnored private var didSimulateDeliveryStall = false
    #endif
    var videoQueueCountDiagnostic: Int {
        videoQueue.count + (softwareDecodeStage?.pendingCount ?? 0)
    }
    var maximumVideoBacklogDiagnostic: Int {
        shared.withLock { $0.maximumVideoBacklog }
    }
    var videoQueueHardLimitDiagnostic: Int {
        shared.withLock { $0.videoQueueHardLimit }
    }
    var videoIntakeCountDiagnostic: Int { videoIntake.count }
    var maximumVideoIntakeDiagnostic: Int { videoIntake.peakCount }
    /// Whether the title has sound at all. A silent one cannot starve for
    /// it, and must never be held in buffering waiting for a cushion that
    /// is never going to arrive (HEL-123).
    private var hasAudioTrack: Bool { !audioTracks.isEmpty }
    /// Edge tracking for `audioStarvationCount`, which counts episodes
    /// rather than the 10 Hz observer ticks inside one.
    @ObservationIgnored private var wasAudioStarved = false
    /// The audio depth the demux loop is aiming for. Shown beside the queue
    /// so the bigger uncached cushion is visible rather than inferred
    /// (HEL-130).
    var audioCushionTarget: Int {
        DemuxBackpressurePolicy.audioCushionTarget(
            deliveryIsCached: shared.withLock { $0.deliveryIsCached }
        )
    }

    /// Timestamp discontinuities in the audio feed — the measurable form
    /// of "the audio crackles" (HEL-64). Should read 0 during untouched
    /// playback; steady growth means the renderer is being handed a
    /// misaligned timeline.
    var audioTimingGapCount: Int {
        audioContinuity.gapCount
    }

    /// Where the software decode path's time goes, separated into the three
    /// costs it is made of (HEL-137): libavcodec, the conversion into Core
    /// Video surfaces, and reading the container. Each is wall time on its own
    /// queue, so the percentages read as the share of one core that stage
    /// holds — they are independent and do not sum to 100%. Cumulative since
    /// the last seek, which is also where the frame-loss bench re-arms, so a
    /// bench result and this line describe the same stretch of playback.
    ///
    /// Nil unless libavcodec is decoding video, and until the first frame.
    var softwareDecodeDiagnostic: String? {
        guard let stage = softwareDecodeStage else { return nil }
        let profile = stage.profile
        guard profile.elapsedSeconds > 0, profile.frames > 0 else { return nil }
        let io = demuxer.ioProfile
        let readFraction = io.elapsedSeconds > 0 ? io.readSeconds / io.elapsedSeconds : 0
        // Cost per frame first, because it is the number that answers whether
        // the device has the headroom: unlike a rate it does not fall when the
        // decoder is deliberately throttled, and reading the rate instead is
        // what left HEL-137 ambiguous for two builds. `budget` is that cost as
        // a fraction of one frame period, so anything at or above 100% cannot
        // hold frame rate however the queues are behaving.
        let frameRate = demuxer.videoFrameRate > 0 ? demuxer.videoFrameRate : 24
        var line = String(
            format: "%.1f ms/frame · budget %.0f%% · decode %.1f · convert %.1f (surface %.1f) · %.1f fps now · read %.0f%% · pending %d",
            profile.frameMilliseconds,
            profile.decodeBudgetUsed(frameRate: frameRate) * 100,
            profile.decodeMilliseconds,
            profile.conversionMilliseconds,
            profile.surfaceMilliseconds,
            profile.recentFramesPerSecond,
            readFraction * 100,
            stage.pendingCount
        )
        line += " · \(stage.resolvedThreadCount) threads"
        line += " · \(stage.outputModeName)"
        if stage.outputsToneMappedSDR {
            line += " · SDR tone-mapped"
        }
        return line
    }

    /// The same three costs as one field for the bench's self-describing
    /// result line, where a console log is all a hardware run leaves behind.
    nonisolated var softwareDecodeBenchField: String? {
        guard let stage = softwareDecodeStage else { return nil }
        let profile = stage.profile
        guard profile.elapsedSeconds > 0, profile.frames > 0 else { return nil }
        let io = demuxer.ioProfile
        let readFraction = io.elapsedSeconds > 0 ? io.readSeconds / io.elapsedSeconds : 0
        let frameRate = demuxer.videoFrameRate > 0 ? demuxer.videoFrameRate : 24
        return String(
            format: "frameMs=%.2f budget=%.3f decodeMs=%.2f convertMs=%.2f surfaceMs=%.2f fpsNow=%.2f fpsAvg=%.2f read=%.3f frames=%d threads=%d sdr=%@ output=%@",
            profile.frameMilliseconds,
            profile.decodeBudgetUsed(frameRate: frameRate),
            profile.decodeMilliseconds,
            profile.conversionMilliseconds,
            profile.surfaceMilliseconds,
            profile.recentFramesPerSecond,
            profile.framesPerSecond,
            readFraction,
            profile.frames,
            stage.resolvedThreadCount,
            stage.outputsToneMappedSDR ? "tonemapped" : "native",
            stage.outputModeName
        ) + " codec=\(stage.codecName) lowDelay=\(stage.lowDelayEnabled ? "on" : "off")"
            + " maxFrameDelay=\(stage.maxFrameDelay.map(String.init) ?? "unknown")"
            + " decoderDelay=\(stage.decoderDelay)"
    }

    /// Proof the DoVi enhancement-layer strip experiment engaged, for the
    /// HUD — nil when the toggle is off or the stream has no EL.
    var enhancementLayerStripInfo: String? {
        guard let stats = demuxer.enhancementLayerStripStats else { return nil }
        return String(format: "%d pkts · %.1f MB removed", stats.units, Double(stats.bytes) / 1_000_000)
    }

    /// Passthrough audio the demuxer discarded before any renderer saw it.
    /// Nil until something is actually dropped, so the HUD stays quiet on a
    /// healthy stream. The multiple is the diagnostic: `aGaps` is blind to
    /// this path by construction, so a silent gap with drops climbing here is
    /// a different fault from one with `aGaps` climbing.
    var audioPacketDropInfo: String? {
        guard let stats = demuxer.audioPacketDropStats, stats.packetSeconds > 0 else { return nil }
        return String(
            format: "%d pkts · worst %.1f× packet (%.0f ms)",
            stats.packets,
            stats.worstOverlapSeconds / stats.packetSeconds,
            stats.worstOverlapSeconds * 1000
        )
    }

    @ObservationIgnored var onFinished: (() -> Void)?
    /// Playback could not continue. The failure carries whether a different
    /// delivery of the same media might work, so the controller can drop to
    /// the next rung of the fallback ladder instead of stranding the viewer
    /// (HEL-100).
    @ObservationIgnored var onError: ((PlaybackEngineFailure) -> Void)?
    @ObservationIgnored var onTrackSelectionChanged: (() -> Void)?
    /// Fires once the initial audio/video cushion is enqueued and the media
    /// clock is anchored. Episode handoff metrics use this rather than stream
    /// discovery so they measure user-visible readiness, not merely an open.
    @ObservationIgnored var onPlaybackStarted: (() -> Void)?
    /// A direct-file cache is an optimization. If its range transport cannot
    /// open this server resource, the engine retries immediately through
    /// libavformat's native HTTP path and asks the controller to retire the
    /// unusable cache instead of failing playback.
    @ObservationIgnored var onPlaybackCacheFallback: (() -> Void)?

    // MARK: Cross-thread state

    @ObservationIgnored nonisolated private let demuxer = FFmpegDemuxer()
    @ObservationIgnored nonisolated private let videoQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let audioQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let demuxQueue = DispatchQueue(label: "ee.helop.lagoon.demux", qos: .userInitiated)
    @ObservationIgnored nonisolated private let pumpQueue = DispatchQueue(label: "ee.helop.lagoon.pump", qos: .userInteractive)
    @ObservationIgnored nonisolated private let pumpKickState = PumpKickState()
    /// Compressed video read past the decoded-frame limit while the demuxer
    /// reads on for audio (HEL-124). Demux queue, plus the resets.
    @ObservationIgnored nonisolated private let videoIntake = VideoIntakeQueue()
    /// Serialises admission to and drain from the intake, because both the
    /// demux loop and the video pump feed the decoders from it and decode
    /// order must survive the two racing (HEL-124).
    @ObservationIgnored nonisolated private let videoFeedLock = NSLock()
    /// How long a backpressure wait may sleep before the loop re-evaluates
    /// the policy on its own. A full decoded queue under a stopped clock
    /// never dequeues, and audio can run dry behind it (HEL-124).
    nonisolated private static let demuxWaitTimeout: TimeInterval = 0.25
    #if DEBUG
    @ObservationIgnored nonisolated private let diagnosticFaultGate = PlaybackDiagnosticFaultGate()
    #endif
    /// Whether each renderer's request block is registered. Pump queue only,
    /// apart from attach and teardown, which run before and after any pump.
    @ObservationIgnored nonisolated(unsafe) private var videoRequestsArmed = false
    @ObservationIgnored nonisolated(unsafe) private var audioRequestsArmed = false
    /// Request-block invocations that found nothing to give (HEL-137). The
    /// pump stops requesting on each, so this stays near zero; the loop that
    /// once cost half a core would count thousands a second. Read by the
    /// regression probe, hence atomic.
    @ObservationIgnored nonisolated private let idleRequestCounter = Atomic<Int>(0)

    nonisolated var idleRequestCallbacks: Int {
        idleRequestCounter.load(ordering: .relaxed)
    }

    nonisolated var videoOutputPathDiagnostic: String {
        if let stage = softwareDecodeStage { return stage.outputModeName }
        return videoDecoder != nil ? "videotoolbox" : "compressed"
    }
    @ObservationIgnored nonisolated private let performanceSignpostID = OSSignpostID(log: PlaybackPerformance.log)
    @ObservationIgnored nonisolated private let lifecycleID = UUID()
    @ObservationIgnored nonisolated private let audioContinuity = AudioContinuityMonitor()
    @ObservationIgnored nonisolated private let av1PipelineTimings = RendererPipelineTimings(
        enabled: UserDefaults.standard.bool(forKey: "debug.av1PipelineProfile")
    )
    @ObservationIgnored nonisolated(unsafe) private var av1PipelineTimer: DispatchSourceTimer?
    @ObservationIgnored nonisolated(unsafe) private var videoDecoder: VideoToolboxDecoder?
    /// libavcodec's decoder, driven from a queue of its own so reading and
    /// decoding overlap. Non-nil exactly when the software path is in use
    /// (HEL-137).
    @ObservationIgnored nonisolated(unsafe) private var softwareDecodeStage: SoftwareVideoDecodeStage?
    @ObservationIgnored private var bench: FrameLossBench?
    @ObservationIgnored private var benchEnabled = false
    @ObservationIgnored private var benchTickCount = 0
    @ObservationIgnored private var performanceMetricsLoadInFlight = false

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
    @ObservationIgnored private var didNotifyPlaybackStarted = false
    @ObservationIgnored private var stallRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var stallConfirmationTask: Task<Void, Never>?
    @ObservationIgnored private var stallConfirmationID: UUID?
    @ObservationIgnored private var stallSignpostActive = false
    @ObservationIgnored private var shutdownRequested = false
    @ObservationIgnored private var rendererNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var audioRendererNotificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var rendererRecoveryInProgress = false
    @ObservationIgnored private var audioRendererRecoveryInProgress = false
    /// Non-nil while a fresh audio renderer is being swapped in. Both paths
    /// that replace one share it, so a flush notification cannot start a
    /// second swap on top of the first.
    @ObservationIgnored private var audioRendererReplacementID: UUID?
    @ObservationIgnored private var audioStatusObservation: NSKeyValueObservation?

    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored nonisolated(unsafe) private var pendingCacheSession: PlaybackCacheSession?
    @ObservationIgnored nonisolated(unsafe) private var pendingDisc: DiscPlaybackRequest?
    @ObservationIgnored private var pendingStartSeconds: Double = 0

    init() {
        PlaybackLifecycleDiagnostics.engineCreated(lifecycleID)
    }

    deinit {
        av1PipelineTimer?.cancel()
        PlaybackLifecycleDiagnostics.engineDestroyed(lifecycleID)
    }

    func prepare(
        url: URL,
        cacheSession: PlaybackCacheSession? = nil,
        disc: DiscPlaybackRequest? = nil,
        startSeconds: Double,
        initialAudioOrdinal: Int?,
        initialSubtitleOrdinal: Int? = nil,
        audioTrackMetadata: [PlayerTrackMetadata] = [],
        embeddedSubtitleMetadata: [PlayerTrackMetadata] = [],
        externalSubtitles: [ExternalSubtitleTrack] = []
    ) {
        pendingURL = url
        pendingCacheSession = cacheSession
        pendingDisc = disc
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
        // A shut-down engine must never come back to life (HEL-110).
        // `finishRendererShutdown` nils `videoRenderer`, so the emptiness
        // check alone lets a retired engine pass — and SwiftUI does re-mount
        // the surface after a failed playback, which used to re-register a
        // renderer set that could never detach again (`shutdown` early-returns
        // on `shutdownRequested`) and start a second demux loop that reopened
        // the stream, transcode session and all.
        guard !shutdownRequested, videoRenderer == nil, let url = pendingURL else { return }

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
        let audio = Self.makeAudioRenderer()
        videoRenderer = video
        audioRenderer = audio
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)
        PlaybackLifecycleDiagnostics.renderersAttached(lifecycleID)
        observeVideoRenderer(video)
        observeAudioRenderer(audio)

        armVideoRequests(video)
        armAudioRequests(audio)
        if av1PipelineTimings.enabled {
            let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(50),
                leeway: .milliseconds(10)
            )
            timer.setEventHandler { [weak self] in
                self?.sampleAV1Pipeline()
            }
            av1PipelineTimer = timer
            timer.resume()
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
            let start = max(pendingStartSeconds, 0)
            $0.pendingSeekSeconds = start
            $0.videoBufferedTo = start
            $0.playbackGeneration += 1
        }
        let startURL = url
        let startCacheSession = pendingCacheSession
        let startDisc = pendingDisc
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
                cacheSession: startCacheSession,
                disc: startDisc,
                recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
            )
        }
    }

    /// Every audio renderer this engine owns, configured identically — a
    /// replacement after a failure or a media-services reset has to sound
    /// exactly like the one it replaces.
    ///
    /// The spatialization default differs between Apple's two players, and
    /// not in this one's favour: `AVPlayerItem` documents
    /// `monoStereoAndMultichannel` for video content, while
    /// `AVSampleBufferAudioRenderer` documents `multichannel` alone. Left at
    /// its default, a stereo soundtrack that AVPlayer would spatialize on
    /// AirPods plays flat here — which covers a great deal of television,
    /// anime and older film (HEL-105).
    ///
    /// This grants permission rather than forcing an effect: the viewer's
    /// Spatial Audio setting still decides, and over HDMI to a receiver it
    /// changes nothing at all.
    static func makeAudioRenderer() -> AVSampleBufferAudioRenderer {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        // The sample-buffer renderer otherwise changes pitch with rate.
        // Time-domain processing keeps speech natural at 1.25x/1.5x and is
        // applied here so media-service and failure replacements inherit it.
        renderer.audioTimePitchAlgorithm = .timeDomain
        return renderer
    }

    // MARK: - Transport (PlayerEngine)

    func play() {
        guard isPaused || synchronizer.rate == 0 else { return }
        isPaused = false
        // A buffering engine resumes when its queue gate is satisfied;
        // forcing the clock here would run its timebase ahead of the samples.
        if !isBuffering {
            synchronizer.rate = Float(rate)
        }
        rearmBench(at: timePosition)
    }

    func pause() {
        guard !isPaused || synchronizer.rate > 0 else { return }
        clearPendingStallConfirmation()
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

    func setRate(_ requestedRate: Double) {
        let requestedRate = PlaybackRatePolicy.clamped(requestedRate)
        guard rate != requestedRate else { return }
        rate = requestedRate
        shared.withLock { $0.playbackRate = requestedRate }
        if !isPaused, !isBuffering {
            synchronizer.rate = Float(requestedRate)
        }
        rearmBench(at: timePosition)
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
        currentSubtitleCues = []
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
            // The track's language is the only reliable signal for a
            // non-UTF-8 sidecar, so it has to reach the decoder (HEL-92).
            let languageHint = track.language
            let cues = await Task.detached {
                SubtitleParser.cues(from: data, languageHint: languageHint)
            }.value
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
        removeAudioRendererObservers()
        audioRendererReplacementID = nil
        av1PipelineTimer?.cancel()
        av1PipelineTimer = nil
        stallRecoveryTask?.cancel()
        clearPendingStallConfirmation()
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
        #if DEBUG
        diagnosticFaultGate.cancel()
        audioDeliverySuspendedForDiagnostics = false
        demuxDeliverySuspendedForDiagnostics = false
        #endif
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

    /// Completes only after this engine has closed FFmpeg and AVFoundation
    /// has acknowledged removal of both renderers. The controller keeps the
    /// instance alive while awaiting this during an episode handoff.
    nonisolated func waitForMediaResourcesToRetire(
        timeout: Duration = .seconds(15)
    ) async -> Bool {
        await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
            for: lifecycleID,
            timeout: timeout
        )
    }

    func refreshVideoPerformanceMetrics() {
        guard !shutdownRequested,
              !performanceMetricsLoadInFlight,
              let renderer = videoRenderer else { return }
        performanceMetricsLoadInFlight = true
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            let snapshot = metrics.map {
                VideoPerformanceSnapshot(
                    totalFrames: $0.totalNumberOfFrames,
                    droppedFrames: $0.numberOfDroppedFrames,
                    corruptedFrames: $0.numberOfCorruptedFrames,
                    optimizedCompositingFrames: $0.numberOfFramesDisplayedUsingOptimizedCompositing,
                    accumulatedFrameDelay: $0.totalAccumulatedFrameDelay
                )
            }
            Task { @MainActor [weak self, snapshot] in
                guard let self else { return }
                self.performanceMetricsLoadInFlight = false
                guard !self.shutdownRequested, let snapshot else { return }
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
        videoRequestsArmed = false
        audioRequestsArmed = false
        video?.flush()
        audio?.flush()
        videoIntake.removeAll()
        videoQueue.reset()
        audioQueue.reset()
        shared.withLock {
            $0.lastEnqueuedAudioEndSeconds = nil
            $0.endOfFilePendingIntake = false
        }

        #if DEBUG
        // Hardware can spend several seconds retiring a 4K decoder and its
        // queued surfaces. This launch-only hook reproduces that timing on
        // CoreSimulator so autoplay must prove it never overlaps the old
        // renderer with the successor.
        let regressionDelay = UserDefaults.standard.double(
            forKey: "debug.regressionRendererRetirementDelaySeconds"
        )
        if regressionDelay > 0 {
            Thread.sleep(forTimeInterval: regressionDelay)
        }
        #endif

        // The synchronizer otherwise retains both renderers until the
        // main-actor engine dies. Removing them asynchronously lets their
        // decoder resources retire without hitching the returning UI.
        let removals = DispatchGroup()
        if let video {
            removals.enter()
            // Apple's contract names invalid time as the explicit
            // immediate-removal sentinel. Avoid manufacturing a negative
            // timeline value and wait for the completion before declaring
            // the renderer retired.
            synchronizer.removeRenderer(video, at: .invalid) { _ in
                removals.leave()
            }
        }
        if let audio {
            removals.enter()
            synchronizer.removeRenderer(audio, at: .invalid) { _ in
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
            $0.videoBufferedTo = clamped
            $0.playbackGeneration += 1
        }
        // Enqueue, flush, and queue reset share the pump queue. This makes
        // Apple's post-flush keyframe rule deterministic: an in-flight old
        // sample cannot race in after the flush.
        pumpQueue.sync { [self] in
            videoRenderer?.flush()
            audioRenderer?.flush()
            videoIntake.removeAll()
            videoQueue.reset()
            audioQueue.reset()
            shared.withLock {
                $0.firstEnqueuedVideoPTS = nil
                $0.lastEnqueuedAudioEndSeconds = nil
                $0.endOfFilePendingIntake = false
            }
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
        currentSubtitleCues = []
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
            synchronizer.setRate(Float(rate), time: time, atHostTime: hostTime)
        }
        kickPumps()
        rearmBench(at: time.seconds)
        if !didNotifyPlaybackStarted {
            didNotifyPlaybackStarted = true
            onPlaybackStarted?()
        }
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

    private func observeAudioRenderer(_ renderer: AVSampleBufferAudioRenderer) {
        let center = NotificationCenter.default
        audioRendererNotificationTokens.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] notification in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey]
                    as? NSValue)?.timeValue
                self.recoverAudioRenderer(
                    renderer,
                    from: flushTime,
                    reason: "automaticFlush"
                )
            }
        })
        audioRendererNotificationTokens.append(center.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: .main
        ) { [weak self, weak renderer] _ in
            guard let self, let renderer else { return }
            MainActor.assumeIsolated {
                self.recoverAudioRenderer(
                    renderer,
                    from: nil,
                    reason: "outputConfiguration"
                )
            }
        })
        // The two notifications above are the renderer's recoverable events.
        // Hard failure has no notification: Apple exposes it as `status`,
        // documented key-value observable and "terminal status from which
        // recovery is not always possible". Unobserved, a failed renderer
        // left the film playing on in silence with nothing reported (HEL-101).
        //
        // KVO is delivered on whichever thread changed the property, which
        // for a CoreMedia-owned renderer is not the main one — hence a hop
        // rather than the `assumeIsolated` the notification blocks can use.
        audioStatusObservation = renderer.observe(\.status, options: [.new]) {
            [weak self, weak renderer] _, _ in
            Task { @MainActor [weak self, weak renderer] in
                guard let self, let renderer else { return }
                self.handleAudioRendererStatus(renderer)
            }
        }
    }

    private func handleAudioRendererStatus(_ renderer: AVSampleBufferAudioRenderer) {
        guard !shutdownRequested,
              renderer === audioRenderer,
              renderer.status == .failed else { return }
        replaceAudioRenderer(renderer, for: .rendererFailed)
    }

    private func removeAudioRendererObservers() {
        for token in audioRendererNotificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        audioRendererNotificationTokens.removeAll()
        audioStatusObservation?.invalidate()
        audioStatusObservation = nil
    }

    /// AVFoundation delivers automatic audio flushes on an arbitrary queue
    /// and explicitly requires the follow-up flush to be serialized with
    /// sample enqueueing. `seek` performs that flush and every queue reset on
    /// `pumpQueue`, then asks the demux loop to refill from the playhead.
    private func recoverAudioRenderer(
        _ renderer: AVSampleBufferAudioRenderer,
        from flushTime: CMTime?,
        reason: StaticString
    ) {
        guard !shutdownRequested,
              renderer === audioRenderer,
              !audioRendererRecoveryInProgress,
              audioRendererReplacementID == nil else { return }
        audioRendererRecoveryInProgress = true
        defer { audioRendererRecoveryInProgress = false }
        let notifiedTime = flushTime?.seconds
        let recoveryPosition = if let notifiedTime, notifiedTime.isFinite, notifiedTime >= 0 {
            notifiedTime
        } else {
            timePosition
        }
        audioRendererRecoveryCount += 1
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=%{public}s",
            recoveryPosition,
            String(describing: reason)
        )
        seek(to: recoveryPosition)
    }

    /// A media-services reset invalidates AVFoundation audio objects. Replace
    /// the renderer rather than reusing it, retain the current synchronized
    /// video surface, and deliberately stay paused until an explicit viewer
    /// or remote-command action calls `play()`.
    func recoverAfterMediaServicesReset() {
        guard let outgoingAudio = audioRenderer else { return }
        replaceAudioRenderer(outgoingAudio, for: .mediaServicesReset)
    }

    /// Swaps in a fresh audio renderer and refills it from the playhead.
    ///
    /// The only recovery AVFoundation offers for a renderer it has failed or
    /// invalidated — neither state can be cleared on the object itself. The
    /// synchronizer keeps the video renderer attached throughout, so what a
    /// viewer loses is a few hundred milliseconds of audio rather than the
    /// film.
    private func replaceAudioRenderer(
        _ outgoingAudio: AVSampleBufferAudioRenderer,
        for replacement: AudioRendererReplacement
    ) {
        guard !shutdownRequested,
              audioRendererReplacementID == nil,
              outgoingAudio === audioRenderer else { return }
        if replacement.staysPaused {
            pause()
        }
        isBuffering = true
        let recoveryPosition = timePosition
        let replacementID = UUID()
        audioRendererReplacementID = replacementID
        // Invalidates this renderer's status observation too, so a failed
        // renderer cannot re-report its terminal state while being retired.
        removeAudioRendererObservers()
        let outgoingError = outgoingAudio.error?.localizedDescription
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Renderer Recovery",
            signpostID: performanceSignpostID,
            "position=%{public}.3f reason=%{public}s",
            recoveryPosition,
            String(describing: replacement.reason)
        )

        pumpQueue.async { [weak self, weak outgoingAudio] in
            guard let self, let outgoingAudio,
                  !self.shared.withLock({ $0.cancelled }),
                  self.audioRenderer === outgoingAudio else { return }
            self.audioRenderer = nil
            outgoingAudio.stopRequestingMediaData()
            self.audioRequestsArmed = false
            outgoingAudio.flush()
            self.audioQueue.reset()
            self.shared.withLock { $0.lastEnqueuedAudioEndSeconds = nil }
            self.audioContinuity.reset()
            self.synchronizer.removeRenderer(outgoingAudio, at: .invalid) { [weak self] removed in
                Task { @MainActor [weak self] in
                    guard let self,
                          !self.shutdownRequested,
                          self.audioRendererReplacementID == replacementID else { return }
                    guard removed else {
                        self.audioRendererReplacementID = nil
                        self.onError?(PlaybackEngineFailure(
                            cause: .delivery,
                            message: replacement.failureMessage(detail: outgoingError)
                        ))
                        return
                    }
                    let incoming = Self.makeAudioRenderer()
                    self.audioRenderer = incoming
                    self.synchronizer.addRenderer(incoming)
                    self.observeAudioRenderer(incoming)
                    self.armAudioRequests(incoming)
                    switch replacement {
                    case .mediaServicesReset:
                        self.mediaServicesResetRecoveryCount += 1
                    case .rendererFailed:
                        self.audioRendererRecoveryCount += 1
                    }
                    self.audioRendererReplacementID = nil
                    // Refills both queues and re-anchors the clock. A paused
                    // engine repositions without starting, which is what the
                    // media-services case requires.
                    self.seek(to: recoveryPosition)
                }
            }
        }
    }

    #if DEBUG
    /// Debug-only, off-by-default fault injection used by both the simulator
    /// regression and the hardware calibration pass on the paired Apple TV,
    /// run from a Debug build. It withholds samples from AVFoundation while
    /// demuxing and video continue, which isolates HEL-123 from network and
    /// codec behavior.
    func simulateAudioStarvationForDiagnostics(durationSeconds: Double = 3) {
        guard !shutdownRequested,
              !didSimulateAudioStarvation,
              durationSeconds > 0 else { return }
        didSimulateAudioStarvation = true
        diagnosticFaultGate.setAudioDeliverySuspended(true)
        audioDeliverySuspendedForDiagnostics = true
        pumpQueue.async { [weak self] in
            guard let self, let renderer = self.audioRenderer else { return }
            if self.audioRequestsArmed {
                self.audioRequestsArmed = false
                renderer.stopRequestingMediaData()
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(durationSeconds * 1_000)))
            guard let self, !self.shutdownRequested else { return }
            self.diagnosticFaultGate.setAudioDeliverySuspended(false)
            self.audioDeliverySuspendedForDiagnostics = false
            // The clock ran while delivery was held, so the queue holds
            // audio that ended before it; a real recovery never hands the
            // renderer such samples, and they use up the acceptance budget
            // the resume rule depends on.
            let clock = self.timePosition
            self.audioQueue.dropLeading { Self.presentationEnd(of: $0).map { $0 < clock } ?? false }
            self.kickPumps()
        }
    }

    /// Stops `av_read_frame` without touching either renderer. Releasing the
    /// gate exercises the real demux/backpressure refill path for HEL-124.
    func simulateDeliveryStallForDiagnostics(durationSeconds: Double = 3) {
        guard !shutdownRequested,
              !didSimulateDeliveryStall,
              durationSeconds > 0 else { return }
        didSimulateDeliveryStall = true
        diagnosticFaultGate.setDemuxDeliverySuspended(true)
        demuxDeliverySuspendedForDiagnostics = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int64(durationSeconds * 1_000)))
            guard let self, !self.shutdownRequested else { return }
            self.diagnosticFaultGate.setDemuxDeliverySuspended(false)
            self.demuxDeliverySuspendedForDiagnostics = false
        }
    }
    #endif

    #if DEBUG
    /// Launch-gated UI regression hook. It invokes the exact notification
    /// recovery path without pretending CoreSimulator changed hardware.
    func simulateAudioRendererFlushForRegression() {
        guard let audioRenderer else { return }
        recoverAudioRenderer(audioRenderer, from: nil, reason: "regression")
    }

    /// The same for hard failure. A renderer cannot be made to report
    /// `.failed` on demand, so the regression drives the replacement the
    /// observation would have started (HEL-101).
    func simulateAudioRendererFailureForRegression() {
        guard let audioRenderer else { return }
        replaceAudioRenderer(audioRenderer, for: .rendererFailed)
    }
    #endif

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
        // The renderer decodes what it was handed. Nothing about the way
        // those samples were delivered will change its verdict.
        onError?(PlaybackEngineFailure(
            cause: .undecodable,
            message: "Playback failed in the Lagoon video renderer (\(detail))."
        ))
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
        // Video always reaches the recovery path. Audio is counted so a
        // silence leaves a trace, and only reaches the recovery path when
        // `buffersOnAudioStarvation` is on (HEL-123).
        switch starvation(at: seconds) {
        case .video:
            wasAudioStarved = false
            confirmStallIfPersistent()
        case .audio:
            if StallRecoveryPolicy.confirms(.audio, buffersOnAudioStarvation: buffersOnAudioStarvation) {
                confirmStallIfPersistent()
            } else {
                clearPendingStallConfirmation()
            }
            // Count episodes, not observer ticks: this fires at 10 Hz.
            if !wasAudioStarved {
                wasAudioStarved = true
                audioStarvationCount += 1
            }
        case .none:
            // Buffering answers `.none` because nothing is being judged, not
            // because audio is healthy. An episode that became a stall is
            // one episode until playback is running again; ending it here
            // would count the dip right after resume, or a reprime's
            // re-prime, as a second one.
            if !isBuffering {
                wasAudioStarved = false
            }
            clearPendingStallConfirmation()
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
        av1PipelineTimings.reset()
        softwareDecodeStage?.resetDetailedTimings()
    }

    private func feedBench(_ snapshot: VideoPerformanceSnapshot) {
        guard bench != nil else { return }
        let memory = MemorySnapshot.current()
        let sample = FrameLossBench.Sample(
            position: timePosition,
            totalFrames: snapshot.totalFrames,
            droppedFrames: snapshot.droppedFrames,
            corruptedFrames: snapshot.corruptedFrames,
            stalls: stallCount,
            audioStalls: audioStallCount,
            audioDry: audioStarvationCount,
            audioGaps: audioContinuity.gapCount,
            videoQueueDepth: videoQueue.count,
            optimizedFrames: snapshot.optimizedCompositingFrames,
            accumulatedDelay: snapshot.accumulatedFrameDelay,
            footprintBytes: memory.footprintBytes,
            availableBytes: memory.availableBytes
        )
        if let result = bench!.record(sample) {
            benchStatus = result.regressionSummary
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
            if let software = softwareDecodeBenchField {
                gates += " swdecode=\"\(software)\""
            }
            if let stage = softwareDecodeStage {
                gates += " output=\"\(stage.outputModeName)\""
            }
            gates += " hud=\"\(UserDefaults.standard.bool(forKey: "debug.playbackHUD") ? "on" : "off")\""
            #if os(tvOS)
            gates += " display=\"\(DisplayModeMatcher.statusDescription)\""
            #endif
            if let size = videoSize {
                gates += " playing=\"\(Int(size.width))x\(Int(size.height))\""
            }
            print("BenchResult dropped=\(result.dropped) frames=\(result.frames) "
                + String(format: "percent=%.3f", result.lossPercent)
                + " corrupted=\(result.corrupted) stalls=\(result.stalls)"
                + " audioStalls=\(result.audioStalls) audioDry=\(result.audioDry) audioGaps=\(result.audioGaps)"
                + " minVideoQueue=\(result.minVideoQueue)"
                + " optimized=\(result.optimizedFrames)"
                + String(format: " delayMs=%.1f", result.accumulatedDelay * 1000)
                + String(format: " memoryStartMB=%.1f memoryPeakMB=%.1f memoryGrowthMB=%.1f",
                    Double(result.startingFootprintBytes) / 1_048_576,
                    result.peakFootprintMB,
                    result.footprintGrowthMB)
                + (result.minimumAvailableBytes > 0
                    ? String(format: " minimumAvailableMB=%.1f", result.minimumAvailableMB)
                    : "")
                + String(format: " start=%.2f window=%.2f ", result.startPosition, result.windowSeconds)
                + gates)
            for line in softwareDecodeStage?.detailedTimingLines ?? [] {
                print("PipelineDecode \(line)")
            }
            for line in av1PipelineTimings.summaryLines() {
                print("PipelineRenderer \(line)")
            }
            benchCompleted = true
            os_signpost(
                .event,
                log: PlaybackPerformance.log,
                name: "Bench Result",
                signpostID: performanceSignpostID,
                "dropped=%{public}d frames=%{public}d percent=%{public}.3f corrupted=%{public}d stalls=%{public}d audioStalls=%{public}d audioDry=%{public}d audioGaps=%{public}d minVideoQueue=%{public}d memoryStartMB=%{public}.1f memoryPeakMB=%{public}.1f memoryGrowthMB=%{public}.1f minimumAvailableMB=%{public}.1f start=%{public}.2f window=%{public}.2f",
                result.dropped,
                result.frames,
                result.lossPercent,
                result.corrupted,
                result.stalls,
                result.audioStalls,
                result.audioDry,
                result.audioGaps,
                result.minVideoQueue,
                Double(result.startingFootprintBytes) / 1_048_576,
                result.peakFootprintMB,
                result.footprintGrowthMB,
                result.minimumAvailableMB,
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
    private func beginStallRecovery(cause: PlaybackStarvation) {
        clearPendingStallConfirmation()
        isBuffering = true
        synchronizer.rate = 0
        stallCount += 1
        if cause == .audio {
            audioStallCount += 1
        }
        if !stallSignpostActive {
            stallSignpostActive = true
            os_signpost(
                .begin,
                log: PlaybackPerformance.log,
                name: "Playback Stall",
                signpostID: performanceSignpostID,
                "position=%{public}.3f count=%{public}d audioDry=%{public}d cause=%{public}s",
                timePosition,
                stallCount,
                audioStarvationCount,
                cause.rawValue
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
                    videoQueueFinished: self.videoQueue.isFinished,
                    playbackRate: self.rate,
                    audioRequired: self.buffersOnAudioStarvation
                        && self.hasAudioTrack
                        && !self.audioQueue.isFinished,
                    audioDeliveryLeadSeconds: self.shared.withLock {
                        $0.lastEnqueuedAudioEndSeconds.map { $0 - self.timePosition }
                    },
                    audioRendererHasSufficientData: self.audioRendererReadyForPlayback
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
                        self.synchronizer.rate = Float(self.rate)
                    }
                    return
                case .reprime:
                    self.stallReprimeCount += 1
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

    /// A single 100 ms observer tick with no video scheduled beyond the
    /// clock is not proof of starvation: the demux queue may refill on the
    /// next scheduling turn. Confirm before pausing the shared clock, or
    /// healthy VC-1 playback acquires visible micro-stalls from recovery.
    private func confirmStallIfPersistent() {
        guard stallConfirmationTask == nil else { return }
        let identifier = UUID()
        stallConfirmationID = identifier
        stallConfirmationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: StallRecoveryPolicy.confirmationDelay)
            } catch {
                return
            }
            guard let self,
                  self.stallConfirmationID == identifier else { return }
            self.stallConfirmationID = nil
            self.stallConfirmationTask = nil
            // Re-read: a second is long enough for the dip to clear. Video
            // always confirms; audio confirms only when
            // `buffersOnAudioStarvation` is on, matching what armed the
            // confirmation.
            let cause = self.starvation(at: self.timePosition)
            guard StallRecoveryPolicy.confirms(cause, buffersOnAudioStarvation: self.buffersOnAudioStarvation)
            else { return }
            self.beginStallRecovery(cause: cause)
        }
    }

    private func clearPendingStallConfirmation() {
        stallConfirmationID = nil
        stallConfirmationTask?.cancel()
        stallConfirmationTask = nil
    }

    private func starvation(at seconds: Double) -> PlaybackStarvation {
        PlaybackStarvationPolicy.starvation(PlaybackStarvationPolicy.Snapshot(
            isBuffering: isBuffering,
            isPaused: isPaused,
            didFinish: didFinish,
            position: seconds,
            duration: duration,
            rate: rate,
            videoQueueCount: videoQueue.count,
            videoQueueFinished: videoQueue.isFinished,
            videoBufferedTo: shared.withLock { $0.videoBufferedTo },
            hasAudio: hasAudioTrack,
            audioQueueFinished: audioQueue.isFinished,
            audioDeliveryLeadSeconds: shared.withLock {
                $0.lastEnqueuedAudioEndSeconds.map { $0 - seconds }
            }
        ))
    }

    private func refreshSubtitles(at seconds: Double) {
        let active = subtitleStore.active(at: seconds)
        if active.textCues != currentSubtitleCues {
            currentSubtitleCues = active.textCues
            let text = active.textCues.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            currentSubtitleText = text.isEmpty ? nil : text
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
        cacheSession: PlaybackCacheSession?,
        disc: DiscPlaybackRequest?,
        recommendedPixelBufferAttributes: CVPixelBufferAttributes
    ) {
        defer {
            PlaybackLifecycleDiagnostics.demuxEnded(lifecycleID)
        }
        // Whether this stream ended up with a cache, which is what decides
        // how much cushion the demux queues have to be (HEL-130). Keyed on
        // the cache rather than on the play method so the two compose: a
        // transcode with the experimental cache switched on is no longer
        // uncached, and a direct play that fell back to the native
        // transport is.
        var deliveryIsCached = cacheSession != nil
        do {
            do {
                try demuxer.open(
                    url: url.absoluteString,
                    cacheSession: cacheSession,
                    disc: disc,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
                )
            // A disc has no native-transport retry to fall back on: without
            // the cache there is nothing to read the filesystem through, and
            // handing libavformat the raw image is the failure this whole
            // path exists to avoid (HEL-133).
            } catch where cacheSession != nil && disc == nil {
                demuxer.close()
                deliveryIsCached = false
                Task { @MainActor in self.onPlaybackCacheFallback?() }
                try demuxer.open(
                    url: url.absoluteString,
                    cacheSession: nil,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
                )
            }
        } catch {
            let demuxError = error as? DemuxError
            let failure = PlaybackEngineFailure(
                cause: demuxError?.cause ?? .delivery,
                message: demuxError?.errorDescription ?? "The stream could not be opened."
            )
            Task { @MainActor in self.onError?(failure) }
            return
        }
        shared.withLock { $0.deliveryIsCached = deliveryIsCached }
        // An Apple decoder that cannot be created is a reason to decode this
        // stream some other way, not a reason to fail the title (HEL-137).
        // AV1 always has libdav1d behind it, so a session refused here -
        // whether because the system-decoder experiment asked for a decoder
        // this platform does not have, or because hardware Apple says may be
        // unavailable at any time actually was - reopens on the software path
        // instead of stranding playback. Once only, and never for HEVC, which
        // has no fallback and must still fail loudly.
        if demuxer.videoStream?.codecName == "av1",
           !demuxer.outputsDecodedVideo,
           let description = demuxer.videoStream?.formatDescription,
           !VideoToolboxDecoder.canDecode(description) {
            demuxer.close()
            demuxer.disableVideoToolboxAV1()
            do {
                try demuxer.open(
                    url: url.absoluteString,
                    cacheSession: deliveryIsCached ? cacheSession : nil,
                    disc: disc,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes
                )
            } catch {
                let demuxError = error as? DemuxError
                let failure = PlaybackEngineFailure(
                    cause: demuxError?.cause ?? .delivery,
                    message: demuxError?.errorDescription
                        ?? "The stream could not be opened."
                )
                Task { @MainActor in self.onError?(failure) }
                return
            }
        }
        // The demuxer builds the software decoder (it has the codec
        // parameters) but never drives it: decoding on the demux queue meant
        // reading and decoding took turns, which 4K AV1 cannot afford
        // (HEL-137).
        if demuxer.outputsDecodedVideo, let decoder = demuxer.takeSoftwareVideoDecoder() {
            softwareDecodeStage = SoftwareVideoDecodeStage(
                decoder: decoder,
                outputHandler: { [weak self] buffer in
                    self?.acceptSoftwareDecodedVideo(buffer)
                },
                errorHandler: { [weak self] error in
                    self?.failVideoDecode(error)
                },
                packetCompletionHandler: { [weak self] in
                    // Whoever is parked on the combined in-flight count has
                    // to re-read it when a packet leaves the stage.
                    self?.videoQueue.signalWaiters()
                }
            )
        }
        if let codecName = demuxer.videoStream?.codecName,
           codecName == "hevc" || codecName == "av1",
           !demuxer.outputsDecodedVideo,
           let description = demuxer.videoStream?.formatDescription {
            do {
                // AV1 only reaches here when the probe above found a
                // decoder for it, which may be Apple's software one on a
                // platform that has it. Requiring hardware would refuse that,
                // so only the silicon case demands it (HEL-137).
                let requiresHardware = codecName != "av1"
                    || PlaybackCapabilities.current.hardwareAV1
                videoDecoder = try VideoToolboxDecoder(
                    formatDescription: description,
                    recommendedPixelBufferAttributes: recommendedPixelBufferAttributes,
                    reportedReorderDepth: demuxer.videoStream?.videoReorderDepth ?? 0,
                    requiresHardware: requiresHardware,
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
                        // Name the codec rather than assuming VC-1 — the
                        // software path also carries MPEG-4 Part 2.
                        "grid \($0) · libavcodec \(demuxer.videoStream?.codecName ?? "?") SW"
                    } else if let videoDecoder {
                        // Which kind of VideoToolbox decoder answered is the
                        // whole point of the AV1 experiment, so name it rather
                        // than assuming hardware.
                        "grid \($0) · VideoToolbox \(videoDecoder.requiresHardware ? "HW" : "system")"
                            + " · reorder \(videoDecoder.reorderDepth)"
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
                        let demuxError = error as? DemuxError
                        let failure = PlaybackEngineFailure(
                            cause: demuxError?.cause ?? .delivery,
                            message: demuxError?.errorDescription
                                ?? "The stream could not seek to that position."
                        )
                        shared.withLock { $0.cancelled = true }
                        videoQueue.markFinished()
                        audioQueue.markFinished()
                        Task { @MainActor in self.onError?(failure) }
                        break
                    }
                }
                do {
                    try videoDecoder?.reset()
                } catch {
                    failVideoDecode(error)
                    break
                }
                // Before the queues, and synchronously: a frame still inside
                // libavcodec belongs to the old position and must not land in
                // a queue that has just been emptied.
                softwareDecodeStage?.reset()
                videoIntake.removeAll()
                shared.withLock { $0.endOfFilePendingIntake = false }
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
            // Decoded frames plus the packets the stage still owes. Both
            // are video already read and not yet shown, and counting only the
            // first would let the loop read a decoder backlog ahead of itself
            // the moment decode stopped happening on this queue (HEL-137).
            //
            // Parked video goes first: it is older than anything the next
            // read would return, and it only waits for decoded-queue room
            // (HEL-124).
            drainVideoIntake()
            let decodedFrameBytes = softwareDecodeStage?.decodedFrameBytes ?? 0
            let videoIsDecoded = videoDecoder != nil || demuxer.outputsDecodedVideo
            let videoIsSoftwareDecoded = demuxer.outputsDecodedVideo
            let videoHardLimit = DemuxBackpressurePolicy.videoHardLimit(
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded,
                decodedFrameBytes: decodedFrameBytes
            )
            let videoBacklog = recordVideoBacklog(hardLimit: videoHardLimit)
            let (playbackRate, endOfFilePending) = shared.withLock {
                ($0.playbackRate, $0.endOfFilePendingIntake)
            }
            if endOfFilePending {
                // Nothing left to read; finish once the intake has drained.
                if videoIntake.isEmpty {
                    finishVideoInput()
                } else {
                    videoQueue.waitUntilBelow(videoHardLimit, timeout: Self.demuxWaitTimeout) {
                        self.softwareDecodeStage?.pendingCount ?? 0
                    }
                }
                continue
            }
            switch DemuxBackpressurePolicy.decision(
                videoCount: videoBacklog,
                audioCount: audioQueue.count,
                audioBufferedSeconds: audioQueue.bufferedDuration,
                videoFrameRate: demuxer.videoFrameRate,
                videoIsDecoded: videoIsDecoded,
                videoIsSoftwareDecoded: videoIsSoftwareDecoded,
                hasAudio: !demuxer.audioStreams.isEmpty,
                deliveryIsCached: deliveryIsCached,
                playbackRate: playbackRate,
                decodedFrameBytes: decodedFrameBytes,
                videoIntakeCount: videoIntake.count,
                videoIntakeBytes: videoIntake.byteCount
            ) {
            case .read:
                performDemuxStep()
            case .waitForVideo(let target):
                // Bounded: with the clock stopped nothing dequeues, and the
                // other queue's state can change underneath a wait on this
                // one. The loop re-evaluates the policy on its own (HEL-124).
                videoQueue.waitUntilBelow(target, timeout: Self.demuxWaitTimeout) {
                    self.softwareDecodeStage?.pendingCount ?? 0
                }
            case .waitForAudio(let target):
                audioQueue.waitUntilBelow(target, timeout: Self.demuxWaitTimeout)
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
        softwareDecodeStage?.invalidate()
        softwareDecodeStage = nil
        demuxer.close()
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Demux Close",
            signpostID: performanceSignpostID
        )
    }

    /// One av_read_frame worth of work; routes to the queues.
    ///
    /// The demux loop itself is one long-lived dispatch work item, so without
    /// an inner pool any autoreleased Core Media/Objective-C temporaries live
    /// until the player closes. Ready sample buffers escape through Lagoon's
    /// queues under ARC; only per-packet framework scratch objects drain here.
    nonisolated private func performDemuxStep() {
        #if DEBUG
        diagnosticFaultGate.waitBeforeDemuxStep()
        #endif
        autoreleasepool {
            step()
        }
    }

    /// One number for both decoded frames ready to present and packets the
    /// asynchronous software stage still owes. Recording it beside the
    /// active bound lets a Release HUD prove the ceiling over an entire
    /// injected outage, not only at whichever instant the viewer reads it.
    @discardableResult
    nonisolated private func recordVideoBacklog(hardLimit: Int) -> Int {
        let backlog = videoQueue.count + (softwareDecodeStage?.pendingCount ?? 0)
        shared.withLock {
            $0.videoQueueHardLimit = hardLimit
            $0.maximumVideoBacklog = max($0.maximumVideoBacklog, backlog)
        }
        return backlog
    }

    /// Everything the container had is in the queues or the decoders:
    /// flush the decoders, close the queues, and arm the finish boundary.
    nonisolated private func finishVideoInput() {
        shared.withLock { $0.endOfFilePendingIntake = false }
        do {
            try videoDecoder?.finish()
            // Frame threading always leaves pictures inside libavcodec;
            // they are the end of the film, so they have to be out before
            // the queue may call itself finished.
            try softwareDecodeStage?.finish()
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
    }

    /// Hands video to the next stage in order: straight through while the
    /// decoded queue has room and nothing is parked ahead of it, otherwise
    /// into the intake behind whatever is already waiting (HEL-124).
    nonisolated private func admitVideo(_ item: VideoIntakeItem) {
        videoFeedLock.lock()
        defer { videoFeedLock.unlock() }
        if videoIntake.isEmpty, decodedVideoBacklog() < currentVideoHardLimit() {
            deliverVideo(item)
        } else {
            videoIntake.append(item)
        }
    }

    nonisolated private func deliverVideo(_ item: VideoIntakeItem) {
        switch item {
        case .sample(let buffer):
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
        case .packet(let packet):
            softwareDecodeStage?.submit(packet)
        }
    }

    /// Moves parked video into the decoders while the decoded queue has
    /// room. Called by the demux loop between reads and by the video pump
    /// after every dequeue: the loop can sit in a network read for seconds
    /// while it reads ahead, and the decoded queue must not run dry behind
    /// a full intake in that time (measured on the Apple TV: `video=0/30/30
    /// intake=151/151`, frames dropping, before the pump drained too).
    nonisolated private func drainVideoIntake() {
        guard !shared.withLock({ $0.cancelled }) else { return }
        videoFeedLock.lock()
        defer { videoFeedLock.unlock() }
        let hardLimit = currentVideoHardLimit()
        while decodedVideoBacklog() < hardLimit, let item = videoIntake.popFirst() {
            deliverVideo(item)
        }
    }

    /// Decoded frames ready to present plus packets the software stage
    /// still owes; the figure every video limit is measured against.
    nonisolated private func decodedVideoBacklog() -> Int {
        videoQueue.count + (softwareDecodeStage?.pendingCount ?? 0)
    }

    nonisolated private func currentVideoHardLimit() -> Int {
        DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: videoDecoder != nil || demuxer.outputsDecodedVideo,
            videoIsSoftwareDecoded: demuxer.outputsDecodedVideo,
            decodedFrameBytes: softwareDecodeStage?.decodedFrameBytes ?? 0
        )
    }

    nonisolated private func step() {
        switch demuxer.readNext() {
        case .video(let buffer):
            recordMediaEnd(buffer)
            if let seconds = Self.presentationEnd(of: buffer) {
                // Stall detection compares the clock against this. Parked
                // video counts too: it is decoded the moment the decoded
                // queue has room, like the software stage's pending packets.
                shared.withLock { $0.videoBufferedTo = max($0.videoBufferedTo, seconds) }
            }
            admitVideo(.sample(buffer))
        case .videoPacket(let packet):
            // Stall detection and the finish boundary read the same media
            // time they did when this queue held the decoded frame: the
            // packet's, which is what the compressed path has always used.
            if let seconds = packet.endSeconds {
                shared.withLock {
                    $0.mediaEndSeconds = max($0.mediaEndSeconds, seconds)
                    $0.videoBufferedTo = max($0.videoBufferedTo, seconds)
                }
            }
            admitVideo(.packet(packet))
        case .audio(let buffers, let streamIndex):
            let (selected, delay, floor) = shared.withLock {
                ($0.selectedAudioStreamIndex, $0.audioDelaySeconds, $0.audioAdmissionFloorSeconds)
            }
            if streamIndex == selected {
                for buffer in buffers {
                    // Watched pre-delay: the delay shifts every stamp
                    // uniformly, so continuity is the same either side.
                    audioContinuity.observe(buffer)
                    let output = delay == 0 ? buffer : Self.retimed(buffer, by: delay)
                    // A seek into a coarse fragment reads that fragment's
                    // audio from its keyframe; the part before the target
                    // is never played and must not be counted (HEL-124).
                    if let end = Self.presentationEnd(of: output), end <= floor { continue }
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
            // Video still parked in the intake is the end of the film too.
            // The demux loop drains it as the decoded queue makes room and
            // finishes then (HEL-124).
            guard videoIntake.isEmpty else {
                shared.withLock { $0.endOfFilePendingIntake = true }
                return
            }
            finishVideoInput()
        case .failed(let message):
            videoQueue.markFinished()
            audioQueue.markFinished()
            // A read that kept failing past libavformat's own reconnects:
            // the transport, not the samples.
            let failure = PlaybackEngineFailure(
                cause: .delivery,
                message: "Playback failed in the Lagoon engine (\(message))."
            )
            Task { @MainActor in self.onError?(failure) }
            shared.withLock { $0.cancelled = true }
        }
    }

    /// Frames from the software decode stage.
    ///
    /// Deliberately not `acceptDecodedVideo`: a seek that has been *requested*
    /// and not yet performed is not a reason to throw these away. The stage
    /// discards its own pre-seek work when the demux loop resets it, and
    /// `videoQueue.reset()` clears anything that landed in between, so both
    /// ends of the seek are already covered.
    ///
    /// Dropping here instead starves the renderer exactly when stall recovery
    /// is re-priming — and re-priming is a seek every couple of seconds, so
    /// the drop keeps the queue empty, which keeps the stall going. Measured
    /// as 4 displayed frames against 2133 on the same title and position with
    /// the same stall loop running (HEL-137).
    nonisolated private func acceptSoftwareDecodedVideo(_ buffer: CMSampleBuffer) {
        guard !shared.withLock({ $0.cancelled }) else { return }
        videoQueue.enqueue(buffer)
        kickPumps()
    }

    nonisolated private func acceptDecodedVideo(_ buffer: CMSampleBuffer) {
        let shouldDrop = shared.withLock { $0.cancelled || $0.pendingSeekSeconds != nil }
        guard !shouldDrop else { return }
        videoQueue.enqueue(buffer)
        kickPumps()
    }

    nonisolated private func recordMediaEnd(_ buffer: CMSampleBuffer) {
        guard let end = Self.presentationEnd(of: buffer) else { return }
        shared.withLock { $0.mediaEndSeconds = max($0.mediaEndSeconds, end) }
    }

    nonisolated private static func presentationEnd(of buffer: CMSampleBuffer) -> Double? {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard pts.isValid, pts.seconds.isFinite else { return nil }
        let sampleDuration = CMSampleBufferGetDuration(buffer)
        let end = sampleDuration.isValid && sampleDuration.seconds.isFinite
            ? CMTimeAdd(pts, sampleDuration).seconds
            : pts.seconds
        return end.isFinite ? end : nil
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
        if UserDefaults.standard.bool(forKey: "debug.av1PipelineProfile") {
            let output = softwareDecodeStage?.outputModeName ?? "unknown"
            print("SoftwareVideoDecodeFailure output=\"\(output)\" detail=\"\(detail)\"")
        }
        // Every caller is a decoder: VideoToolbox refusing a session or a
        // frame, or libavcodec refusing the stream. Redelivering the same
        // bitstream cannot change that.
        let failure = PlaybackEngineFailure(
            cause: .undecodable,
            message: "Playback failed in the Lagoon engine (\(detail))."
        )
        Task { @MainActor in
            self.onError?(failure)
        }
    }

    /// Fill the queues enough that playback can start cleanly, then hand
    /// control back to the main actor to run the clock.
    nonisolated private func primeAndStart(at target: Double) {
        let generation = shared.withLock { state -> Int in
            state.audioAdmissionFloorSeconds = target
            return state.playbackGeneration
        }
        let hasAudio = !demuxer.audioStreams.isEmpty
        let videoHardLimit = DemuxBackpressurePolicy.videoHardLimit(
            videoIsDecoded: videoDecoder != nil || demuxer.outputsDecodedVideo,
            videoIsSoftwareDecoded: demuxer.outputsDecodedVideo,
            decodedFrameBytes: softwareDecodeStage?.decodedFrameBytes ?? 0
        )
        recordVideoBacklog(hardLimit: videoHardLimit)
        let playbackRate = shared.withLock { $0.playbackRate }
        let baseVideoReserve = demuxer.outputsDecodedVideo ? 18 : 12
        let minimumVideoReserve = min(
            Int(ceil(Double(baseVideoReserve) * playbackRate)),
            max(videoHardLimit - 1, 1)
        )
        let minimumAudioReserve = 1.25 * playbackRate
        // Audio ahead of the start position wherever it sits: the pump may
        // already have handed the renderer some of it, and that share is
        // exactly what `audioQueue` no longer shows. Audio that ends before
        // the target counts for nothing on either side; a seek into a
        // coarse fragment primes on exactly that otherwise (HEL-123/124).
        let audioAhead = { () -> Double in
            let delivered = self.shared.withLock { state in
                state.lastEnqueuedAudioEndSeconds.map { max($0 - target, 0) } ?? 0
            }
            return delivered + self.audioQueue.bufferedDuration(after: target)
        }
        while (videoQueue.count < minimumVideoReserve || (hasAudio && audioAhead() < minimumAudioReserve)),
              !videoQueue.isFinished,
              !shared.withLock({ $0.cancelled }) {
            if shared.withLock({ $0.pendingSeekSeconds != nil }) { return }
            let pendingDecode = softwareDecodeStage?.pendingCount ?? 0
            recordVideoBacklog(hardLimit: videoHardLimit)
            guard videoQueue.count + pendingDecode >= videoHardLimit else {
                performDemuxStep()
                continue
            }
            // The decoded queue is full and audio is still short. On an HLS
            // fragment the audio block sits behind the rest of the video
            // block, so keep reading and park the video compressed, up to the
            // intake's own bounds (HEL-124).
            if hasAudio, audioAhead() < minimumAudioReserve,
               videoIntake.count < DemuxBackpressurePolicy.videoIntakeHardLimit,
               videoIntake.byteCount < DemuxBackpressurePolicy.videoIntakeByteBudget,
               !shared.withLock({ $0.endOfFilePendingIntake }) {
                performDemuxStep()
                continue
            }
            // Everything the memory limit allows has been read. When frames
            // are still inside the decoder the cushion is on its way, and
            // waiting for it is the difference between starting playback on a
            // full renderer and starting it on an empty one — with decode off
            // this queue, "read enough" and "decoded enough" are no longer the
            // same moment (HEL-137).
            guard let stage = softwareDecodeStage, pendingDecode > 0 else { break }
            stage.waitUntilPendingBelow(pendingDecode)
        }
        recordVideoBacklog(hardLimit: videoHardLimit)
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
        let locallyDecoded = demuxer.outputsDecodedAudio(streamIndex: stream.streamIndex)
        if locallyDecoded {
            diagnostic += " · local LPCM"
        }
        if stream.isAtmos {
            diagnostic += " · Atmos (JOC)"
        } else if stream.codecName == "eac3" {
            diagnostic += " · no JOC"
        }
        let publishedDiagnostic = diagnostic
        Task { @MainActor in
            self.audioDiagnostic = publishedDiagnostic
            self.audioOutputPathDiagnostic = locallyDecoded ? "LPCM" : "compressed"
        }
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
        guard let description = demuxer.videoStream?.formatDescription else { return .zero }
        // Presentation, not coded, dimensions. This size positions the
        // subtitle overlay (`displayedVideoRect`), so an anamorphic stream —
        // a 720x576 PAL rip displaying 4:3 — would otherwise have its cues
        // laid out against the wrong box.
        return CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
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
                self.rearmRequestsIfNeeded()
            } while self.pumpKickState.completeCycle()
        }
    }

    /// AVFoundation calls a renderer's request block whenever the renderer
    /// wants more, and keeps calling it for as long as the block gives it
    /// nothing. With the software decoder starving the video queue, that
    /// loop measured 0.4 of a core at the highest priority in the process,
    /// enqueueing nothing, on a device whose decoder was short exactly that
    /// much CPU (HEL-137). The audio queue is empty almost always, because
    /// the renderer takes audio as fast as it is demuxed, so its block spun
    /// the same way on every title.
    ///
    /// So a request is armed only while there is something to give: a pump
    /// that finds its queue empty stops it, and `kickPumps()`, which runs
    /// whenever a queue receives a buffer, arms it again if the renderer
    /// could not take everything at once.
    nonisolated private func armVideoRequests(_ renderer: AVSampleBufferVideoRenderer) {
        guard !videoRequestsArmed else { return }
        videoRequestsArmed = true
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpVideo(fromRequest: true)
        }
    }

    nonisolated private func armAudioRequests(_ renderer: AVSampleBufferAudioRenderer) {
        guard !audioRequestsArmed else { return }
        audioRequestsArmed = true
        renderer.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpAudio(fromRequest: true)
        }
    }

    nonisolated private func rearmRequestsIfNeeded() {
        if let renderer = videoRenderer, videoQueue.count > 0 {
            armVideoRequests(renderer)
        }
        #if DEBUG
        // A request block must be armed only while the pump has something to
        // give it. During an injected hold, the queue keeps filling from the
        // demuxer, so every `kickPumps` cycle re-armed this block, the
        // callback fired once and disarmed it again, dozens of times a
        // second (HEL-137's armVideoRequests lesson, applied here too).
        if let renderer = audioRenderer, audioQueue.count > 0, !diagnosticFaultGate.audioDeliverySuspended {
            armAudioRequests(renderer)
        }
        #else
        if let renderer = audioRenderer, audioQueue.count > 0 {
            armAudioRequests(renderer)
        }
        #endif
    }

    nonisolated private func pumpVideo(fromRequest: Bool = false) {
        guard let renderer = videoRenderer else { return }
        while renderer.isReadyForMoreMediaData {
            guard let buffer = videoQueue.dequeue() else {
                if fromRequest {
                    idleRequestCounter.wrappingAdd(1, ordering: .relaxed)
                }
                if videoRequestsArmed {
                    videoRequestsArmed = false
                    renderer.stopRequestingMediaData()
                }
                return
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            if pts.isValid {
                shared.withLock { state in
                    if state.firstEnqueuedVideoPTS == nil {
                        state.firstEnqueuedVideoPTS = pts
                    }
                }
            }
            let enqueueStarted = ProcessInfo.processInfo.systemUptime
            renderer.enqueue(buffer)
            av1PipelineTimings.recordEnqueue(
                from: enqueueStarted,
                to: ProcessInfo.processInfo.systemUptime
            )
            // A frame left the decoded queue; the intake may have its
            // replacement (HEL-124).
            drainVideoIntake()
        }
    }

    nonisolated private func sampleAV1Pipeline() {
        guard let renderer = videoRenderer else { return }
        av1PipelineTimings.sample(
            at: ProcessInfo.processInfo.systemUptime,
            rendererReady: renderer.isReadyForMoreMediaData,
            renderQueue: videoQueue.count,
            decodePending: softwareDecodeStage?.pendingCount ?? 0
        )
    }

    nonisolated private func pumpAudio(fromRequest: Bool = false) {
        guard let renderer = audioRenderer else { return }
        #if DEBUG
        guard !diagnosticFaultGate.audioDeliverySuspended else {
            if audioRequestsArmed {
                audioRequestsArmed = false
                renderer.stopRequestingMediaData()
            }
            return
        }
        #endif
        while renderer.isReadyForMoreMediaData {
            guard let buffer = audioQueue.dequeue() else {
                if fromRequest {
                    idleRequestCounter.wrappingAdd(1, ordering: .relaxed)
                }
                if audioRequestsArmed {
                    audioRequestsArmed = false
                    renderer.stopRequestingMediaData()
                }
                return
            }
            renderer.enqueue(buffer)
            if let end = Self.presentationEnd(of: buffer) {
                shared.withLock { $0.lastEnqueuedAudioEndSeconds = end }
            }
        }
    }
}

// MARK: - Support types

/// Why an audio renderer is being replaced. The two cases differ in what
/// the viewer is owed afterwards, which is the only reason they are not one.
nonisolated enum AudioRendererReplacement: Equatable {
    /// The media server restarted and invalidated every AVFoundation audio
    /// object. Apple requires an app to wait for an explicit viewer or
    /// remote-command action before resuming, so this one stays paused.
    case mediaServicesReset
    /// The renderer reported `.failed`, which Apple documents as terminal.
    /// Nothing the viewer did caused it and nothing they can do fixes it, so
    /// playback resumes on its own once the replacement is fed.
    case rendererFailed

    var staysPaused: Bool {
        switch self {
        case .mediaServicesReset: true
        case .rendererFailed: false
        }
    }

    var reason: StaticString {
        switch self {
        case .mediaServicesReset: "mediaServicesReset"
        case .rendererFailed: "rendererFailed"
        }
    }

    /// Only reached when the replacement itself fails, which leaves playback
    /// with no audio path at all. `detail` is the renderer's own error where
    /// it had one — the server's reason beats ours (HEL-98's lesson).
    func failureMessage(detail: String?) -> String {
        switch self {
        case .mediaServicesReset:
            "Playback audio could not recover after the media service restarted."
        case .rendererFailed:
            if let detail, !detail.isEmpty {
                "Playback audio failed and could not be restarted (\(detail))."
            } else {
                "Playback audio failed and could not be restarted."
            }
        }
    }
}

nonisolated enum StallRecoveryDecision: Equatable {
    case wait
    case resume
    case reprime
}

/// Pure policy behind the asynchronous recovery loop so an infinite stall is
/// a deterministic unit-test failure. Twelve decoded frames matches the
/// demuxer's low-water cushion; five seconds is long enough for the normal
/// network refill path but bounded well below a visibly frozen player.
/// Which half of the pipeline has run dry, if either (HEL-123).
nonisolated enum PlaybackStarvation: String, Equatable {
    case none
    case video
    case audio
}

/// Video starvation stops the clock. Audio starvation is **only counted**,
/// and the difference is the whole lesson of HEL-123.
///
/// The original defect is real: an audio queue at zero produced no stall,
/// no buffering state and no counter movement, so a film could play on with
/// the picture running and no sound while every indicator read healthy.
/// The first fix treated that as a stall and stopped the clock for it, and
/// that broke playback for every title with audio — verified against Ted 2
/// and GTA VI, both of which had been playing correctly.
///
/// **`audioQueue` depth is not a measure of audio starvation.** `pumpAudio`
/// drains it into `AVSampleBufferAudioRenderer` for as long as the renderer
/// says `isReadyForMoreMediaData`, so the buffered seconds live inside the
/// renderer and Lagoon's queue sits near zero on a *healthy* title. Reading
/// it as starvation fires constantly, and stopping the clock for it turns
/// continuous playback into a buffer/play/buffer cycle.
///
/// Switching the reading from packet count to buffered seconds does not fix
/// that, which is the trap worth recording: this ticket's own text warns
/// that a count near zero cannot distinguish a starved feed from one being
/// taken as fast as it arrives, and the seconds are the same queue measured
/// in different units. Both are the wrong side of the pump. A true audio
/// starvation signal has to come from the renderer, and finding one is
/// still open.
///
/// So `.audio` is a reported condition and never a recovery trigger. That
/// is the minimum this ticket asked for — counted and reported — and it is
/// as far as the evidence supports going.
///
/// Pure so the decision can be pinned by tests rather than reproduced on
/// hardware: the engine only assembles the snapshot.
nonisolated enum PlaybackStarvationPolicy {
    /// How little lead the clock may have over delivered video before the
    /// picture is called starved.
    static let videoLeadSeconds = 0.2
    /// Renderer delivery lead, not Lagoon queue depth. Build 66 proved that
    /// both packet count and buffered duration on the app side normally sit
    /// near zero because AVFoundation takes the samples immediately.
    static let audioFloorSeconds = 0.25

    struct Snapshot {
        var isBuffering = false
        var isPaused = false
        var didFinish = false
        var position: Double = 0
        var duration: Double = 0
        var rate: Double = 1
        var videoQueueCount = 0
        var videoQueueFinished = false
        var videoBufferedTo: Double = 0
        var hasAudio = false
        var audioQueueFinished = false
        /// nil until the first audio sample has actually reached the
        /// renderer. Startup/seek cannot be called starved before that.
        var audioDeliveryLeadSeconds: Double?
    }

    static func starvation(_ snapshot: Snapshot) -> PlaybackStarvation {
        guard !snapshot.isBuffering,
              !snapshot.isPaused,
              !snapshot.didFinish,
              snapshot.duration <= 0 || snapshot.position < snapshot.duration - 1
        else { return .none }
        // Video first. It is the half that freezes the picture, and where
        // both are dry the recovery wanted is the same either way.
        //
        // The margins are media time, which drains `rate` times faster than
        // real time, so both scale with it to keep the same wall-clock
        // cushion above 1x.
        if !snapshot.videoQueueFinished,
           snapshot.videoQueueCount == 0,
           snapshot.videoBufferedTo - snapshot.position < videoLeadSeconds * snapshot.rate {
            return .video
        }
        if snapshot.hasAudio,
           !snapshot.audioQueueFinished,
           let lead = snapshot.audioDeliveryLeadSeconds,
           lead < audioFloorSeconds * snapshot.rate {
            return .audio
        }
        return .none
    }
}

#if DEBUG
/// Two off-by-default, bounded playback fault gates shared by the Debug-only
/// diagnostics toggle and the simulator regression suite. The demux side
/// uses a condition so the injected outage consumes no CPU and teardown can
/// always wake it.
nonisolated final class PlaybackDiagnosticFaultGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isCancelled = false
    private var isDemuxDeliverySuspended = false
    private var isAudioDeliverySuspended = false

    var audioDeliverySuspended: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isAudioDeliverySuspended
    }

    func setAudioDeliverySuspended(_ suspended: Bool) {
        condition.lock()
        isAudioDeliverySuspended = suspended && !isCancelled
        condition.unlock()
    }

    func setDemuxDeliverySuspended(_ suspended: Bool) {
        condition.lock()
        isDemuxDeliverySuspended = suspended && !isCancelled
        if !isDemuxDeliverySuspended { condition.broadcast() }
        condition.unlock()
    }

    func waitBeforeDemuxStep() {
        condition.lock()
        while isDemuxDeliverySuspended && !isCancelled {
            condition.wait()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        isDemuxDeliverySuspended = false
        isAudioDeliverySuspended = false
        condition.broadcast()
        condition.unlock()
    }
}
#endif

nonisolated enum StallRecoveryPolicy {
    static let confirmationDelay: Duration = .seconds(1)
    static let resumeVideoCount = 12
    static let reprimeAfter: Duration = .seconds(5)
    /// Renderer delivery lead required before an audio-gated resume,
    /// scaled by the same clamped playback rate as `resumeVideoCount`.
    static let resumeAudioLeadSeconds = 1.0
    /// When the renderer reports sufficient data for a reliable start, the
    /// delivery lead must still be at least this clear of the starvation
    /// floor (`PlaybackStarvationPolicy.audioFloorSeconds`, 0.25 s) so the
    /// first observer tick after a resume cannot re-arm a stall.
    static let resumeAudioLeadFloorSeconds = 0.5

    /// `.video` always confirms a pending stall. `.audio` confirms only
    /// when `buffersOnAudioStarvation` is on. `.none` never confirms one.
    static func confirms(_ starvation: PlaybackStarvation, buffersOnAudioStarvation: Bool) -> Bool {
        switch starvation {
        case .video: return true
        case .audio: return buffersOnAudioStarvation
        case .none: return false
        }
    }

    /// Was video-only because app-side audio depth is structurally near
    /// zero: `audioQueue` drains into the renderer as fast as it fills, so
    /// requiring a cushion there hung every video stall to `reprimeAfter`
    /// (build 66). The audio condition below reads renderer delivery lead
    /// and the renderer's own readiness flag. Audio waiting in Lagoon's
    /// queue is deliberately not counted, because audio behind a renderer
    /// that is not taking it is not audio that will play; counting it
    /// resumed a held renderer into silence three times in four seconds.
    /// It only applies when `audioRequired` is true. The engine passes
    /// that from `buffersOnAudioStarvation`, so a video stall behaves
    /// exactly as before while the mode is off.
    ///
    /// The renderer's own readiness flag decides in the normal case,
    /// because with the clock stopped the renderer takes about a second of
    /// audio and then stops asking, which parks the lead just under a
    /// fixed one-second threshold (measured in the simulator at 0.996 s).
    /// The full-second lead remains as the fallback when the flag is not
    /// set.
    ///
    /// The audio condition applies to a video-caused stall too when the
    /// mode is on, because resuming on video alone with the renderer still
    /// dry would re-starve within a second and turn one silence into a
    /// stutter.
    static func decision(
        elapsed: Duration,
        videoQueueCount: Int,
        videoQueueFinished: Bool,
        playbackRate: Double = 1,
        audioRequired: Bool = false,
        audioDeliveryLeadSeconds: Double? = nil,
        audioRendererHasSufficientData: Bool = false
    ) -> StallRecoveryDecision {
        let requiredVideoCount = Int(ceil(
            Double(resumeVideoCount) * PlaybackRatePolicy.clamped(playbackRate)
        ))
        let videoReady = videoQueueCount >= requiredVideoCount || videoQueueFinished
        let rate = PlaybackRatePolicy.clamped(playbackRate)
        let lead = audioDeliveryLeadSeconds ?? -.infinity
        let audioReady = !audioRequired
            || lead >= resumeAudioLeadSeconds * rate
            || (audioRendererHasSufficientData && lead >= resumeAudioLeadFloorSeconds * rate)
        if videoReady && audioReady {
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
        /// Whether the stream got a playback cache. Read on the main actor
        /// so the HUD can show which demux cushion is in force (HEL-130).
        var deliveryIsCached = true
        /// Furthest presentation end observed across audio and video. EOF
        /// uses this as the renderer boundary even without container duration.
        var mediaEndSeconds: Double = 0
        var audioDelaySeconds: Double = 0
        /// Media seconds consumed per wall-clock second. Demux watermarks
        /// use it to retain the same real-time cushion above 1x.
        var playbackRate: Double = 1
        /// First sample actually accepted by the renderer after attach/flush.
        var firstEnqueuedVideoPTS: CMTime?
        /// Furthest audio presentation end actually handed to AVFoundation.
        /// Compared with the synchronizer clock for HEL-123; unlike the app
        /// queue it includes samples AVFoundation already owns.
        var lastEnqueuedAudioEndSeconds: Double?
        /// Captured from the active decode path so the hardware/simulator
        /// probe can assert HEL-124 never exceeds its real memory bound.
        var videoQueueHardLimit = 0
        /// Peak decoded-frame-plus-pending backlog observed under that
        /// bound, retained for the whole engine session and Release HUD.
        var maximumVideoBacklog = 0
        /// End of file was read while the intake still held video. The
        /// demux loop finishes the queues once that has drained.
        var endOfFilePendingIntake = false
        /// The position playback last started from. Audio that ends at or
        /// before it is audio the renderer discards; queued, it would count
        /// toward the audio high water and throttle the read-ahead exactly
        /// when the renderer holds least (HEL-124).
        var audioAdmissionFloorSeconds: Double = -.infinity
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

    // A stream arriving without a playback cache has nothing between the
    // network and the renderers: no sparse cache, no proactive range fill,
    // no playhead prefetch. The demux queues are the entire cushion, so
    // they are asked to be a bigger one (HEL-130).
    //
    // **Only audio grows, and the asymmetry is the whole point.** Video's
    // queue holds decoded frames — 24.9 MB each at 4K 10-bit, which is why
    // its hard limit is 30 and why HEL-126 exists — while audio holds
    // compressed packets at roughly 80 KB a second. Doubling the audio
    // cushion costs about 1.5 MB against a video queue already permitted
    // 746 MB. Even the worst case, a locally decoded 8-channel track held
    // as float LPCM, is about 26 MB.
    //
    // Audio is also the half that has no cushion of its own. The video
    // renderer coasts on frames it already holds, which is why a starved
    // transcode reaches the viewer as silence over a moving picture rather
    // than as a freeze (HEL-123).
    private static let uncachedAudioHighWater = 360
    private static let uncachedAudioLowWater = 288
    private static let uncachedAudioHardWater = 540
    /// The margin video must leave audio covered for before it may park on
    /// its own high water. Larger without a cache, because the drain it has
    /// to survive is however long the network takes to deliver the next
    /// segment rather than a cache read.
    private static let uncachedAudioSafetySeconds = 3.0
    /// Bounds on the compressed video the demux loop may park past the
    /// decoded limit while it reads on for audio (HEL-124). Both have to
    /// hold a whole fragment, because the audio block sits behind the
    /// video block and the read-ahead only helps if it reaches it: 600
    /// access units is 25 s at 24 fps or 10 s at 60 fps, and 128 MB is
    /// 10 s at 100 Mbps. A lead-triggered read-ahead was tried first and
    /// starved a 4K remux anyway, because reading a 60 MB video block over
    /// the network takes longer than any cushion the renderer holds; the
    /// read has to start the moment the decoded queue is full, and the
    /// audio high water below is what bounds it.
    static let videoIntakeHardLimit = 600
    static let videoIntakeByteBudget = 128 * 1_048_576

    /// The audio depth being aimed for, so the HUD can show which profile
    /// is in force rather than leaving its absence to be inferred.
    static func audioCushionTarget(deliveryIsCached: Bool) -> Int {
        deliveryIsCached ? audioHighWater : uncachedAudioHighWater
    }

    /// The most decoded frames Lagoon's own queue may hold, bounded by count
    /// and — once a frame is expensive enough for the count to stop meaning
    /// anything — by bytes (HEL-137 lever 5).
    ///
    /// 42 frames was chosen when the software path carried SD and HD: at
    /// 1080p 10-bit that is 250 MB. Software AV1 reaching 4K made the same
    /// 42 frames 1.05 GB of P010 surfaces, in a process jetsam has already
    /// killed once at 2.1 GB (HEL-109). The budget below is the ceiling the
    /// hardware-decoded path was already allowed — 30 frames of 4K P010 —
    /// so every configuration measured before this keeps the limit it was
    /// measured with, and only 4K software decode comes back under it.
    static let decodedQueueByteBudget: Int64 = 30 * 24_883_200

    /// Never below this however large a frame gets: a queue has to hold the
    /// codec's reorder depth plus a cushion or it stops being a queue.
    private static let decodedQueueFrameFloor = 8

    static func videoHardLimit(
        videoIsDecoded: Bool,
        videoIsSoftwareDecoded: Bool = false,
        decodedFrameBytes: Int64 = 0
    ) -> Int {
        let byCount = videoIsSoftwareDecoded ? 42 : (videoIsDecoded ? 30 : 120)
        guard decodedFrameBytes > 0 else { return byCount }
        let byBytes = Int(decodedQueueByteBudget / decodedFrameBytes)
        return max(min(byCount, byBytes), decodedQueueFrameFloor)
    }

    /// `deliveryIsCached` defaults true, which is the shape every caller had
    /// before the uncached profile existed.
    static func decision(
        videoCount: Int,
        audioCount: Int,
        audioBufferedSeconds: Double,
        videoFrameRate: Double,
        videoIsDecoded: Bool,
        videoIsSoftwareDecoded: Bool = false,
        hasAudio: Bool,
        deliveryIsCached: Bool = true,
        playbackRate: Double = 1,
        decodedFrameBytes: Int64 = 0,
        videoIntakeCount: Int = 0,
        videoIntakeBytes: Int = 0
    ) -> DemuxBackpressureDecision {
        let audioHighWater = deliveryIsCached ? Self.audioHighWater : uncachedAudioHighWater
        let audioLowWater = deliveryIsCached ? Self.audioLowWater : uncachedAudioLowWater
        let audioHardWater = deliveryIsCached ? Self.audioHardWater : uncachedAudioHardWater
        let audioSafetySeconds = deliveryIsCached
            ? Self.audioSafetySeconds
            : uncachedAudioSafetySeconds
        let videoHardWater = videoHardLimit(
            videoIsDecoded: videoIsDecoded,
            videoIsSoftwareDecoded: videoIsSoftwareDecoded,
            decodedFrameBytes: decodedFrameBytes
        )
        let safePlaybackRate = PlaybackRatePolicy.clamped(playbackRate)
        let baseVideoHighWater = videoIsSoftwareDecoded ? 30 : (videoIsDecoded ? 18 : 90)
        let baseVideoLowWater = videoIsSoftwareDecoded ? 24 : (videoIsDecoded ? 12 : 72)
        // Scale both watermarks with the rate, then clamp them as a pair.
        // Clamping the low water against the *already clamped* high water
        // collapses the drain batch to a single frame once the scaled high
        // water saturates: 41/40 for software decode and 119/118 for
        // compressed h264 at 2x. The batched drain below then degenerates
        // into a read-one/wait-one handshake and the decoded queue parks one
        // frame under the hard limit — ~254 MB of 1080p P010 surfaces.
        let drainBatch = max(baseVideoHighWater - baseVideoLowWater, 1)
        let videoHighWater = min(
            Int(ceil(Double(baseVideoHighWater) * safePlaybackRate)),
            max(videoHardWater - 1, 1)
        )
        let scaledVideoLowWater = min(
            Int(ceil(Double(baseVideoLowWater) * safePlaybackRate)),
            videoHighWater - drainBatch
        )
        let videoLowWater = max(min(scaledVideoLowWater, videoHighWater - 1), 1)
        let safeFrameRate = videoFrameRate.isFinite && videoFrameRate >= 1
            ? videoFrameRate
            : 24

        if videoCount >= videoHighWater {
            let drainSeconds = Double(max(videoCount - videoLowWater, 0)) / safeFrameRate
            let audioCanCoverDrain = !hasAudio
                || audioBufferedSeconds >= audioSafetySeconds * safePlaybackRate + drainSeconds
            // HEL-124 residual: `audioBufferedSeconds` is the app-side queue,
            // which sits near zero on any title with audio because the
            // renderer takes samples as fast as they are demuxed, so this
            // batch-drain branch is effectively unreachable there and the
            // loop instead parks at the hard limit below in one-slot pacing.
            // The read-ahead rule above is what keeps audio fed when the
            // interleave is coarser than the cushion; this branch stays.
            if audioCanCoverDrain {
                return .waitForVideo(below: videoLowWater)
            }
            if videoCount >= videoHardWater {
                // The decoded queue is full. With audio in the stream the
                // demuxer may not sit here: on an HLS fragment the audio
                // block is behind the video block, so reaching it means
                // reading video the decoded queue has no room for, which
                // parks compressed in the intake (HEL-124). The audio high
                // water is what stops the read-ahead on a finely interleaved
                // stream, and the intake's own bounds stop it on a coarse
                // one. Without audio, one slot at a time as before.
                if hasAudio,
                   audioCount < audioHighWater,
                   videoIntakeCount < videoIntakeHardLimit,
                   videoIntakeBytes < videoIntakeByteBudget {
                    return .read
                }
                return .waitForVideo(below: videoHardWater)
            }
            return .read
        }

        if hasAudio, audioCount >= audioHighWater {
            let baseVideoSafetyCount = videoIsSoftwareDecoded ? 24 : (videoIsDecoded ? 12 : 36)
            let videoSafetyCount = min(
                Int(ceil(Double(baseVideoSafetyCount) * safePlaybackRate)),
                max(videoHardWater - 1, 1)
            )
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
        if let expectedNext {
            let delta = CMTimeSubtract(pts, expectedNext).seconds
            if abs(delta) > 0.001 {
                gaps += 1
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Audio Timestamp Gap",
                    "deltaMs=%{public}.3f expected=%{public}.6f actual=%{public}.6f durationMs=%{public}.3f count=%{public}d",
                    delta * 1_000,
                    expectedNext.seconds,
                    pts.seconds,
                    duration.seconds * 1_000,
                    gaps
                )
            }
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
    /// Seconds of queued audio that end after `seconds`. Priming after a
    /// seek lands inside a fragment whose audio block starts at the
    /// keyframe, and audio that ends before the target is audio the
    /// renderer will discard, not a cushion (HEL-124).
    func bufferedDuration(after seconds: Double) -> Double {
        condition.lock()
        defer { condition.unlock() }
        guard head < buffers.count,
              let first = buffers[head],
              let last = buffers.last ?? nil else { return 0 }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        guard firstPTS.isValid, lastPTS.isValid else { return 0 }
        let duration = CMSampleBufferGetDuration(last)
        let end = duration.isValid && duration.seconds.isFinite
            ? CMTimeAdd(lastPTS, duration).seconds
            : lastPTS.seconds
        return max(end - max(firstPTS.seconds, seconds), 0)
    }

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

    /// Used by the Debug audio hold to discard audio that ended before the
    /// clock; a real recovery never hands the renderer such samples.
    func dropLeading(while shouldDrop: (CMSampleBuffer) -> Bool) {
        condition.lock()
        while head < buffers.count, let buffer = buffers[head], shouldDrop(buffer) {
            buffers[head] = nil
            head += 1
            if head >= 64, head * 2 >= buffers.count {
                buffers.removeFirst(head)
                head = 0
            }
        }
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
    ///
    /// `alsoCounting` adds work already spoken for but not yet in this queue —
    /// video sitting in the software decode stage (HEL-137). It is evaluated
    /// under the lock on every wake, so the stage settles this wait by
    /// signalling here rather than needing a condition of its own.
    /// With a `timeout`, returns after at most that long even if the queue
    /// is still full, so the caller can re-evaluate something the queue
    /// cannot see (HEL-124).
    func waitUntilBelow(
        _ targetCount: Int,
        timeout: TimeInterval? = nil,
        alsoCounting: () -> Int = { 0 }
    ) {
        condition.lock()
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        while buffers.count - head + alsoCounting() >= targetCount, !finished, !waitsInterrupted {
            if let deadline {
                guard condition.wait(until: deadline) else { break }
            } else {
                condition.wait()
            }
        }
        condition.unlock()
    }

    /// Re-evaluate the waits without the queue itself having changed — what
    /// the decode stage calls when a packet leaves it.
    func signalWaiters() {
        condition.lock()
        condition.broadcast()
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
