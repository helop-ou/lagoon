import LagoonEngine
import MediaAccessibility
import Observation
import OSLog
import SwiftUI
import UIKit

/// Milliseconds for a `Duration`, for DecodeTrace and soak lines.
private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// Negotiates the stream with Jellyfin, runs the Lagoon engine (the app's
/// only player), and owns progress reporting.
@Observable
@MainActor
final class PlaybackController {
    private(set) var engine: SampleBufferPlayerEngine?
    /// Changes when a new engine replaces the old one; resets episode-scoped
    /// chrome.
    private(set) var playbackIdentity = ""
    /// Identity of the hosted display layer. UI tests compare it across
    /// autoplay to prove the render surface was kept.
    private(set) var playerSurfaceIdentity = ""
    private(set) var playerInfo: PlayerItemInfo?
    private(set) var errorMessage: String?
    private(set) var didFinish = false
    private(set) var isExternalPlaybackRouteActive = false
    let subtitleSearch = SubtitleSearchCoordinator()
    let incidents = PlaybackIncidentMonitor()

    /// The next episode, resolved at start so Up Next can appear instantly.
    /// Nil for movies and at the end of a series.
    private(set) var nextUp: MediaItem? {
        didSet { automation.setNextUpAvailable(nextUp != nil) }
    }
    let automation = PlaybackAutomation()
    /// The lower quality offered after repeated stalls.
    let qualityOffer = PlaybackQualityOffer()
    @ObservationIgnored private var qualityOfferPolicy = PlaybackQualityOfferPolicy()
    /// Stalls of the current engine already counted.
    @ObservationIgnored private var observedStallCount = 0
    /// The ceiling the viewer accepted. Kept for the rest of the session:
    /// the link that stalled one episode will stall the next.
    @ObservationIgnored private var qualityCap: Int?
    /// The playing source's bitrate, which the lower quality steps under.
    @ObservationIgnored private var playingSourceBitrate: Int?
    @ObservationIgnored private var isChangingQuality = false
    /// Set before the autoplay hand-off runs, so the view's end-of-file
    /// handling does not close the player underneath it.
    private(set) var isAutoplayPending = false
    /// iOS background with the picture off: every engine, including an
    /// autoplay successor, plays audio only until the app returns.
    private var videoOutputSuspended = false
    /// iOS background, picture showing or not. Every engine is told, so a
    /// decode session the system takes there waits for the foreground.
    private var isInBackground = false
    /// Fires each time the engine anchors its first frame after a load or
    /// seek. Rewired onto each successor, so a SyncPlay driver never holds an
    /// engine.
    @ObservationIgnored var onEngineReady: (() -> Void)?
    /// The player session is over for good.
    @ObservationIgnored var onClosed: (() -> Void)?
    /// Buffering started or stopped (stall, seek, initial prime). Rewired
    /// onto each successor like `onEngineReady`.
    @ObservationIgnored var onBufferingChanged: ((Bool) -> Void)?
    /// Set while a SyncPlay group owns the transport. Weak so neither end
    /// keeps the other alive. When nil, every `user…` method acts locally.
    @ObservationIgnored weak var groupTransport: (any GroupTransportRequests)?
    /// Extra HUD lines, such as SyncPlay's `Sync:` line.
    @ObservationIgnored var groupHUDLines: (() -> [String])?
    #if os(iOS)
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    /// Whether PiP is showing the picture, or about to. Answered by the
    /// player view, which owns the PiP coordinator.
    @ObservationIgnored var isPictureInPictureShowing: () -> Bool = { false }
    #endif

    private(set) var hudLines: [String] = []
    /// Read through to the engine, which owns the cache; nothing here
    /// mirrors it. HLS has no byte-range model.
    var bufferedFraction: Double? { engine?.bufferState.bufferedFraction }
    var bufferedRanges: [PlaybackBufferedRange] { engine?.bufferState.bufferedRanges ?? [] }
    var playheadPrefetchCount: Int { engine?.bufferState.playheadPrefetchCount ?? 0 }

    private var client: JellyfinClient?
    /// Kept so a failed attempt can be replayed on the next rung.
    private var currentMedia: MediaItem?
    /// The current rung and the position a retry resumes from. A new item
    /// starts at the top of the ladder.
    private var delivery: PlaybackDelivery = .negotiated
    private var deliveryItemId: String?
    /// A position that outranks every resume rule for one start: a SyncPlay
    /// join, or a fallback retry resuming where the failed rung stopped.
    private var startPositionOverride: Double?
    /// Load paused at the start position; a group member is started later
    /// by `playGroup(atHostTime:)`.
    private var startsPaused = false
    /// Playing a downloaded file. Always false on tvOS.
    private var isLocalPlayback = false
    /// Set when a downloaded file fails, so the retry goes to the server
    /// instead of looping on the same broken file. A new item resets it.
    private var skipsLocalPlayback = false
    /// One rung at a time. Renderer and demux can report the same failure,
    /// and two fallbacks in flight would skip the remux rung.
    private var isFallingBack = false
    /// Every rung this item has descended, and the failure that forced it.
    /// Shown in the HUD, because a fallback that succeeds never reaches
    /// `errorMessage`.
    private(set) var deliveryFallbacks: [PlaybackDeliveryFallbackRecord] = []
    private var itemId = ""
    private var mediaSourceId = ""
    private var playMethod: PlayMethod = .directPlay

    var activePlayMethod: PlayMethod { playMethod }
    /// `PlayMethod` reports remux and transcode both as `Transcode`; the
    /// regression probe needs the rung to tell them apart.
    var activeDeliveryRung: PlaybackDelivery { delivery }

    var isPlaybackCacheActive: Bool {
        engine?.bufferState.isActive ?? false
    }
    @ObservationIgnored private var reporting: PlaybackReportingSession?
    @ObservationIgnored private let diagnosticSampler = PlaybackDiagnosticsSampler()
    private var isClosed = false
    private var lastKnownPosition: Double = 0
    /// Whether the current engine has presented its start. Until then its
    /// `timePosition` reads 0 rather than the requested start.
    private var engineHasStarted = false
    private var nextUpTask: Task<Void, Never>?
    @ObservationIgnored private let successorPreparation = PlaybackSuccessorPreparation()
    /// Guards the hand-off: `didFinish` and an expiring countdown can both
    /// fire, and advancing twice would skip an episode.
    private(set) var isAdvancing = false
    /// Separate from `isAdvancing`: reporting may still be finishing after
    /// the successor's first frame, and must not leave a spinner over video.
    private(set) var isTransitionOverlayVisible = false
    /// Time from action or end of file to the successor's first frame, for
    /// the HUD and regression probe. Nil before the first hand-off.
    private(set) var lastHandoffMilliseconds: Double?
    /// Soak hook (`debug.soakExitAtSeconds`): flips at the configured
    /// position so the view drives a real `dismiss()`. Not `didFinish`,
    /// which means the file ran out.
    private(set) var soakExitRequested = false
    /// Lets `close()` time the whole soak exit from the request.
    @ObservationIgnored private var soakExitRequestedAt: ContinuousClock.Instant?
    /// The viewer's track picks, carried into the next episode.
    private var trackCarry: PlaybackTrackPlan.Carry?
    /// This attempt's track selection, and what recording a choice needs.
    @ObservationIgnored private var trackPlan: PlaybackTrackPlan?
    /// Series-scoped choices that survive closing the player. Set by the
    /// player view before the first start; nil in tests and previews.
    @ObservationIgnored var audioTrackMemory: AudioTrackMemoryStore?
    @ObservationIgnored var subtitleTrackMemory: SubtitleTrackMemoryStore?
    private var selection = TrackSelectionSettings()
    private var missingSubtitleMode: MissingSubtitleMode = .ask
    @ObservationIgnored private let audioSession = PlaybackAudioSession()
    @ObservationIgnored private let nowPlaying = NowPlayingCoordinator()
    @ObservationIgnored private let lifecycleID = UUID()
    @ObservationIgnored private var handoffStartedAt: TimeInterval?
    @ObservationIgnored private var transitionFeedbackTask: Task<Void, Never>?
    @ObservationIgnored private var startHooks = PlaybackStartHooks()

    init() {
        PlaybackLifecycleDiagnostics.controllerCreated(lifecycleID)
        qualityOffer.onAccept = { [weak self] in
            Task { await self?.switchToLowerQuality() }
        }
        #if os(iOS)
        // Not `scenePhase`: under the UIKit-presented player
        // (`PlayerPresentationHub`) it never changes.
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidEnterBackground() }
            },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationWillEnterForeground() }
            },
        ]
        #endif
    }

    deinit {
        PlaybackLifecycleDiagnostics.controllerDestroyed(lifecycleID)
        #if os(iOS)
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    @ObservationIgnored private let performanceSignpostID = OSSignpostID(log: PlaybackPerformance.log)

    /// `startPosition` and `startPaused` are for SyncPlay joins and apply
    /// to this start only.
    func start(
        media: MediaItem,
        startFromBeginning: Bool,
        client: JellyfinClient,
        trackPreferences: TrackPreferenceValues = TrackPreferenceValues(),
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        missingSubtitleMode: MissingSubtitleMode = .ask,
        startPosition: Double? = nil,
        startPaused: Bool = false
    ) async {
        selection = TrackSelectionSettings(
            audioMode: trackPreferences.audioMode,
            subtitleMode: trackPreferences.subtitleMode,
            preferredAudioLanguages: preferredAudioLanguages.isEmpty
                ? Locale.preferredLanguages
                : preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages.isEmpty
                ? SubtitlePreferencesStore.systemCaptionLanguages
                : preferredSubtitleLanguages
        )
        self.missingSubtitleMode = missingSubtitleMode
        await start(
            media: media,
            startFromBeginning: startFromBeginning,
            client: client,
            prepared: nil,
            startPosition: startPosition,
            startPaused: startPaused
        )
    }

    private func start(
        media: MediaItem,
        startFromBeginning: Bool,
        client: JellyfinClient,
        prepared: PlaybackSuccessorPreparation.PreparedPlayback?,
        startPosition: Double? = nil,
        startPaused: Bool = false
    ) async {
        guard !isClosed else { return }
        beginStartSignpost(itemID: media.id)
        defer { endStartSignpost() }
        beginStart(media: media, client: client, startPosition: startPosition, startPaused: startPaused)
        // Checked before a prepared successor, which describes a network stream.
        let download = downloadedSource(for: media)
        isLocalPlayback = download != nil
        // How far the attempt got, for the failure report.
        var startStage: PlaybackFailureDetail.Stage = .negotiate
        do {
            // Fetched alongside negotiation so they don't delay the first
            // frame. Skipped for downloads: an unreachable server would cost
            // the full request timeout before the engine starts.
            async let extras: JellyfinClient.PlaybackExtras = isLocalPlayback
                ? .none
                : await client.playbackExtras(itemId: media.id)
            async let segments: [MediaSegment] = isLocalPlayback
                ? []
                : await client.mediaSegments(itemId: media.id)
            let resolved = if let download {
                download
            } else {
                try await streamedSource(for: media, prepared: prepared, client: client)
            }
            adopt(resolved)
            var startSeconds = beginAttempt(for: media, resolved: resolved, startFromBeginning: startFromBeginning)
            startSeconds = startHooks.pinnedStart(
                startSeconds,
                runtimeTicks: resolved.source.runTimeTicks ?? media.runTimeTicks
            )
            let resolvedExtras = await extras
            let resolvedSegments = await segments
            startSeconds = startHooks.skippableStart(startSeconds, segments: resolvedSegments)
            let info = PlayerItemInfo(
                for: media,
                source: resolved.source,
                client: client,
                extras: resolvedExtras,
                segments: resolvedSegments
            )
            playerInfo = info
            let tracks = startTracks(for: media, resolved: resolved, extras: resolvedExtras, client: client)
            trackPlan = tracks.plan

            configureSystemMediaCallbacks()
            try await waitForPreviousEngineToRetire()
            try audioSession.activate { [weak self] in
                guard let engine = self?.engine else { return false }
                return !engine.isPaused
            }

            let engine = makeEngine(
                for: media, resolved: resolved, startSeconds: startSeconds, tracks: tracks, client: client
            )
            startStage = .start
            install(engine, for: media)
            beginAutomation(segments: info.segments, engine: engine)
            nowPlaying.activate(
                info: info,
                itemID: itemId,
                engine: engine,
                transport: transportActions,
                replacingActiveSession: handoffStartedAt != nil
            )
            configureSubtitleSearch(plan: tracks.plan, engine: engine, client: client)
            lastKnownPosition = startSeconds
            let reporting = beginReporting(for: media, resolved: resolved, client: client)

            try await startHooks.delayStartup()
            try await reportStart(reporting, at: startSeconds)
            try Task.checkCancellation()
            guard self.engine === engine, self.reporting === reporting, reporting.isActive else {
                return
            }
            beginSession(engine: engine, resolved: resolved)
            resolveNextUp(after: media, client: client)
        } catch {
            failStart(error, stage: startStage)
        }
    }

    // MARK: - Start steps

    private func beginStartSignpost(itemID: String) {
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Playback Controller Start",
            signpostID: performanceSignpostID,
            "item=%{public}s",
            itemID
        )
    }

    private func endStartSignpost() {
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Playback Controller Start",
            signpostID: performanceSignpostID
        )
    }

    /// Where an attempt's bytes come from, and what the server said about
    /// them.
    private struct ResolvedSource {
        /// Nil for a download, which plays without asking the server.
        let info: PlaybackInfoResponse?
        let source: MediaSource
        let streamURL: URL
        let method: PlayMethod
        var isDownload = false
        /// A download's own position, which replaces the server's.
        var localResumeTicks: Int64?
        /// A transcoded download is a different file from the source, so its
        /// source streams don't describe it.
        var isTranscodedDownload = false

        /// Empty for a transcoded download. Safe: selection falls back to
        /// what the file demuxes to.
        var trackStreams: [MediaStream] {
            isTranscodedDownload ? [] : (source.mediaStreams ?? [])
        }

        /// Read a disc image directly only when direct play serves the image
        /// itself. Transcodes and downloads are ordinary streams.
        var discRequest: DiscPlaybackRequest? {
            guard !isDownload, method == .directPlay,
                  PlaybackSourceLayout(videoType: source.videoType, isoType: source.isoType).isReadableDisc
            else { return nil }
            return DiscPlaybackRequest(runtimeSeconds: source.runTimeTicks.map(Ticks.seconds))
        }
    }

    /// The tracks an attempt opens with: the plan that selects them, and the
    /// subtitles the engine is handed.
    private struct StartTracks {
        let plan: PlaybackTrackPlan
        let embeddedAudio: [MediaStream]
        let embeddedSubtitles: [MediaStream]
        let externalSubtitles: [ExternalSubtitleTrack]
    }

    /// Per-start state. The start position and paused start are reset every
    /// time, so a failed group start cannot leak its position; a new item
    /// also negotiates from scratch.
    private func beginStart(
        media: MediaItem,
        client: JellyfinClient,
        startPosition: Double?,
        startPaused: Bool
    ) {
        self.client = client
        currentMedia = media
        startPositionOverride = startPosition
        startsPaused = startPaused
        if deliveryItemId != media.id {
            deliveryItemId = media.id
            delivery = startHooks.initialDelivery()
            deliveryFallbacks = []
            skipsLocalPlayback = false
            qualityOfferPolicy = PlaybackQualityOfferPolicy()
        }
        itemId = media.id
    }

    /// A download plays from disk with no server round trip. Always nil on
    /// tvOS, and after a downloaded file has failed.
    private func downloadedSource(for media: MediaItem) -> ResolvedSource? {
        #if os(iOS)
        guard !skipsLocalPlayback, let local = DownloadStore.shared.localPlayback(for: media.id) else {
            return nil
        }
        return ResolvedSource(
            info: nil,
            source: local.source,
            streamURL: local.url,
            method: .directPlay,
            isDownload: true,
            localResumeTicks: local.resumeTicks,
            isTranscodedDownload: local.quality != .original
        )
        #else
        return nil
        #endif
    }

    /// The prepared successor when it is this item, otherwise a fresh
    /// negotiation on the current rung.
    private func streamedSource(
        for media: MediaItem,
        prepared: PlaybackSuccessorPreparation.PreparedPlayback?,
        client: JellyfinClient
    ) async throws -> ResolvedSource {
        if let prepared, prepared.mediaID == media.id {
            return ResolvedSource(
                info: prepared.info,
                source: prepared.source,
                streamURL: prepared.streamURL,
                method: prepared.method
            )
        }
        var negotiated = try await negotiatedSource(for: media, client: client)
        // A disc this rung cannot play steps down before an attempt,
        // whatever the server says. The HUD still records why.
        let layout = PlaybackSourceLayout(
            videoType: negotiated.source.videoType,
            isoType: negotiated.source.isoType
        )
        if delivery == .negotiated, let refusal = layout.directPlayRefusal {
            skipDelivery(to: PlaybackFallbackPolicy.start(for: layout), refusal: refusal)
            negotiated = try await negotiatedSource(for: media, client: client)
        }
        let (streamURL, method) = try client.streamURL(itemId: media.id, source: negotiated.source)
        return ResolvedSource(
            info: negotiated.info,
            source: negotiated.source,
            streamURL: streamURL,
            method: method
        )
    }

    private func negotiatedSource(
        for media: MediaItem,
        client: JellyfinClient
    ) async throws -> (info: PlaybackInfoResponse, source: MediaSource) {
        let info = try await client.playbackInfo(
            itemId: media.id,
            delivery: delivery,
            maxBitrate: qualityCap
        )
        guard info.errorCode == nil, let source = info.mediaSources.first else {
            throw JellyfinError.unplayable
        }
        return (info, source)
    }

    private func adopt(_ resolved: ResolvedSource) {
        mediaSourceId = resolved.source.id
        playMethod = resolved.method
        playingSourceBitrate = resolved.source.bitrate
    }

    /// Resolves where this attempt starts, spends the one-start override,
    /// and opens the attempt's incident record there, at the real resume
    /// position a bench or regression hook may then move.
    private func beginAttempt(
        for media: MediaItem,
        resolved: ResolvedSource,
        startFromBeginning: Bool
    ) -> Double {
        let seconds = Self.resumeStartSeconds(
            fallbackOverrideSeconds: startPositionOverride,
            startFromBeginning: startFromBeginning,
            localResumeTicks: resolved.localResumeTicks,
            serverPositionTicks: media.userData?.playbackPositionTicks
        )
        startPositionOverride = nil
        incidents.beginAttempt(
            delivery: delivery,
            method: resolved.method,
            source: resolved.source,
            cached: SampleBufferPlayerEngine.cachesPlayback(
                url: resolved.streamURL, delivery: resolved.method.delivery
            ),
            disc: resolved.discRequest != nil,
            resumeSeconds: seconds
        )
        return seconds
    }

    private func startTracks(
        for media: MediaItem,
        resolved: ResolvedSource,
        extras: JellyfinClient.PlaybackExtras,
        client: JellyfinClient
    ) -> StartTracks {
        let source = resolved.source
        let streams = resolved.trackStreams
        let embeddedAudio = streams.filter(\.isAudio)
        let allSubtitles = streams.filter(\.isSubtitle)
        let embeddedSubtitles = allSubtitles.filter { $0.isExternal != true }
        // Kept paired: a sidecar whose URL won't resolve is dropped from
        // both lists, or every later ordinal names the wrong track.
        let externalPairs: [(stream: MediaStream, track: ExternalSubtitleTrack)] = allSubtitles
            .filter { $0.isExternal == true }
            .compactMap { stream in
                guard let url = client.externalSubtitleURL(deliveryUrl: stream.deliveryUrl) else { return nil }
                return (stream, ExternalSubtitleTrack(
                    url: url,
                    title: stream.displayTitle,
                    language: stream.language,
                    select: stream.index == source.defaultSubtitleStreamIndex,
                    isForced: stream.isForced == true,
                    isHearingImpaired: stream.isHearingImpaired == true
                ))
            }
        let memoryScope = AudioTrackMemoryStore.scope(seriesID: media.seriesId, itemID: media.id)
        let plan = PlaybackTrackPlan(
            audio: embeddedAudio,
            embeddedSubtitles: embeddedSubtitles,
            externalSubtitles: externalPairs.map(\.stream),
            serverDefaultAudioIndex: source.defaultAudioStreamIndex,
            serverDefaultSubtitleIndex: source.defaultSubtitleStreamIndex,
            settings: selection,
            originalLanguage: extras.originalLanguage ?? media.originalLanguage,
            captionDisplay: Self.systemCaptionDisplay,
            memoryScope: memoryScope,
            carry: trackCarry,
            rememberedAudio: audioTrackMemory?.choice(for: memoryScope),
            rememberedSubtitle: subtitleTrackMemory?.choice(for: memoryScope),
            benchSubtitleLanguage: startHooks.benchSubtitleLanguage
        )
        return StartTracks(
            plan: plan,
            embeddedAudio: embeddedAudio,
            embeddedSubtitles: embeddedSubtitles,
            externalSubtitles: externalPairs.map(\.track)
        )
    }

    /// Never attach a new engine to the display layer while the outgoing
    /// synchronizer still owns it; that stalls the autoplayed episode on
    /// Apple TV.
    private func waitForPreviousEngineToRetire() async throws {
        try checkStartIsWanted()
        let previousResourcesRetired = await PlaybackLifecycleDiagnostics
            .waitForMediaResourcesToRetire(timeout: .seconds(15))
        if !previousResourcesRetired {
            signpostRetirementTimeout(scope: "start")
            throw PlaybackStartError.previousEngineDidNotRetire
        }
        try checkStartIsWanted()
    }

    /// The outgoing engine still holds the display layer, so nothing new may
    /// attach to it: stop and say so.
    private func failRetirement(scope: StaticString) {
        signpostRetirementTimeout(scope: scope)
        beginStop()
        errorMessage = PlaybackStartError.previousEngineDidNotRetire.errorDescription
    }

    private func signpostRetirementTimeout(scope: StaticString) {
        let lifecycle = PlaybackLifecycleDiagnostics.snapshot()
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Playback Resource Retirement Timeout",
            signpostID: performanceSignpostID,
            "scope=%{public}@ demux=%{public}d renderers=%{public}d footprintMB=%{public}.1f",
            String(describing: scope) as NSString,
            lifecycle.activeDemuxLoops,
            lifecycle.attachedRendererSets,
            lifecycle.footprintMB
        )
    }

    private func checkStartIsWanted() throws {
        guard !isClosed else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func makeEngine(
        for media: MediaItem,
        resolved: ResolvedSource,
        startSeconds: Double,
        tracks: StartTracks,
        client: JellyfinClient
    ) -> SampleBufferPlayerEngine {
        let engine = SampleBufferPlayerEngine()
        // Carry the viewer's speed across hand-off and fallback swaps.
        engine.setRate(self.engine?.rate ?? 1)
        if startsPaused {
            // Before priming, so the clock anchors at rate 0 and the
            // member waits on its first frame.
            engine.pause()
        }
        startsPaused = false
        engine.prepare(
            url: resolved.streamURL,
            itemID: media.id,
            delivery: resolved.method.delivery,
            expectedLength: resolved.source.size,
            disc: resolved.discRequest,
            startSeconds: startSeconds,
            initialAudioOrdinal: tracks.plan.initialAudioOrdinal,
            initialSubtitleOrdinal: tracks.plan.initialSubtitleOrdinal,
            audioTrackMetadata: tracks.embeddedAudio.map(Self.trackMetadata),
            embeddedSubtitleMetadata: tracks.embeddedSubtitles.map(Self.trackMetadata),
            externalSubtitles: tracks.externalSubtitles,
            authorization: client.mediaRequestAuthorization()
        )
        engine.setVideoOutputSuspended(videoOutputSuspended)
        engine.setHostInBackground(isInBackground)
        return engine
    }

    /// Makes `engine` the current one. Every callback holds it weakly and
    /// checks it is still current: a retired engine can still report.
    private func install(_ engine: SampleBufferPlayerEngine, for media: MediaItem) {
        engine.onFinished = { [weak self] in self?.playbackDidFinish() }
        engine.onTimeAdvanced = { [weak self] position, duration in
            self?.automation.tick(position: position, duration: duration)
        }
        engine.onSeekReady = { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine else { return }
            self.onEngineReady?()
        }
        observedStallCount = 0
        engine.onBufferingChanged = { [weak self, weak engine] buffering in
            guard let self, let engine, self.engine === engine else { return }
            // A timed skip waits out a stall before seeking.
            self.automation.isBuffering = buffering
            self.onBufferingChanged?(buffering)
            // The engine counts a stall just after it starts buffering.
            if buffering {
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine, self.engine === engine else { return }
                    self.noteStalls(engine.stallCount)
                }
            }
        }
        engine.onPlaybackStarted = { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine else { return }
            self.engineHasStarted = true
            self.finishEpisodeHandoff(outcome: "ready")
            self.incidents.playbackReady(engine: engine)
            #if DEBUG
            self.schedulePlaybackStarvationDiagnostics(for: engine)
            self.scheduleRendererRecoveryRegressionHooks(for: engine)
            self.scheduleDeliveryFallbackRegression(for: engine)
            #endif
        }
        engine.onError = { [weak self, weak engine] failure in
            guard let self, let engine, self.engine === engine else { return }
            self.handleEngineError(failure, engine: engine)
        }
        engine.onTrackSelectionChanged = { [weak self, weak engine] in
            self?.nowPlaying.updateLanguageOptions()
            // Identity-guarded: a shut-down engine keeps reporting the
            // track it had, and this writes durable state.
            if let self, let engine, self.engine === engine {
                self.recordTrackChoices(engine: engine)
            }
            if let language = engine?.subtitleTracks.first(where: \.isSelected)?.languageTag,
               let normalized = SubtitlePreferencesStore.normalizedLanguage(language) {
                // Apple's caption contract: feed explicit choices back
                // to the system caption-language preferences.
                _ = MACaptionAppearanceAddSelectedLanguage(.user, normalized as CFString)
            }
        }
        playbackIdentity = media.id
        engineHasStarted = false
        self.engine = engine
    }

    private func beginAutomation(segments: [MediaSegment], engine: SampleBufferPlayerEngine) {
        automation.beginItem(segments: segments)
        // Seeded: the callback only reports changes.
        automation.isBuffering = engine.isBuffering
        // Through the controller, so a skip in a group is a group seek.
        automation.onSkip = { [weak self] segment in self?.userSeek(to: segment.end) }
        automation.onPlayNext = { [weak self] in
            guard let self, !self.isClosed, !self.isAdvancing else { return }
            // In a group the server starts the next item for everyone.
            if let groupTransport = self.groupTransport {
                groupTransport.requestNextItem()
                return
            }
            self.isAutoplayPending = true
            Task { await self.playNextEpisode() }
        }
    }

    private func configureSubtitleSearch(
        plan: PlaybackTrackPlan,
        engine: SampleBufferPlayerEngine,
        client: JellyfinClient
    ) {
        let preferredSet = Set(selection.preferredSubtitleLanguages.compactMap(
            SubtitlePreferencesStore.normalizedLanguage
        ))
        let hasSuitableLocalTrack = plan.subtitleStreams.contains {
            guard let language = $0.language.flatMap(SubtitlePreferencesStore.normalizedLanguage) else {
                return false
            }
            return preferredSet.contains(language)
        }
        subtitleSearch.configure(
            client: client,
            engine: engine,
            itemID: itemId,
            mediaSourceID: mediaSourceId,
            streams: plan.subtitleStreams,
            preferredLanguages: selection.preferredSubtitleLanguages,
            missingMode: missingSubtitleMode,
            hasSuitableLocalTrack: hasSuitableLocalTrack
        ) { [weak self] stream in
            self?.trackPlan?.appendSearchedSubtitle(stream)
            self?.nowPlaying.updateLanguageOptions()
        }
    }

    private func beginReporting(
        for media: MediaItem,
        resolved: ResolvedSource,
        client: JellyfinClient
    ) -> PlaybackReportingSession {
        let reporting = PlaybackReportingSession(
            client: client,
            itemID: itemId,
            mediaSourceID: mediaSourceId,
            playSessionID: resolved.info?.playSessionId,
            method: resolved.method,
            signpostID: performanceSignpostID,
            runtimeTicks: resolved.source.runTimeTicks ?? media.runTimeTicks
        )
        self.reporting = reporting
        return reporting
    }

    /// A reporting failure never interrupts playback. Cancellation does: the
    /// player was dismissed mid-request, and nothing may be recreated after
    /// teardown.
    private func reportStart(_ reporting: PlaybackReportingSession, at seconds: Double) async throws {
        if isLocalPlayback {
            // Not awaited: an unreachable server would stall local
            // playback for the full request timeout. Failures are dropped.
            Task {
                try? await reporting.reportStart(at: seconds)
            }
            return
        }
        do {
            try await reporting.reportStart(at: seconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Reporting failure must not interrupt playback.
        }
    }

    /// The engine is current and the server knows: start the progress loop
    /// and the diagnostics that run for the session.
    private func beginSession(engine: SampleBufferPlayerEngine, resolved: ResolvedSource) {
        startProgressLoop()
        diagnosticSampler.cacheMetrics = { [weak self] in self?.engine?.playbackCacheMetrics }
        diagnosticSampler.startTrace(engine: engine) { [weak self] in
            self?.soakExitRequested = true
            self?.soakExitRequestedAt = ContinuousClock.now
        }
        diagnosticSampler.startHUD(
            source: resolved.source, method: resolved.method, engine: engine,
            context: { [weak self] in
                guard let self else { return nil }
                return .init(
                    cache: self.engine?.playbackCacheMetrics,
                    handoffMilliseconds: self.lastHandoffMilliseconds,
                    fallbackLines: self.deliveryFallbackHUDLines
                        + (self.groupHUDLines?() ?? [])
                )
            },
            publish: { [weak self] in self?.hudLines = $0 }
        )
    }

    private func failStart(_ error: Error, stage: PlaybackFailureDetail.Stage) {
        // `beginStop` also claims the exactly-once stop report.
        let cancelled = Self.isStartCancellation(error, taskCancelled: Task.isCancelled, closed: isClosed)
        finishEpisodeHandoff(outcome: cancelled ? "cancelled" : "failed")
        if !cancelled {
            incidents.startFailed(error, delivery: delivery, stage: stage)
        }
        _ = beginStop()
        if !cancelled {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Whether a start error is the viewer leaving rather than a failure.
    /// A cancelled URLSession request surfaces as `URLError.cancelled`, not
    /// `CancellationError`. It counts only when the task or controller was
    /// really cancelled, so a transport teardown still reports.
    nonisolated static func isStartCancellation(_ error: Error, taskCancelled: Bool, closed: Bool) -> Bool {
        if error is CancellationError { return true }
        guard let urlError = error as? URLError, urlError.code == .cancelled else { return false }
        return taskCancelled || closed
    }

    /// Which resume position wins when a title starts.
    ///
    /// An override (a fallback retry or a SyncPlay position) wins even over
    /// "start from the beginning". Otherwise a download's local position
    /// replaces the server's.
    nonisolated static func resumeStartSeconds(
        fallbackOverrideSeconds: Double?,
        startFromBeginning: Bool,
        localResumeTicks: Int64?,
        serverPositionTicks: Int64?
    ) -> Double {
        if let fallbackOverrideSeconds {
            return fallbackOverrideSeconds
        }
        if !startFromBeginning, let localResumeTicks {
            return Ticks.seconds(localResumeTicks)
        }
        if !startFromBeginning, let serverPositionTicks, serverPositionTicks > 0 {
            return Ticks.seconds(serverPositionTicks)
        }
        return 0
    }

    private nonisolated static func trackMetadata(_ stream: MediaStream) -> PlayerTrackMetadata {
        PlayerTrackMetadata(
            languageTag: stream.language,
            isForced: stream.isForced == true,
            isHearingImpaired: stream.isHearingImpaired == true
        )
    }

    func recordPlayerSurface(identity: String) {
        if playerSurfaceIdentity != identity {
            playerSurfaceIdentity = identity
        }
    }

    /// Records a choice the viewer just made, or drops the override it
    /// replaces.
    ///
    /// The selection callback fires only for deliberate choices, not
    /// automatic selection. Recorded now, not at exit, because by exit the
    /// item, layout or engine may belong to the next episode.
    private func recordTrackChoices(engine: SampleBufferPlayerEngine) {
        guard let plan = trackPlan else { return }
        if let audioTrackMemory,
           let selected = engine.audioTracks.first(where: \.isSelected),
           let update = plan.audioMemoryUpdate(
               selected: selected.engineID,
               engineTrackCount: engine.audioTracks.count
           ) {
            switch update {
            case .remember(let choice): audioTrackMemory.remember(choice, for: plan.memoryScope)
            case .forget: audioTrackMemory.forget(plan.memoryScope)
            }
        }
        if let subtitleTrackMemory,
           let update = plan.subtitleMemoryUpdate(
               selected: engine.subtitleTracks.first(where: \.isSelected)?.engineID,
               engineTrackCount: engine.subtitleTracks.count
           ) {
            switch update {
            case .remember(let choice): subtitleTrackMemory.remember(choice, for: plan.memoryScope)
            case .forget: subtitleTrackMemory.forget(plan.memoryScope)
            }
        }
    }

    /// The device's caption setting. Closed captioning turned on in
    /// Accessibility means always on, whatever the caption style says.
    private static var systemCaptionDisplay: SystemCaptionDisplay {
        if UIAccessibility.isClosedCaptioningEnabled { return .alwaysOn }
        switch MACaptionAppearanceGetDisplayType(.user) {
        case .forcedOnly: return .forcedOnly
        case .automatic: return .automatic
        case .alwaysOn: return .alwaysOn
        @unknown default: return .unrecognized
        }
    }

    private func configureSystemMediaCallbacks() {
        audioSession.onPauseRequested = { [weak self] in
            self?.engine?.pause()
            self?.nowPlaying.updateTimeline()
        }
        audioSession.onResumeRequested = { [weak self] in
            self?.engine?.play()
            self?.nowPlaying.updateTimeline()
        }
        audioSession.onMediaServicesReset = { [weak self] in
            self?.engine?.recoverAfterMediaServicesReset()
            self?.nowPlaying.updateTimeline()
        }
        audioSession.onRouteAvailabilityChanged = { [weak self] active in
            guard let self else { return }
            self.isExternalPlaybackRouteActive = active
            #if os(iOS)
            self.pictureRouteDidChange()
            #endif
        }
        audioSession.onError = { [weak self] error in
            guard let self, self.engine != nil else { return }
            self.engine?.pause()
            self.errorMessage = error.localizedDescription
            self.nowPlaying.updateTimeline()
        }
    }

    #if DEBUG
    /// Debug hook: injects bounded outages, so hardware can run the same
    /// cases as the simulator regression suite.
    private func schedulePlaybackStarvationDiagnostics(for engine: SampleBufferPlayerEngine) {
        let defaults = UserDefaults.standard
        let requestedDelay = defaults.double(forKey: "debug.starvationInjectionDelaySeconds")
        let requestedDuration = defaults.double(forKey: "debug.starvationInjectionDurationSeconds")
        let delay = requestedDelay > 0 ? requestedDelay : 5
        let duration = requestedDuration > 0 ? requestedDuration : 3

        if defaults.bool(forKey: "debug.simulateAudioStarvation") {
            Task { [weak self, weak engine] in
                try? await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
                guard let self, let engine, self.engine === engine else { return }
                engine.simulateAudioStarvationForDiagnostics(durationSeconds: duration)
            }
        }
        if defaults.bool(forKey: "debug.simulateDeliveryStall") {
            Task { [weak self, weak engine] in
                try? await Task.sleep(for: .milliseconds(Int64(delay * 1_000)))
                guard let self, let engine, self.engine === engine else { return }
                engine.simulateDeliveryStallForDiagnostics(durationSeconds: duration)
            }
        }
    }
    #endif

    #if DEBUG
    /// Injects renderer events the simulator cannot cause with a real
    /// HDMI or audio route change.
    private func scheduleRendererRecoveryRegressionHooks(for engine: SampleBufferPlayerEngine) {
        if UserDefaults.standard.bool(forKey: "debug.regressionInjectAudioRendererFlush") {
            Task { [weak self, weak engine] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let engine, self.engine === engine else { return }
                engine.simulateAudioRendererFlushForRegression()
            }
        }
        if UserDefaults.standard.bool(forKey: "debug.regressionInjectMediaServicesReset") {
            Task { [weak self, weak engine] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, let engine, self.engine === engine else { return }
                self.audioSession.simulateMediaServicesResetForRegression()
            }
        }
    }
    #endif

    /// Looks up what plays next, after the engine is running, so the round
    /// trip cannot delay the first frame.
    private func resolveNextUp(after media: MediaItem, client: JellyfinClient) {
        nextUpTask?.cancel()
        successorPreparation.cancel()
        nextUp = nil
        guard media.type == .episode else { return }
        nextUpTask = Task { [weak self] in
            let next = try? await client.episodeAfter(media)
            guard !Task.isCancelled else { return }
            self?.nextUp = next
        }
    }

    /// Negotiates and warms the successor in the last two minutes of an
    /// episode.
    private func prepareNextIfNeeded(force: Bool = false) {
        guard !successorPreparation.hasPreparation,
              let next = nextUp, let client else { return }
        if !force {
            guard let engine, engine.duration > 0,
                  engine.duration - engine.timePosition <= 120 else { return }
        }
        // Staging suspends the current fill; cached bytes stay readable.
        successorPreparation.prepare(
            itemID: next.id,
            client: client,
            staging: successorStaging,
            warms: !isAdvancing
        )
    }

    /// Staging closures. They hold no engine: each reaches the current one
    /// through the controller, so a completed hand-off stages on the new one.
    private var successorStaging: PlaybackSuccessorPreparation.Staging {
        .init(
            stage: { [weak self] prepared, warms in
                guard let self, let client = self.client else { return }
                self.engine?.stageSuccessor(
                    itemID: prepared.mediaID,
                    url: prepared.streamURL,
                    delivery: prepared.method.delivery,
                    expectedLength: prepared.source.size,
                    authorization: client.mediaRequestAuthorization(),
                    warms: warms
                )
            },
            endWarming: { [weak self] in self?.engine?.endSuccessorWarming() },
            discard: { [weak self] itemID in
                self?.engine?.discardStagedSuccessor(itemID: itemID)
            }
        )
    }

    /// Roll into the queued episode without leaving the player.
    ///
    /// The finished episode's stop report must land before the next one
    /// starts, or Jellyfin leaves it unresolved instead of marking it played.
    func playNextEpisode() async {
        defer { isAutoplayPending = false }
        guard !isAdvancing, let next = nextUp, client != nil else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        beginEpisodeHandoff(to: next)
        prepareNextIfNeeded(force: true)
        let prepared = await successorPreparation.preparedForHandoff()
        guard !isClosed else { return }
        captureTrackCarry()
        await restart(next, scope: "handoff", prepared: prepared, preservingPreparedNext: true)
    }

    /// Replaces the engine on the same surface: stop, wait for the outgoing
    /// engine to release the display layer, then start. The one path for an
    /// episode hand-off, a group item change and a delivery fallback.
    ///
    /// The new item resumes from its own position unless `startPosition`
    /// says otherwise. `isStillWanted` is checked after the stop, when the
    /// caller's reason to restart may have gone.
    private func restart(
        _ media: MediaItem,
        scope: StaticString,
        prepared: PlaybackSuccessorPreparation.PreparedPlayback? = nil,
        preservingPreparedNext: Bool,
        delivery rung: PlaybackDelivery? = nil,
        startPosition: Double? = nil,
        startPaused: Bool = false,
        isStillWanted: () -> Bool = { true }
    ) async {
        guard let client else { return }
        // Keep the display layer mounted. Destroying it leaves the old
        // renderer registered as attached, and the retirement wait times out
        // every time.
        let retired = await stop(
            preservingPreparedNext: preservingPreparedNext,
            preservingPlayerSurface: true
        )
        guard !isClosed else { return }
        guard retired else {
            failRetirement(scope: scope)
            return
        }
        guard !Task.isCancelled, isStillWanted() else { return }
        // Don't let the old card reappear over a successor resumed near its end.
        nextUp = nil
        didFinish = false
        errorMessage = nil
        if let rung { delivery = rung }
        await start(
            media: media,
            startFromBeginning: false,
            client: client,
            prepared: prepared,
            startPosition: startPosition,
            startPaused: startPaused
        )
    }

    /// Reads the live selection back off the engine before it is torn down.
    private func captureTrackCarry() {
        guard let engine, let trackPlan else { return }
        trackCarry = trackPlan.carry(
            selectedAudio: engine.audioTracks.first(where: \.isSelected)?.engineID,
            selectedSubtitle: engine.subtitleTracks.first(where: \.isSelected)?.engineID
        )
    }

    /// Stop filling ahead without discarding what is cached.
    func suspendBufferFill() {
        engine?.suspendBufferFill()
    }

    /// The file ran out. Races a running countdown; whichever arrives first
    /// wins, and `playNextEpisode` guards against both. Decided here, not in
    /// the view, so a locked phone rolls on too.
    private func playbackDidFinish() {
        didFinish = true
        // In a group, always ask the server for the next entry, whatever
        // the local successor or autoplay setting.
        if let groupTransport {
            groupTransport.requestNextItem()
            return
        }
        guard automation.autoplaysOnFinish, nextUp != nil, !isAdvancing else { return }
        automation.playNext()
    }

    /// The app is away and neither picture in picture nor AirPlay shows the
    /// picture, so decoding it is wasted and its session may be taken.
    nonisolated static func videoIsUnseen(inBackground: Bool, pictureInPicture: Bool, airPlay: Bool) -> Bool {
        inBackground && !pictureInPicture && !airPlay
    }

    #if os(iOS)
    /// Locked or backgrounded: audio carries on, cache fill stops, and the
    /// picture is dropped unless PiP or AirPlay still shows it.
    private func applicationDidEnterBackground() {
        guard !isClosed, engine != nil else { return }
        isInBackground = true
        engine?.setHostInBackground(true)
        suspendBufferFill()
        suspendVideoIfUnseen()
        publishDisplayState()
    }

    /// Back on screen: the picture restarts from the playhead.
    private func applicationWillEnterForeground() {
        guard !isClosed else { return }
        isInBackground = false
        videoOutputSuspended = false
        engine?.setHostInBackground(false)
        engine?.setVideoOutputSuspended(false)
        resumeBufferFill()
        publishDisplayState()
    }

    /// Picture in picture started or stopped, or the AirPlay route changed.
    /// Stopping either while the app is away leaves nothing to show the
    /// picture, so video is suspended as backgrounding would have.
    func pictureRouteDidChange() {
        guard !isClosed, engine != nil else { return }
        suspendVideoIfUnseen()
        publishDisplayState()
    }

    private func suspendVideoIfUnseen() {
        guard !videoOutputSuspended,
              Self.videoIsUnseen(
                  inBackground: isInBackground,
                  pictureInPicture: isPictureInPictureShowing(),
                  airPlay: isExternalPlaybackRouteActive
              ) else { return }
        videoOutputSuspended = true
        engine?.setVideoOutputSuspended(true)
    }

    private func publishDisplayState() {
        incidents.setDisplayState(
            background: isInBackground,
            pictureInPicture: isPictureInPictureShowing(),
            airPlay: isExternalPlaybackRouteActive,
            videoSuspended: videoOutputSuspended
        )
    }
    #endif

    // MARK: - Group playback

    /// Swaps the item in one player session when the group moves on. Same
    /// stop-then-start as `playNextEpisode`, so the video surface survives,
    /// without the successor warm-up.
    func startGroupItem(_ media: MediaItem, startPosition: Double) async {
        guard !isAdvancing, !isClosed, client != nil else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        await restart(
            media,
            scope: "group",
            preservingPreparedNext: false,
            startPosition: startPosition,
            startPaused: true,
            isStillWanted: { groupTransport != nil }
        )
    }

    // MARK: - The viewer's transport
    //
    // Every viewer control comes through here, so one `groupTransport` check
    // hands the transport to a SyncPlay group. Tracks, audio delay and speed
    // stay local.

    func userPlay() {
        guard let groupTransport else {
            engine?.play()
            return
        }
        groupTransport.requestPlay()
    }

    func userPause() {
        guard let groupTransport else {
            engine?.pause()
            return
        }
        groupTransport.requestPause()
    }

    func userTogglePause() {
        guard let groupTransport else {
            engine?.togglePause()
            return
        }
        if engine?.isPaused ?? true {
            groupTransport.requestPlay()
        } else {
            groupTransport.requestPause()
        }
    }

    /// `resume` means seek and then play (the tvOS scrub commit).
    func userSeek(to seconds: Double, resume: Bool = false) {
        guard let groupTransport else {
            // Resume before seeking: the seek re-anchors the synchronizer
            // when it primes, and unpausing afterwards fights that.
            if resume, engine?.isPaused == true { engine?.play() }
            engine?.seek(to: seconds)
            return
        }
        groupTransport.requestSeek(to: seconds, resume: resume)
    }

    func userSeek(by seconds: Double) {
        guard let groupTransport else {
            engine?.seek(by: seconds)
            return
        }
        guard let engine else { return }
        groupTransport.requestSeek(to: max(engine.timePosition + seconds, 0), resume: false)
    }

    var transportActions: PlayerTransportActions {
        PlayerTransportActions(
            play: { [weak self] in self?.userPlay() },
            pause: { [weak self] in self?.userPause() },
            togglePause: { [weak self] in self?.userTogglePause() },
            seek: { [weak self] seconds, resume in self?.userSeek(to: seconds, resume: resume) },
            seekBy: { [weak self] seconds in self?.userSeek(by: seconds) }
        )
    }

    func resumeBufferFill() {
        // A successor under negotiation is about to take the link for its
        // warm-up; the engine only refuses once warm-up has started.
        guard !successorPreparation.isPreparing else { return }
        engine?.resumeBufferFill()
    }

    func updateNowPlayingTimeline() {
        nowPlaying.updateTimeline()
    }

    private var currentPosition: Double {
        Self.reportablePosition(
            engine: engine?.timePosition,
            engineHasStarted: engineHasStarted,
            lastKnown: lastKnownPosition
        )
    }

    /// Where playback is, for reports and restarts. The start point stands
    /// until the engine has presented it, so a failure before the first
    /// frame never reports or restarts from 0.
    nonisolated static func reportablePosition(
        engine: Double?,
        engineHasStarted: Bool,
        lastKnown: Double
    ) -> Double {
        guard let engine, engineHasStarted else { return lastKnown }
        return engine
    }

    private func startProgressLoop() {
        reporting?.startProgress(snapshot: { [weak self] in
            guard let self, let engine = self.engine else { return nil }
            self.lastKnownPosition = self.currentPosition
            self.nowPlaying.updateTimeline()
            return .init(seconds: self.lastKnownPosition, isPaused: engine.isPaused)
        }, didReport: { [weak self] in
            self?.prepareNextIfNeeded()
        })
    }

    /// Releases every resource synchronously on the main actor. The stop
    /// report is returned as a separate task, so network latency never
    /// holds up dismissal or retains this controller.
    @discardableResult
    func beginStop(
        preservingPreparedNext: Bool = false,
        preservingPlayerSurface: Bool = false
    ) -> Task<Void, Never>? {
        reporting?.cancelProgress()
        diagnosticSampler.stop()
        nextUpTask?.cancel()
        nextUpTask = nil
        // A sleeping countdown must not wake on a gone engine.
        automation.invalidate()
        qualityOffer.withdraw()
        if !preservingPreparedNext {
            successorPreparation.cancel()
        }
        subtitleSearch.detach()
        let seconds = currentPosition
        lastKnownPosition = seconds
        incidents.endAttempt(engine: engine, outcome: stopOutcome)

        // Keep this main-actor phase tiny; the engine does renderer flushing
        // and buffer release on its pump queue.
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Dismiss Main Actor Cleanup",
            signpostID: performanceSignpostID
        )
        if let engine {
            engine.onFinished = nil
            engine.onTimeAdvanced = nil
            engine.onError = nil
            engine.onTrackSelectionChanged = nil
            engine.onPlaybackStarted = nil
            engine.onSeekReady = nil
            engine.onBufferingChanged = nil
            engine.shutdown()
            // A hand-off keeps the staged successor for the next engine.
            engine.discardPlaybackCache(preservingStagedSuccessor: preservingPreparedNext)
            if !preservingPlayerSurface {
                self.engine = nil
            }
        }
        if !preservingPlayerSurface {
            finishEpisodeHandoff(outcome: "cancelled")
            nowPlaying.stop()
            audioSession.deactivate()
        }
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Dismiss Main Actor Cleanup",
            signpostID: performanceSignpostID
        )

        let report = reporting?.stop(at: seconds)
        reporting = nil
        return report
    }

    /// Final dismissal. Unlike the hand-off stop, it stops any suspended
    /// task from reviving an engine after the player has gone.
    @discardableResult
    func close() -> Task<Void, Never>? {
        isClosed = true
        // After teardown, so a group driver leaves a controller with no engine.
        defer { onClosed?() }
        guard let soakExitRequestedAt else { return beginStop() }
        // Soak only (the hook is gated). `closeMs` is `beginStop()` alone;
        // `sinceRequestMs` is the whole exit since the request.
        let closeStart = ContinuousClock.now
        let result = beginStop()
        let closeMs = ms(ContinuousClock.now - closeStart)
        let sinceRequestMs = ms(ContinuousClock.now - soakExitRequestedAt)
        print(String(format: "SoakExit closeMs=%.1f sinceRequestMs=%.1f", closeMs, sinceRequestMs))
        return result
    }

    private func stop(
        preservingPreparedNext: Bool,
        preservingPlayerSurface: Bool
    ) async -> Bool {
        let outgoingEngine = engine
        let report = beginStop(
            preservingPreparedNext: preservingPreparedNext,
            preservingPlayerSurface: preservingPlayerSurface
        )
        // Await report and retirement in parallel, so a slow server does not
        // add to retirement, while keeping report-before-start.
        let retirement = Task {
            guard let outgoingEngine else { return true }
            return await outgoingEngine.waitForMediaResourcesToRetire()
        }
        await report?.value
        return await retirement.value
    }

    private func handleEngineError(_ failure: PlaybackEngineFailure, engine: SampleBufferPlayerEngine) {
        lastKnownPosition = currentPosition
        let canFallBack = !isClosed && !isFallingBack && currentMedia != nil && client != nil
        let next = canFallBack ? PlaybackFallbackPolicy.next(after: delivery, cause: failure.cause) : nil
        incidents.engineFailed(failure, delivery: delivery, next: next, engine: engine)
        if let next {
            isFallingBack = true
            #if os(iOS)
            if isLocalPlayback {
                // Retry from the server, not the same file. The download is
                // kept: one failure is not proof the file is bad.
                skipsLocalPlayback = true
                DownloadStore.log.error(
                    "Downloaded file failed to play, falling back to the server: \(self.itemId, privacy: .public)"
                )
            }
            #endif
            // Anything this engine reports now belongs to a dying session.
            engine.onError = nil
            Task { await self.fallBack(to: next, after: failure) }
            return
        }
        finishEpisodeHandoff(outcome: "failed")
        incidents.endAttempt(engine: engine, outcome: "failed")
        let report = beginStop()
        errorMessage = failure.message
        // beginStop claims the report, so a later onDisappear stays idempotent.
        _ = report
    }

    #if DEBUG
    /// Fails the first negotiated attempt so the ladder can be tested
    /// without a broken file.
    ///
    /// `debug.regressionFailFirstDelivery` is `delivery` (expect remux) or
    /// `undecodable` (expect transcode, remux skipped). Injected after
    /// playback starts so the retry has a position to resume from.
    private func scheduleDeliveryFallbackRegression(for engine: SampleBufferPlayerEngine) {
        guard let injected = UserDefaults.standard.string(
            forKey: "debug.regressionFailFirstDelivery"
        ), delivery == .negotiated else { return }
        let cause: PlaybackEngineFailure.Cause = injected == "undecodable" ? .undecodable : .delivery
        Task { [weak self, weak engine] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let engine, self.engine === engine else { return }
            self.handleEngineError(
                PlaybackEngineFailure(
                    cause: cause,
                    message: "Injected \(injected) failure (regression hook)."
                ),
                engine: engine
            )
        }
    }
    #endif

    /// Records a rung skipped before any attempt, for the HUD. Not
    /// `fallBack`: there is no engine to retire or position to resume.
    private func skipDelivery(
        to next: PlaybackDelivery,
        refusal: (cause: String, message: String)
    ) {
        deliveryFallbacks.append(PlaybackDeliveryFallbackRecord(
            transition: "\(delivery.rawValue)→\(next.rawValue) · \(refusal.cause)",
            message: refusal.message
        ))
        delivery = next
    }

    /// Retries the same media on the next rung, from where it failed.
    ///
    /// `next` only moves down, so a stream that fails every way still ends
    /// in the error overlay.
    private func fallBack(to next: PlaybackDelivery, after failure: PlaybackEngineFailure) async {
        // Held across the restart: a failure while the next attempt starts
        // takes the terminal path instead of tearing down a starting engine.
        defer { isFallingBack = false }
        guard !isClosed, client != nil, let media = currentMedia else { return }
        let resumeAt = currentPosition
        // Tell the group now: the replacement buffers before its callbacks
        // are wired, and its Ready must read as a new state.
        onBufferingChanged?(true)
        let cause = failure.cause == .undecodable ? "undecodable" : "delivery"
        os_signpost(
            .event,
            log: PlaybackPerformance.log,
            name: "Playback Delivery Fallback",
            signpostID: performanceSignpostID,
            "from=%{public}s to=%{public}s cause=%{public}s position=%{public}.3f",
            delivery.rawValue,
            next.rawValue,
            cause,
            resumeAt
        )
        deliveryFallbacks.append(PlaybackDeliveryFallbackRecord(
            transition: "\(delivery.rawValue)→\(next.rawValue) · \(cause)",
            message: failure.message
        ))
        await restart(
            media,
            scope: "fallback",
            preservingPreparedNext: true,
            delivery: next,
            startPosition: resumeAt,
            // In a group, prime and report Ready; the server starts playback.
            startPaused: groupTransport != nil
        )
    }

    // MARK: - Lower quality after stalls

    /// Offers a lower quality once repeated stalls show the link cannot keep
    /// up. Not for a download, which has no link, nor in a group, where a
    /// restart is the group's to make.
    private func noteStalls(_ count: Int) {
        guard count > observedStallCount else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var offers = false
        for _ in observedStallCount..<count {
            offers = qualityOfferPolicy.recordStall(at: now) || offers
        }
        observedStallCount = count
        guard offers, !isClosed, !isLocalPlayback, groupTransport == nil else { return }
        qualityOffer.present()
    }

    /// Re-negotiates under a lower ceiling and resumes at the playhead, on
    /// the same rung. The viewer asked for it, so it is not a fallback.
    private func switchToLowerQuality() async {
        guard !isClosed, !isFallingBack, !isChangingQuality, groupTransport == nil,
              let client, let media = currentMedia else { return }
        isChangingQuality = true
        defer { isChangingQuality = false }
        let link = engine?.bufferState.networkBytesPerSecond.map { Int($0 * 8) }
        let currentCap: Int?
        if let qualityCap {
            currentCap = qualityCap
        } else {
            currentCap = await client.connectionBitrateCeiling()
        }
        let cap = PlaybackQualityLimit.loweredBitrate(
            linkBitsPerSecond: link,
            playingBitrate: playingSourceBitrate,
            currentCap: currentCap
        )
        qualityCap = cap
        deliveryFallbacks.append(PlaybackDeliveryFallbackRecord(
            transition: "\(delivery.rawValue) · max " + String(format: "%.1f Mbps", Double(cap) / 1_000_000),
            message: "Lower quality chosen after repeated stalls."
        ))
        captureTrackCarry()
        await restart(
            media,
            scope: "quality",
            preservingPreparedNext: true,
            startPosition: currentPosition
        )
    }

    /// The attempt's end, as the diagnostics history names it.
    private var stopOutcome: String {
        if errorMessage != nil { return "failed" }
        if didFinish { return "finished" }
        if handoffStartedAt != nil { return "handoff" }
        if isFallingBack { return "fallback" }
        if isChangingQuality { return "quality" }
        return "stopped"
    }

    private func beginEpisodeHandoff(to next: MediaItem) {
        guard handoffStartedAt == nil else { return }
        incidents.handoffBegan()
        lastHandoffMilliseconds = nil
        isTransitionOverlayVisible = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        handoffStartedAt = startedAt
        transitionFeedbackTask?.cancel()
        transitionFeedbackTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.25))
            } catch {
                return
            }
            guard let self, self.handoffStartedAt == startedAt else { return }
            self.isTransitionOverlayVisible = true
        }
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Episode Handoff",
            signpostID: performanceSignpostID,
            "from=%{public}s to=%{public}s",
            itemId,
            next.id
        )
    }

    private func finishEpisodeHandoff(outcome: String) {
        transitionFeedbackTask?.cancel()
        transitionFeedbackTask = nil
        isTransitionOverlayVisible = false
        guard let startedAt = handoffStartedAt else { return }
        handoffStartedAt = nil
        let milliseconds = max(ProcessInfo.processInfo.systemUptime - startedAt, 0) * 1_000
        if outcome == "ready" {
            lastHandoffMilliseconds = milliseconds
        }
        incidents.handoffFinished(outcome: outcome, milliseconds: milliseconds)
        os_signpost(
            .end,
            log: PlaybackPerformance.log,
            name: "Episode Handoff",
            signpostID: performanceSignpostID,
            "outcome=%{public}s durationMs=%{public}.0f",
            outcome,
            milliseconds
        )
    }

    /// Why this rung is in force; empty when the ladder never ran.
    private var deliveryFallbackHUDLines: [String] {
        guard !deliveryFallbacks.isEmpty else { return [] }
        var lines = ["Rung:    \(delivery.rawValue)"]
        for (index, fallback) in deliveryFallbacks.enumerated() {
            lines.append("Fell \(index + 1):  \(fallback.transition)")
            lines.append("Why \(index + 1):   \(fallback.message)")
        }
        return lines
    }

}
