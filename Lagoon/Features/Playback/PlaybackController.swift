import LagoonEngine
import CoreMedia
import MediaAccessibility
import Observation
import OSLog
import SwiftUI
import UIKit

nonisolated enum PlaybackStartError: LocalizedError {
    case previousEngineDidNotRetire

    var errorDescription: String? {
        switch self {
        case .previousEngineDidNotRetire:
            "The previous video could not release its player resources. Close the player and try again."
        }
    }
}

/// Transport requests routed to a SyncPlay group instead of the local engine.
///
/// A request does nothing locally: the group's answering command is what
/// moves this player.
@MainActor
protocol GroupTransportRequests: AnyObject {
    func requestPlay()
    func requestPause()
    /// `resume` means seek and then play, so the implementation can order
    /// the two requests.
    func requestSeek(to seconds: Double, resume: Bool)
    func requestNextItem()
}

/// The transport actions the player chrome can request.
///
/// Closures rather than a controller reference keep the engine out of
/// anything SwiftUI retains.
struct PlayerTransportActions {
    /// Idempotent: system integrations state the wanted state, not a toggle.
    let play: () -> Void
    let pause: () -> Void
    let togglePause: () -> Void
    let seek: (_ seconds: Double, _ resume: Bool) -> Void
    let seekBy: (_ seconds: Double) -> Void
}

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
    /// Set before the autoplay hand-off runs, so the view's end-of-file
    /// handling does not close the player underneath it.
    private(set) var isAutoplayPending = false
    /// iOS background with the picture off: every engine, including an
    /// autoplay successor, plays audio only until the app returns.
    private var videoOutputSuspended = false
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
    private var resumeOverride: Double?
    /// A caller's start position (a SyncPlay join), outranking every resume
    /// rule for one start. Not `resumeOverride`, which the new-item reset
    /// clears, and a group join is exactly when the item is new.
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
    private var trackPreference: TrackPreference?
    /// Series-scoped audio choice that survives closing the player. Set by
    /// the player view before the first start; nil in tests and previews.
    @ObservationIgnored var audioTrackMemory: AudioTrackMemoryStore?
    /// The show or film the current item is remembered under.
    @ObservationIgnored private var audioMemoryScope: String?
    /// The layout the scope was resolved against. Held, not re-read at exit,
    /// so a start that fails partway cannot pair a new scope with old streams.
    @ObservationIgnored private var audioMemoryLayout: [AudioLayoutStream] = []
    /// What automatic selection chose, so the exit can tell an override
    /// from an untouched default.
    @ObservationIgnored private var policyAudioOrdinal: Int?
    /// The same three for subtitles, kept separate because one can be lost
    /// while the other is kept.
    @ObservationIgnored var subtitleTrackMemory: SubtitleTrackMemoryStore?
    @ObservationIgnored private var subtitleMemoryScope: String?
    @ObservationIgnored private var subtitleMemoryLayout: [SubtitleLayoutStream] = []
    @ObservationIgnored private var policySubtitleOrdinal: Int?
    /// Streams in engine order: audio is the embedded list; subtitles are
    /// embedded first, then external.
    private var audioStreams: [MediaStream] = []
    private var orderedSubtitleStreams: [MediaStream] = []
    private var preferredAudioLanguages: [String] = []
    private var preferredSubtitleLanguages: [String] = []
    private var audioDefaultMode: AudioDefaultMode = .serverDefault
    private var subtitleDefaultMode: SubtitleDefaultMode = .system
    private var missingSubtitleMode: MissingSubtitleMode = .ask
    @ObservationIgnored private let audioSession = PlaybackAudioSession()
    @ObservationIgnored private let nowPlaying = NowPlayingCoordinator()
    @ObservationIgnored private let lifecycleID = UUID()
    @ObservationIgnored private var handoffStartedAt: TimeInterval?
    @ObservationIgnored private var transitionFeedbackTask: Task<Void, Never>?
    #if DEBUG
    /// `debug.regressionStartNearEnd` applies to the fixture episode only;
    /// applied to the successor, the hand-off test exits too early.
    @ObservationIgnored private var didApplyRegressionNearEnd = false
    #endif

    init() {
        PlaybackLifecycleDiagnostics.controllerCreated(lifecycleID)
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

    /// A track choice by language and title, not ordinal: an extra track
    /// on one episode would shift every ordinal below it.
    private struct TrackPreference {
        var audioLanguage: String?
        var audioTitle: String?
        var subtitleLanguage: String?
        var subtitleTitle: String?
        /// Subtitles turned off is carried too, or the next episode
        /// reinstates the server default.
        var subtitlesOff: Bool
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
        await start(
            media: media,
            startFromBeginning: startFromBeginning,
            client: client,
            trackPreferences: trackPreferences,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            missingSubtitleMode: missingSubtitleMode,
            prepared: nil,
            startPosition: startPosition,
            startPaused: startPaused
        )
    }

    private func start(
        media: MediaItem,
        startFromBeginning: Bool,
        client: JellyfinClient,
        trackPreferences: TrackPreferenceValues,
        preferredAudioLanguages: [String],
        preferredSubtitleLanguages: [String],
        missingSubtitleMode: MissingSubtitleMode,
        prepared: PlaybackSuccessorPreparation.PreparedPlayback?,
        startPosition: Double? = nil,
        startPaused: Bool = false
    ) async {
        guard !isClosed else { return }
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
        currentMedia = media
        // Reset every start, so a failed group start cannot leak its position.
        startPositionOverride = startPosition
        startsPaused = startPaused
        if deliveryItemId != media.id {
            // A new item negotiates from scratch.
            deliveryItemId = media.id
            delivery = .negotiated
            deliveryFallbacks = []
            resumeOverride = nil
            skipsLocalPlayback = false
            #if DEBUG
            // Regression hook: force a rung so HLS cases run on a server that
            // would direct-play everything. Raw value `remux` or `transcode`.
            if UserDefaults.standard.bool(forKey: "debug.playerRegression"),
               let forced = UserDefaults.standard.string(forKey: "debug.regressionInitialDelivery"),
               let rung = PlaybackDelivery(rawValue: forced), rung != .negotiated {
                delivery = rung
            }
            #endif
        }
        itemId = media.id
        audioDefaultMode = trackPreferences.audioMode
        subtitleDefaultMode = trackPreferences.subtitleMode
        self.preferredAudioLanguages = preferredAudioLanguages.isEmpty
            ? Locale.preferredLanguages
            : preferredAudioLanguages
        self.preferredSubtitleLanguages = preferredSubtitleLanguages.isEmpty
            ? SubtitlePreferencesStore.systemCaptionLanguages
            : preferredSubtitleLanguages
        self.missingSubtitleMode = missingSubtitleMode
        // A download plays from disk with no server round trip. Checked
        // before a prepared successor, which describes a network stream.
        var localSource: MediaSource?
        var localURL: URL?
        var localResumeTicks: Int64?
        #if os(iOS)
        var localIsTranscode = false
        if !skipsLocalPlayback, let local = DownloadStore.shared.localPlayback(for: media.id) {
            localSource = local.source
            localURL = local.url
            localIsTranscode = local.quality != .original
            localResumeTicks = local.resumeTicks
        }
        #endif
        isLocalPlayback = localURL != nil
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
            let info: PlaybackInfoResponse?
            let source: MediaSource
            var streamURL: URL
            var method: PlayMethod
            if let localURL, let localSource {
                info = nil
                source = localSource
                streamURL = localURL
                method = .directPlay
            } else if let prepared, prepared.mediaID == media.id {
                info = prepared.info
                source = prepared.source
                streamURL = prepared.streamURL
                method = prepared.method
            } else {
                var negotiated = try await client.playbackInfo(itemId: media.id, delivery: delivery)
                guard negotiated.errorCode == nil,
                      var resolvedSource = negotiated.mediaSources.first else {
                    throw JellyfinError.unplayable
                }
                // A disc this rung cannot play steps down before an attempt,
                // whatever the server says. The HUD still records why.
                let layout = PlaybackSourceLayout(
                    videoType: resolvedSource.videoType,
                    isoType: resolvedSource.isoType
                )
                if delivery == .negotiated, let refusal = layout.directPlayRefusal {
                    skipDelivery(to: PlaybackFallbackPolicy.start(for: layout), refusal: refusal)
                    negotiated = try await client.playbackInfo(itemId: media.id, delivery: delivery)
                    guard negotiated.errorCode == nil,
                          let lowered = negotiated.mediaSources.first else {
                        throw JellyfinError.unplayable
                    }
                    resolvedSource = lowered
                }
                info = negotiated
                source = resolvedSource
                (streamURL, method) = try client.streamURL(itemId: media.id, source: source)
            }
            mediaSourceId = source.id
            playMethod = method
            // Read a disc image directly only when direct play serves the
            // image itself. Transcodes and downloads are ordinary streams.
            let discRequest: DiscPlaybackRequest? = !isLocalPlayback
                && method == .directPlay
                && PlaybackSourceLayout(
                    videoType: source.videoType,
                    isoType: source.isoType
                ).isReadableDisc
                ? DiscPlaybackRequest(
                    runtimeSeconds: source.runTimeTicks.map(Ticks.seconds)
                )
                : nil
            var resumeSeconds = Self.resumeStartSeconds(
                fallbackOverrideSeconds: startPositionOverride ?? resumeOverride,
                startFromBeginning: startFromBeginning,
                localResumeTicks: localResumeTicks,
                serverPositionTicks: media.userData?.playbackPositionTicks
            )
            resumeOverride = nil
            startPositionOverride = nil
            incidents.beginAttempt(
                delivery: delivery,
                method: method,
                source: source,
                cached: SampleBufferPlayerEngine.cachesPlayback(
                    url: streamURL, delivery: method.delivery
                ),
                disc: discRequest != nil,
                resumeSeconds: resumeSeconds
            )
            if UserDefaults.standard.bool(forKey: "debug.frameLossBench") {
                let pinnedStart = UserDefaults.standard.double(forKey: "debug.benchStartSeconds")
                if pinnedStart > 0 {
                    resumeSeconds = pinnedStart
                }
            }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debug.regressionStartNearEnd"),
               !didApplyRegressionNearEnd,
               let ticks = source.runTimeTicks ?? media.runTimeTicks {
                didApplyRegressionNearEnd = true
                resumeSeconds = max(Ticks.seconds(ticks) - 45, 0)
            }
            #endif

            let resolvedExtras = await extras
            let resolvedSegments = await segments
            // UI regression hook: start inside the first skippable segment.
            if UserDefaults.standard.bool(forKey: "debug.playerRegression"),
               UserDefaults.standard.bool(forKey: "debug.regressionStartAtFirstSkippable"),
               let segment = resolvedSegments.first(where: { $0.kind.isSkippable }) {
                resumeSeconds = segment.start + min(max((segment.end - segment.start) / 4, 0.1), 1)
            }

            playerInfo = itemInfo(
                for: media,
                source: source,
                client: client,
                extras: resolvedExtras,
                segments: resolvedSegments
            )

            // A transcoded download is a different file from the source, so
            // its source streams don't describe it. Empty metadata is safe:
            // selection falls back to what the file demuxes to.
            #if os(iOS)
            let sourceStreams: [MediaStream] = localIsTranscode ? [] : (source.mediaStreams ?? [])
            #else
            let sourceStreams = source.mediaStreams ?? []
            #endif
            // Map the server's default audio to the demuxer's per-type
            // 1-based ordinal; embedded streams keep demux order.
            let embeddedAudio = sourceStreams.filter { $0.type == "Audio" }
            var initialAudioOrdinal: Int?
            if let index = source.defaultAudioStreamIndex,
               let position = embeddedAudio.firstIndex(where: { $0.index == index }) {
                initialAudioOrdinal = position + 1
            }
            initialAudioOrdinal = TrackSelectionPolicy.audioOrdinal(
                mode: audioDefaultMode,
                candidates: embeddedAudio.map(Self.selectionCandidate),
                serverDefault: initialAudioOrdinal,
                preferredLanguages: self.preferredAudioLanguages,
                originalLanguage: resolvedExtras.originalLanguage ?? media.originalLanguage
            )
            // A choice carried from the previous episode outranks the default.
            let audioLayout = embeddedAudio.map(Self.layoutStream)
            policyAudioOrdinal = initialAudioOrdinal
            audioMemoryLayout = audioLayout
            audioMemoryScope = AudioTrackMemoryStore.scope(
                seriesID: media.seriesId,
                itemID: media.id
            )
            if let preference = trackPreference,
               let carried = AudioTrackMemoryPolicy.descriptiveOrdinal(
                   matchingLanguage: preference.audioLanguage,
                   title: preference.audioTitle,
                   in: audioLayout
               ) {
                initialAudioOrdinal = carried
            }
            // A remembered choice for this show outranks both, while it
            // still matches a track here.
            if let scope = audioMemoryScope,
               let remembered = audioTrackMemory?.choice(for: scope),
               let carried = AudioTrackMemoryPolicy.ordinal(
                   for: remembered,
                   in: audioLayout
               ) {
                initialAudioOrdinal = carried
            }

            // Subtitle ordinals: embedded first, then external, as the engine
            // lists them.
            let allSubtitles = sourceStreams.filter { $0.type == "Subtitle" }
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
            // Automatic selection alone; the exit compares against it.
            let selectedAudioLanguage = initialAudioOrdinal.flatMap { ordinal in
                embeddedAudio.indices.contains(ordinal - 1)
                    ? embeddedAudio[ordinal - 1].language
                    : nil
            }
            let automaticSubtitleOrdinal: Int? = subtitleDefaultMode == .system
                ? Self.systemDefaultSubtitleOrdinal(
                    current: initialSubtitleOrdinal,
                    subtitles: orderedSubtitles,
                    selectedAudioLanguage: selectedAudioLanguage,
                    preferredLanguages: self.preferredSubtitleLanguages
                )
                : TrackSelectionPolicy.subtitleOrdinal(
                    mode: subtitleDefaultMode,
                    candidates: orderedSubtitles.map(Self.selectionCandidate),
                    serverDefault: initialSubtitleOrdinal,
                    preferredLanguages: self.preferredSubtitleLanguages,
                    selectedAudioLanguage: selectedAudioLanguage
                )
            policySubtitleOrdinal = automaticSubtitleOrdinal
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
            } else {
                initialSubtitleOrdinal = automaticSubtitleOrdinal
            }
            // A remembered choice for this show outranks both, while it
            // still matches a track here or says none.
            subtitleMemoryLayout = orderedSubtitles.map(Self.subtitleLayoutStream)
            subtitleMemoryScope = SubtitleTrackMemoryStore.scope(
                seriesID: media.seriesId,
                itemID: media.id
            )
            if let scope = subtitleMemoryScope,
               let remembered = subtitleTrackMemory?.choice(for: scope),
               let carried = SubtitleTrackMemoryPolicy.ordinal(
                   for: remembered,
                   in: subtitleMemoryLayout
               ) {
                initialSubtitleOrdinal = carried
            }
            // Bench hook: force a subtitle language so scripted runs always
            // have cues to count.
            if let language = UserDefaults.standard.string(forKey: "debug.benchSubtitleLanguage"),
               !language.isEmpty {
                if language == "off" {
                    // Explicit, or the system caption preference may turn
                    // one on.
                    initialSubtitleOrdinal = 0
                } else if let ordinal = Self.ordinal(matchingLanguage: language, title: nil, in: orderedSubtitles) {
                    initialSubtitleOrdinal = ordinal
                }
            }
            audioStreams = embeddedAudio
            orderedSubtitleStreams = orderedSubtitles

            configureSystemMediaCallbacks()
            guard !isClosed else { throw CancellationError() }
            try Task.checkCancellation()
            let previousResourcesRetired = await PlaybackLifecycleDiagnostics
                .waitForMediaResourcesToRetire(timeout: .seconds(15))
            if !previousResourcesRetired {
                let lifecycle = PlaybackLifecycleDiagnostics.snapshot()
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Playback Resource Retirement Timeout",
                    signpostID: performanceSignpostID,
                    "demux=%{public}d renderers=%{public}d footprintMB=%{public}.1f",
                    lifecycle.activeDemuxLoops,
                    lifecycle.attachedRendererSets,
                    lifecycle.footprintMB
                )
                // Never attach a new engine to the display layer while the
                // outgoing synchronizer still owns it; that stalls the
                // autoplayed episode on Apple TV.
                throw PlaybackStartError.previousEngineDidNotRetire
            }
            guard !isClosed else { throw CancellationError() }
            try Task.checkCancellation()
            try audioSession.activate { [weak self] in
                guard let engine = self?.engine else { return false }
                return !engine.isPaused
            }

            let engine = SampleBufferPlayerEngine()
            startStage = .start
            // Carry the viewer's speed across hand-off and fallback swaps.
            engine.setRate(self.engine?.rate ?? 1)
            if startsPaused {
                // Before priming, so the clock anchors at rate 0 and the
                // member waits on its first frame.
                engine.pause()
            }
            startsPaused = false
            engine.prepare(
                url: streamURL,
                itemID: media.id,
                delivery: method.delivery,
                expectedLength: source.size,
                disc: discRequest,
                startSeconds: resumeSeconds,
                initialAudioOrdinal: initialAudioOrdinal,
                initialSubtitleOrdinal: initialSubtitleOrdinal,
                audioTrackMetadata: embeddedAudio.map(Self.trackMetadata),
                embeddedSubtitleMetadata: embeddedSubtitles.map(Self.trackMetadata),
                externalSubtitles: externalTracks,
                authorization: client.mediaRequestAuthorization()
            )
            engine.onFinished = { [weak self] in self?.playbackDidFinish() }
            engine.onTimeAdvanced = { [weak self] position, duration in
                self?.automation.tick(position: position, duration: duration)
            }
            engine.onSeekReady = { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
                self.onEngineReady?()
            }
            engine.onBufferingChanged = { [weak self, weak engine] buffering in
                guard let self, let engine, self.engine === engine else { return }
                // A timed skip waits out a stall before seeking.
                self.automation.isBuffering = buffering
                self.onBufferingChanged?(buffering)
            }
            engine.setVideoOutputSuspended(videoOutputSuspended)
            engine.onPlaybackStarted = { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
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
                    self.rememberAudioChoice(engine: engine)
                    self.rememberSubtitleChoice(engine: engine)
                }
                if let language = engine?.subtitleTracks.first(where: \.isSelected)?.languageTag,
                   let normalized = SubtitlePreferencesStore.normalizedLanguage(language) {
                    // Apple's caption contract: feed explicit choices back
                    // to the system caption-language preferences.
                    _ = MACaptionAppearanceAddSelectedLanguage(.user, normalized as CFString)
                }
            }
            playbackIdentity = media.id
            self.engine = engine
            guard let playerInfo else { throw JellyfinError.unplayable }
            automation.beginItem(identity: media.id, segments: playerInfo.segments)
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
            nowPlaying.activate(
                info: playerInfo,
                itemID: itemId,
                engine: engine,
                transport: transportActions,
                replacingActiveSession: handoffStartedAt != nil
            )
            let preferredSet = Set(self.preferredSubtitleLanguages.compactMap(
                SubtitlePreferencesStore.normalizedLanguage
            ))
            let hasSuitableLocalTrack = orderedSubtitles.contains {
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
                streams: orderedSubtitles,
                preferredLanguages: self.preferredSubtitleLanguages,
                missingMode: missingSubtitleMode,
                hasSuitableLocalTrack: hasSuitableLocalTrack
            ) { [weak self] stream in
                self?.orderedSubtitleStreams.append(stream)
                self?.nowPlaying.updateLanguageOptions()
            }
            lastKnownPosition = resumeSeconds
            let reporting = PlaybackReportingSession(
                client: client,
                itemID: itemId,
                mediaSourceID: mediaSourceId,
                playSessionID: info?.playSessionId,
                method: method,
                signpostID: performanceSignpostID,
                runtimeTicks: source.runTimeTicks ?? media.runTimeTicks
            )
            self.reporting = reporting

            #if DEBUG
            // UI-test hook: widen the window where dismissal races startup.
            let startupDelay = UserDefaults.standard.double(
                forKey: "debug.regressionPlaybackStartDelaySeconds"
            )
            if startupDelay > 0 {
                try await Task.sleep(for: .seconds(startupDelay))
            }
            #endif

            if isLocalPlayback {
                // Not awaited: an unreachable server would stall local
                // playback for the full request timeout. Failures are dropped.
                Task {
                    try? await reporting.reportStart(at: resumeSeconds)
                }
            } else {
                do {
                    try await reporting.reportStart(at: resumeSeconds)
                } catch is CancellationError {
                    // Dismissed mid-request: don't recreate work after teardown.
                    throw CancellationError()
                } catch {
                    // Reporting failure must not interrupt playback.
                }
            }
            try Task.checkCancellation()
            guard self.engine === engine, self.reporting === reporting, reporting.isActive else {
                return
            }
            startProgressLoop()
            diagnosticSampler.cacheMetrics = { [weak self] in self?.engine?.playbackCacheMetrics }
            diagnosticSampler.startTrace(engine: engine) { [weak self] in
                self?.soakExitRequested = true
                self?.soakExitRequestedAt = ContinuousClock.now
            }
            diagnosticSampler.startHUD(
                source: source, method: method, engine: engine,
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
            resolveNextUp(after: media, client: client)
        } catch {
            // `beginStop` also claims the exactly-once stop report.
            let cancelled = Self.isStartCancellation(error, taskCancelled: Task.isCancelled, closed: isClosed)
            finishEpisodeHandoff(outcome: cancelled ? "cancelled" : "failed")
            if !cancelled {
                incidents.startFailed(error, delivery: delivery, stage: startStage)
            }
            _ = beginStop()
            if !cancelled {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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

    private nonisolated static func subtitleLayoutStream(_ stream: MediaStream) -> SubtitleLayoutStream {
        SubtitleLayoutStream(
            language: stream.language,
            title: stream.title,
            isForced: stream.isForced == true,
            isHearingImpaired: stream.isHearingImpaired == true,
            isExternal: stream.isExternal == true,
            isDefault: stream.isDefault == true
        )
    }

    private nonisolated static func layoutStream(_ stream: MediaStream) -> AudioLayoutStream {
        AudioLayoutStream(
            codec: stream.codec,
            channels: stream.channels,
            language: stream.language,
            title: stream.title,
            isDefault: stream.isDefault == true
        )
    }

    /// Persists, or drops, an audio choice the viewer just made.
    ///
    /// The selection callback fires only for deliberate choices, not
    /// automatic selection. Recorded now, not at exit, because by exit the
    /// item, layout or engine may belong to the next episode.
    private func rememberAudioChoice(engine: SampleBufferPlayerEngine) {
        guard let audioTrackMemory,
              let scope = audioMemoryScope,
              let selected = engine.audioTracks.first(where: \.isSelected),
              audioMemoryLayout.indices.contains(selected.engineID - 1),
              // Engine ordinals count delivered tracks, the layout counts
              // source tracks. On remux or transcode they can differ.
              engine.audioTracks.count == audioMemoryLayout.count else { return }
        switch AudioTrackMemoryPolicy.outcome(
            chosen: selected.engineID,
            automatic: policyAudioOrdinal
        ) {
        case .forget:
            audioTrackMemory.forget(scope)
        case .remember(let ordinal):
            let stream = audioMemoryLayout[ordinal - 1]
            audioTrackMemory.remember(
                RememberedAudioChoice(
                    language: stream.language,
                    title: stream.title,
                    ordinal: ordinal,
                    layout: AudioTrackMemoryPolicy.fingerprint(of: audioMemoryLayout)
                ),
                for: scope
            )
        }
    }

    /// Persists, or drops, a subtitle choice, like `rememberAudioChoice`.
    ///
    /// Ordinal 0 (off) is a real choice. Subtitle search appends tracks
    /// mid-play, so the engine may list more than the layout; the prefix
    /// still lines up, and appended tracks are not remembered.
    private func rememberSubtitleChoice(engine: SampleBufferPlayerEngine) {
        guard let subtitleTrackMemory,
              let scope = subtitleMemoryScope,
              engine.subtitleTracks.count >= subtitleMemoryLayout.count else { return }
        let ordinal = engine.subtitleTracks.first(where: \.isSelected)?.engineID
            ?? SubtitleTrackMemoryPolicy.offOrdinal
        guard ordinal == SubtitleTrackMemoryPolicy.offOrdinal
                || subtitleMemoryLayout.indices.contains(ordinal - 1) else { return }
        switch SubtitleTrackMemoryPolicy.outcome(
            chosen: ordinal,
            automatic: policySubtitleOrdinal
        ) {
        case .forget:
            subtitleTrackMemory.forget(scope)
        case .remember(let ordinal):
            let layout = SubtitleTrackMemoryPolicy.fingerprint(of: subtitleMemoryLayout)
            let stream = ordinal == SubtitleTrackMemoryPolicy.offOrdinal
                ? nil
                : subtitleMemoryLayout[ordinal - 1]
            subtitleTrackMemory.remember(
                RememberedSubtitleChoice(
                    isOff: ordinal == SubtitleTrackMemoryPolicy.offOrdinal,
                    language: stream?.language,
                    title: stream?.title,
                    ordinal: ordinal,
                    layout: layout
                ),
                for: scope
            )
        }
    }

    private nonisolated static func selectionCandidate(_ stream: MediaStream) -> TrackSelectionCandidate {
        TrackSelectionCandidate(
            language: stream.language,
            isDefault: stream.isDefault == true,
            isOriginal: stream.isOriginal == true,
            isForced: stream.isForced == true,
            isHearingImpaired: stream.isHearingImpaired == true
        )
    }

    /// Seeds a first playback from the system caption policy. Jellyfin's
    /// default wins when present, except under Forced Only.
    private static func systemDefaultSubtitleOrdinal(
        current: Int?,
        subtitles: [MediaStream],
        selectedAudioLanguage: String?,
        preferredLanguages: [String]
    ) -> Int? {
        let displayType: MACaptionAppearanceDisplayType = UIAccessibility.isClosedCaptioningEnabled
            ? .alwaysOn
            : MACaptionAppearanceGetDisplayType(.user)
        let preferred = SubtitlePreferencesStore.deduplicated(preferredLanguages)

        func best(requireForced: Bool) -> Int? {
            let candidates = subtitles.enumerated().filter { _, stream in
                !requireForced || stream.isForced == true
            }
            for language in preferred {
                if let match = candidates.first(where: { _, stream in
                    SubtitlePreferencesStore.normalizedLanguage(stream.language ?? "") == language
                        && stream.isHearingImpaired == true
                }) {
                    return match.offset + 1
                }
                if let match = candidates.first(where: { _, stream in
                    SubtitlePreferencesStore.normalizedLanguage(stream.language ?? "") == language
                }) {
                    return match.offset + 1
                }
            }
            if let match = candidates.first(where: { $0.element.isHearingImpaired == true }) {
                return match.offset + 1
            }
            return candidates.first.map { $0.offset + 1 }
        }

        switch displayType {
        case .forcedOnly:
            return best(requireForced: true) ?? 0
        case .alwaysOn:
            return current ?? best(requireForced: false) ?? 0
        case .automatic:
            if let current { return current }
            if let forced = best(requireForced: true) { return forced }
            let audio = selectedAudioLanguage.flatMap(SubtitlePreferencesStore.normalizedLanguage)
            if let primary = preferred.first, let audio, audio != primary {
                return best(requireForced: false)
            }
            return 0
        @unknown default:
            return current
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
            self?.isExternalPlaybackRouteActive = active
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
        if UserDefaults.standard.bool(forKey: "debug.regressionInjectAudioRendererFailure") {
            Task { [weak self, weak engine] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, let engine, self.engine === engine else { return }
                engine.simulateAudioRendererFailureForRegression()
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
        guard !isAdvancing, let next = nextUp, let client else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        beginEpisodeHandoff(to: next)
        prepareNextIfNeeded(force: true)
        let prepared = await successorPreparation.preparedForHandoff()
        guard !isClosed else { return }
        captureTrackPreference()
        let outgoingResourcesRetired = await stop(
            preservingPreparedNext: true,
            preservingPlayerSurface: true
        )
        guard outgoingResourcesRetired else {
            let lifecycle = PlaybackLifecycleDiagnostics.snapshot()
            os_signpost(
                .event,
                log: PlaybackPerformance.log,
                name: "Playback Resource Retirement Timeout",
                signpostID: performanceSignpostID,
                "scope=handoff demux=%{public}d renderers=%{public}d footprintMB=%{public}.1f",
                lifecycle.activeDemuxLoops,
                lifecycle.attachedRendererSets,
                lifecycle.footprintMB
            )
            _ = beginStop()
            errorMessage = PlaybackStartError.previousEngineDidNotRetire.errorDescription
            return
        }
        guard !isClosed else { return }
        // Don't let the old card reappear over a successor resumed near its end.
        nextUp = nil
        didFinish = false
        errorMessage = nil
        // Resume: the next episode may have a position of its own.
        await start(
            media: next,
            startFromBeginning: false,
            client: client,
            trackPreferences: TrackPreferenceValues(
                audioMode: audioDefaultMode,
                subtitleMode: subtitleDefaultMode
            ),
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            missingSubtitleMode: missingSubtitleMode,
            prepared: prepared
        )
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
            // The file's title, not Jellyfin's display title, which reads
            // the same on every untagged track and would match the first.
            audioTitle: audioStream?.title,
            subtitleLanguage: subtitleStream?.language,
            subtitleTitle: subtitleStream?.displayTitle,
            // No selected subtitle track means off.
            subtitlesOff: subtitle == nil
        )
    }

    /// Engine ordinals are 1-based and count per kind.
    private static func stream(at ordinal: Int, in streams: [MediaStream]) -> MediaStream? {
        let index = ordinal - 1
        return streams.indices.contains(index) ? streams[index] : nil
    }

    /// Where the carried choice lands in these streams, or nil to keep the
    /// server's default.
    private static func ordinal(
        matchingLanguage language: String?,
        title: String?,
        in streams: [MediaStream]
    ) -> Int? {
        guard language != nil || title != nil else { return nil }
        if let exact = streams.firstIndex(where: { $0.language == language && $0.displayTitle == title }) {
            return exact + 1
        }
        // Titles vary per episode; fall back to language alone.
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
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

    #if os(iOS)
    /// Locked or backgrounded: audio carries on, cache fill stops, and the
    /// picture is dropped unless PiP or AirPlay still shows it.
    private func applicationDidEnterBackground() {
        guard !isClosed, engine != nil else { return }
        suspendBufferFill()
        guard !isPictureInPictureShowing(), !isExternalPlaybackRouteActive else { return }
        videoOutputSuspended = true
        engine?.setVideoOutputSuspended(true)
    }

    /// Back on screen: the picture restarts from the playhead.
    private func applicationWillEnterForeground() {
        guard !isClosed else { return }
        videoOutputSuspended = false
        engine?.setVideoOutputSuspended(false)
        resumeBufferFill()
    }
    #endif

    // MARK: - Group playback
    //
    // What a SyncPlay driver calls. Separate from the viewer's controls
    // below, which the driver turns into group requests, so this path does
    // not recurse. The driver never holds the engine.

    /// Start so the current position is on screen exactly at `hostTime`.
    func playGroup(atHostTime hostTime: CMTime) {
        engine?.play(atHostTime: hostTime)
    }

    func pauseGroup() {
        engine?.pause()
    }

    func seekGroup(to seconds: Double) {
        engine?.seek(to: seconds)
    }

    /// A drift nudge on top of the viewer's speed. 1 is no correction.
    func setCorrectionRate(_ multiplier: Double) {
        engine?.setCorrectionRate(multiplier)
    }

    /// The synchronizer's media clock, 0 with no engine. For the driver,
    /// never a view: it is tick-rate state the player root must not read.
    var clockPosition: Double { engine?.clockPosition ?? 0 }

    /// Loaded and anchored but not rolling.
    var isPrimedAndPaused: Bool {
        guard let engine else { return false }
        return engine.isPaused && !engine.isBuffering
    }

    /// The clock is advancing (a group report's `IsPlaying`). Not the
    /// inverse of `isPrimedAndPaused`: a buffering engine is neither.
    var isClockRunning: Bool {
        guard let engine else { return false }
        return !engine.isPaused && !engine.isBuffering
    }

    /// Swaps the item in one player session when the group moves on. Same
    /// stop-then-start as `playNextEpisode`, so the video surface survives,
    /// without the successor warm-up.
    func startGroupItem(_ media: MediaItem, startPosition: Double) async {
        guard !isAdvancing, !isClosed, let client else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        let retired = await stop(preservingPreparedNext: false, preservingPlayerSurface: true)
        guard retired, !isClosed, !Task.isCancelled, groupTransport != nil else { return }
        nextUp = nil
        didFinish = false
        errorMessage = nil
        await start(
            media: media,
            startFromBeginning: false,
            client: client,
            trackPreferences: TrackPreferenceValues(
                audioMode: audioDefaultMode,
                subtitleMode: subtitleDefaultMode
            ),
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            missingSubtitleMode: missingSubtitleMode,
            startPosition: startPosition,
            startPaused: true
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

    private func startProgressLoop() {
        reporting?.startProgress(snapshot: { [weak self] in
            guard let self, let engine = self.engine else { return nil }
            self.lastKnownPosition = engine.timePosition
            self.nowPlaying.updateTimeline()
            return .init(seconds: engine.timePosition, isPaused: engine.isPaused)
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
        if !preservingPreparedNext {
            successorPreparation.cancel()
        }
        subtitleSearch.detach()
        let seconds = engine?.timePosition ?? lastKnownPosition
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

    func stop() async {
        let report = beginStop()
        await report?.value
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
        lastKnownPosition = engine.timePosition
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
        guard !isClosed, let client, let media = currentMedia else { return }
        let resumeAt = engine?.timePosition ?? lastKnownPosition
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
        // Keep the display layer mounted, as the hand-off does. Destroying it
        // leaves the old renderer registered as attached, and the retirement
        // wait times out every time.
        let outgoingResourcesRetired = await stop(
            preservingPreparedNext: true,
            preservingPlayerSurface: true
        )
        guard !isClosed else { return }
        guard outgoingResourcesRetired else {
            errorMessage = PlaybackStartError.previousEngineDidNotRetire.errorDescription
            return
        }
        didFinish = false
        errorMessage = nil
        delivery = next
        resumeOverride = resumeAt
        await start(
            media: media,
            startFromBeginning: false,
            client: client,
            trackPreferences: TrackPreferenceValues(
                audioMode: audioDefaultMode,
                subtitleMode: subtitleDefaultMode
            ),
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            missingSubtitleMode: missingSubtitleMode,
            prepared: nil,
            // In a group, prime and report Ready; the server starts playback.
            startPaused: groupTransport != nil
        )
    }

    // The facts line, skipping anything the server didn't know.
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

        // Keep the opening chapter: a jump target, though no tick at 0:00.
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
            posterURL: client.imageURL(for: media, kind: .poster, maxWidth: 400),
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

    // "Dolby Digital+ Atmos 5.1".
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

    // Shared with the detail page's badges via MediaQuality.
    private static func resolutionClass(width: Int) -> String {
        MediaQuality.resolutionClass(width: width)
    }

    private static func rangeLabel(_ range: String) -> String {
        MediaQuality.rangeLabel(range)
    }

    /// The attempt's end, as the diagnostics history names it.
    private var stopOutcome: String {
        if errorMessage != nil { return "failed" }
        if didFinish { return "finished" }
        if handoffStartedAt != nil { return "handoff" }
        if isFallingBack { return "fallback" }
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
