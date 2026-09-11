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

/// HEL-148 soak diagnostic: milliseconds for a `Duration`, shared by the
/// DecodeTrace loop's `mainLateMs`/`pumpMs`/`Soak*` lines.
private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// Negotiates the stream with Jellyfin, runs the Lagoon engine (the app's
/// only player since HEL-48 went all-in), and owns progress reporting.
@Observable
@MainActor
final class PlaybackController {
    private(set) var engine: SampleBufferPlayerEngine?
    /// Changes only when a prepared engine replaces the previous one. The
    /// persistent player surface uses it to reset episode-scoped chrome.
    private(set) var playbackIdentity = ""
    /// Process-local identity of the hosted AVSampleBufferDisplayLayer. The
    /// debug UI journey compares it across autoplay to prove that a stable
    /// SwiftUI branch also retained the actual UIKit render surface.
    private(set) var playerSurfaceIdentity = ""
    private(set) var playerInfo: PlayerItemInfo?
    private(set) var errorMessage: String?
    private(set) var didFinish = false
    private(set) var isExternalPlaybackRouteActive = false
    let subtitleSearch = SubtitleSearchCoordinator()
    /// Reports failures, recoveries and degraded sessions to the
    /// diagnostics hub, one attempt at a time (HEL-159).
    let incidents = PlaybackIncidentMonitor()

    /// The episode queued behind this one, resolved once at start so the Up
    /// Next card can appear the instant the credits do (HEL-66). Nil for
    /// movies and at the end of a series.
    private(set) var nextUp: MediaItem?

    private(set) var hudLines: [String] = []
    /// The byte-zero prefix remains available for compatibility diagnostics,
    /// while the timeline renders every sparse range retained around seeks.
    /// HLS/native paths have no direct-file byte-range model.
    private(set) var bufferedFraction: Double?
    private(set) var bufferedRanges: [PlaybackBufferedRange] = []
    private(set) var playheadPrefetchCount = 0

    private var client: JellyfinClient?
    /// Retained so a failed attempt can be replayed on the next rung of the
    /// delivery ladder (HEL-100); everything else `start` needs is already
    /// controller state.
    private var currentMedia: MediaItem?
    /// How the current item is being delivered, and the position a retry
    /// resumes from. The ladder belongs to one item — a new one starts at
    /// the top.
    private var delivery: PlaybackDelivery = .negotiated
    private var deliveryItemId: String?
    private var resumeOverride: Double?
    /// One rung at a time. The renderer and the demux loop can both report
    /// the same collapse, and two fallbacks in flight would skip a rung —
    /// straight past the cheap remux to a transcode nobody needed.
    private var isFallingBack = false
    /// Every rung this item has descended, and the failure that forced it.
    ///
    /// The detail inside `failure.message` — the VideoToolbox status or
    /// renderer error that is the entire reason the ladder ran — reaches
    /// `errorMessage` only when the ladder runs *out* of rungs. A fallback
    /// that succeeds therefore throws away the one fact that explains it,
    /// leaving a signpost as the only trace and Instruments as the only
    /// reader — which needs a paired device, and an Apple TV that cannot be
    /// paired has no way to get at it. The HUD carries it instead.
    private(set) var deliveryFallbacks: [PlaybackDeliveryFallbackRecord] = []
    private var itemId = ""
    private var mediaSourceId = ""
    private var playMethod: PlayMethod = .directPlay

    var activePlayMethod: PlayMethod { playMethod }
    /// Jellyfin's `PlayMethod` collapses the remux and transcode rungs to
    /// the same `Transcode` value, so the regression probe needs the
    /// ladder rung itself to tell a forced HEL-124 remux apart from an
    /// ordinary transcode.
    var activeDeliveryRung: PlaybackDelivery { delivery }

    var isPlaybackCacheActive: Bool {
        playbackCache.current != nil
    }
    @ObservationIgnored private var reporting: PlaybackReportingSession?
    @ObservationIgnored private let diagnosticSampler = PlaybackDiagnosticsSampler()
    private var bufferFillTask: Task<Void, Never>?
    private var bufferFillGeneration = UUID()
    private var isClosed = false
    private var lastKnownPosition: Double = 0
    private var nextUpTask: Task<Void, Never>?
    @ObservationIgnored private let successorPreparation = PlaybackSuccessorPreparation()
    /// Guards the hand-off: `didFinish` and an expiring countdown can both
    /// arrive at the end of a file, and advancing twice would skip an
    /// episode outright.
    private(set) var isAdvancing = false
    /// Presentation state is separate from the reentrancy guard: playback
    /// reporting may still be finishing after the successor has shown its
    /// first frame, and must not leave a spinner over healthy video.
    private(set) var isTransitionOverlayVisible = false
    /// User action/EOF to the successor's first primed presentation clock.
    /// Visible in the HUD and hardware accessibility probe for regression
    /// comparisons; nil before the first episode handoff.
    private(set) var lastHandoffMilliseconds: Double?
    /// HEL-148 soak hook (`debug.soakExitAtSeconds`): flips once the film
    /// reaches the configured position, so the view's `onChange` can drive
    /// the same `dismiss()` a real exit would. Observable so that onChange
    /// fires; kept separate from `didFinish`, which means something
    /// different (the file actually ran out).
    private(set) var soakExitRequested = false
    /// When the soak exit was requested, so `close()` can report how long
    /// the whole exit — not just `beginStop()` — took from that instant.
    @ObservationIgnored private var soakExitRequestedAt: ContinuousClock.Instant?
    /// What the viewer picked in the track panel, carried into the next
    /// episode (HEL-66). Nil on a first load — there is nothing to carry.
    private var trackPreference: TrackPreference?
    /// The current item's streams in the order the engine numbers them, so
    /// a selected track can be named rather than just counted. Audio is the
    /// embedded list; subtitles are embedded first, then external.
    private var audioStreams: [MediaStream] = []
    private var orderedSubtitleStreams: [MediaStream] = []
    private var preferredAudioLanguages: [String] = []
    private var preferredSubtitleLanguages: [String] = []
    private var audioDefaultMode: AudioDefaultMode = .serverDefault
    private var subtitleDefaultMode: SubtitleDefaultMode = .system
    private var missingSubtitleMode: MissingSubtitleMode = .ask
    @ObservationIgnored private let audioSession = PlaybackAudioSession()
    @ObservationIgnored private let nowPlaying = NowPlayingCoordinator()
    @ObservationIgnored private let playbackCache = PlaybackCacheCoordinator(
        isEnabled: PlaybackBufferPolicy.backgroundBufferingEnabled
    )
    @ObservationIgnored private let lifecycleID = UUID()
    @ObservationIgnored private var handoffStartedAt: TimeInterval?
    @ObservationIgnored private var transitionFeedbackTask: Task<Void, Never>?
    #if DEBUG
    /// `debug.regressionStartNearEnd` exists to reach autoplay quickly. It
    /// must only affect the fixture episode: applying it again to the
    /// successor made the old handoff test exit before sustained playback
    /// could be measured.
    @ObservationIgnored private var didApplyRegressionNearEnd = false
    #endif

    init() {
        PlaybackLifecycleDiagnostics.controllerCreated(lifecycleID)
    }

    deinit {
        PlaybackLifecycleDiagnostics.controllerDestroyed(lifecycleID)
    }

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

    func start(
        media: MediaItem,
        startFromBeginning: Bool,
        client: JellyfinClient,
        trackPreferences: TrackPreferenceValues = TrackPreferenceValues(),
        preferredAudioLanguages: [String] = [],
        preferredSubtitleLanguages: [String] = [],
        missingSubtitleMode: MissingSubtitleMode = .ask
    ) async {
        await start(
            media: media,
            startFromBeginning: startFromBeginning,
            client: client,
            trackPreferences: trackPreferences,
            preferredAudioLanguages: preferredAudioLanguages,
            preferredSubtitleLanguages: preferredSubtitleLanguages,
            missingSubtitleMode: missingSubtitleMode,
            prepared: nil
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
        prepared: PlaybackSuccessorPreparation.PreparedPlayback?
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
        if deliveryItemId != media.id {
            // A different item negotiates from scratch: the previous one's
            // failures say nothing about this file.
            deliveryItemId = media.id
            delivery = .negotiated
            deliveryFallbacks = []
            resumeOverride = nil
            #if DEBUG
            // Regression hook: start on a chosen rung instead of negotiating,
            // so the HLS cases open a real playlist on a server whose content
            // would otherwise direct-play — every public-demo item is H.264
            // (HEL-144 / audit A18). `debug.regressionInitialDelivery` is a
            // `PlaybackDelivery` raw value: `remux` or `transcode`.
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
        // How far the attempt got, for the report if it fails: nothing
        // negotiated, or an engine that never became ready.
        var startStage: PlaybackFailureDetail.Stage = .negotiate
        do {
            // Chapters and trickplay ride alongside the negotiation rather
            // than after it — neither is in PlaybackInfo, and waiting for a
            // second round trip would delay the first frame (HEL-39).
            async let extras = client.playbackExtras(itemId: media.id)
            async let segments = client.mediaSegments(itemId: media.id)
            let info: PlaybackInfoResponse
            let source: MediaSource
            var streamURL: URL
            var method: PlayMethod
            if let prepared, prepared.mediaID == media.id {
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
                // A disc cannot be played from the bytes this rung serves,
                // whatever the server answers about direct play, so the
                // ladder steps past it before an attempt rather than after
                // one (HEL-133). No engine starts, but the HUD still gets a
                // record of why the rung below is in force.
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
            #if DEBUG && os(iOS)
            // HEL-166 spike: a title the spike has on disk plays from there.
            // The server's negotiation still ran above, so track metadata
            // and reporting stay as for a stream; the bytes are local.
            if let local = DownloadSpikeStore.shared.completedLocalURL(itemID: media.id) {
                streamURL = local
                method = .directPlay
                DownloadSpikeStore.log.info("playing \(media.id, privacy: .public) from \(local.path(percentEncoded: false), privacy: .public)")
            }
            #endif
            mediaSourceId = source.id
            playMethod = method
            // A disc image Lagoon can read is played by reading it, not by
            // asking the server to rebuild it — but only when the bytes on
            // offer are the image itself. A transcode of the same title is an
            // ordinary stream and must stay one (HEL-133).
            let discRequest: DiscPlaybackRequest? = method == .directPlay
                && PlaybackSourceLayout(
                    videoType: source.videoType,
                    isoType: source.isoType
                ).isReadableDisc
                ? DiscPlaybackRequest(
                    runtimeSeconds: source.runTimeTicks.map(Ticks.seconds)
                )
                : nil
            // A local file needs no cache in front of it.
            let cacheSession = streamURL.isFileURL ? nil : playbackCache.activate(
                itemID: media.id,
                url: streamURL,
                method: method,
                expectedLength: source.size,
                authorization: client.mediaRequestAuthorization()
            )
            let playbackURL = cacheSession?.completeFileURL ?? streamURL
            // A complete file plays from disk without the session, except a
            // disc image, whose reader lives behind the session (HEL-167).
            let transportCache = PlaybackBufferPolicy.engineUsesCacheSession(
                playsFromCompleteFile: playbackURL.isFileURL,
                disc: discRequest != nil,
                method: method
            ) ? cacheSession : nil
            publishBufferMetrics(cacheSession?.metrics)

            var resumeSeconds: Double = 0
            if let resumeOverride {
                // A fallback retry resumes exactly where the failure landed,
                // which outranks both the server's position and an explicit
                // "start from beginning" the viewer already got past.
                resumeSeconds = resumeOverride
            } else if !startFromBeginning, let ticks = media.userData?.playbackPositionTicks, ticks > 0 {
                resumeSeconds = Ticks.seconds(ticks)
            }
            resumeOverride = nil
            incidents.beginAttempt(
                delivery: delivery,
                method: method,
                source: source,
                cached: transportCache != nil || playbackURL.isFileURL,
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
            // Launch-only UI regression hook: enter the first real intro or
            // recap so XCTest can exercise the actual CustomPlayerView
            // countdown and seek. Normal launches never read this path.
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

            // The server's default audio choice (user language preferences
            // applied server-side) maps to the demuxer's per-type 1-based
            // ordinal: embedded streams keep their demux order.
            let embeddedAudio = (source.mediaStreams ?? []).filter { $0.type == "Audio" }
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
                let selectedAudioLanguage = initialAudioOrdinal.flatMap { ordinal in
                    embeddedAudio.indices.contains(ordinal - 1)
                        ? embeddedAudio[ordinal - 1].language
                        : nil
                }
                if subtitleDefaultMode == .system {
                    initialSubtitleOrdinal = Self.systemDefaultSubtitleOrdinal(
                        current: initialSubtitleOrdinal,
                        subtitles: orderedSubtitles,
                        selectedAudioLanguage: selectedAudioLanguage,
                        preferredLanguages: self.preferredSubtitleLanguages
                    )
                } else {
                    initialSubtitleOrdinal = TrackSelectionPolicy.subtitleOrdinal(
                        mode: subtitleDefaultMode,
                        candidates: orderedSubtitles.map(Self.selectionCandidate),
                        serverDefault: initialSubtitleOrdinal,
                        preferredLanguages: self.preferredSubtitleLanguages,
                        selectedAudioLanguage: selectedAudioLanguage
                    )
                }
            }
            // Hands-off soak/bench hook (HEL-148), mirroring
            // `debug.benchSearchTerm`: forces a subtitle language on so a
            // scripted long-film run always has cues to count, independent
            // of whatever this server/account's track preferences resolve
            // to.
            if let language = UserDefaults.standard.string(forKey: "debug.benchSubtitleLanguage"),
               !language.isEmpty {
                if language == "off" {
                    // The system caption preference can turn a track on by
                    // itself; a bench arm that means "no subtitles" has to
                    // say so explicitly.
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
                // Never attach a replacement to the display-layer renderer
                // while an outgoing synchronizer still owns it. Proceeding
                // after the old three-second timeout was the autoplay-only
                // episode-two stall path on Apple TV.
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
            // Episode handoff and delivery fallback replace the engine while
            // the viewer remains in one player session. Carry their chosen
            // speed across that internal swap.
            engine.setRate(self.engine?.rate ?? 1)
            engine.prepare(
                url: playbackURL,
                cacheSession: transportCache,
                disc: discRequest,
                startSeconds: resumeSeconds,
                initialAudioOrdinal: initialAudioOrdinal,
                initialSubtitleOrdinal: initialSubtitleOrdinal,
                audioTrackMetadata: embeddedAudio.map(Self.trackMetadata),
                embeddedSubtitleMetadata: embeddedSubtitles.map(Self.trackMetadata),
                externalSubtitles: externalTracks,
                authorization: client.mediaRequestAuthorization()
            )
            engine.onFinished = { [weak self] in self?.didFinish = true }
            engine.onPlaybackStarted = { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
                self.finishEpisodeHandoff(outcome: "ready")
                self.incidents.playbackReady(engine: engine)
                if playbackURL.isFileURL {
                    self.publishBufferMetrics(cacheSession?.metrics)
                } else {
                    self.startBufferFill(session: cacheSession, engine: engine)
                }
                #if DEBUG
                self.schedulePlaybackStarvationDiagnostics(for: engine)
                self.scheduleRendererRecoveryRegressionHooks(for: engine)
                self.scheduleDeliveryFallbackRegression(for: engine)
                #endif
            }
            engine.onPlaybackCacheFallback = { [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
                self.bufferFillTask?.cancel()
                self.bufferFillTask = nil
                self.playbackCache.discardCurrent(preservingNext: true)
                self.publishBufferMetrics(nil)
            }
            engine.onError = { [weak self, weak engine] failure in
                guard let self, let engine, self.engine === engine else { return }
                self.handleEngineError(failure, engine: engine)
            }
            engine.onTrackSelectionChanged = { [weak self, weak engine] in
                self?.nowPlaying.updateLanguageOptions()
                if let language = engine?.subtitleTracks.first(where: \.isSelected)?.languageTag,
                   let normalized = SubtitlePreferencesStore.normalizedLanguage(language) {
                    // Apple's caption contract asks custom selectors to
                    // feed explicit language choices back to the system's
                    // ordered caption-language preference stack.
                    _ = MACaptionAppearanceAddSelectedLanguage(.user, normalized as CFString)
                }
            }
            playbackIdentity = media.id
            self.engine = engine
            guard let playerInfo else { throw JellyfinError.unplayable }
            nowPlaying.activate(
                info: playerInfo,
                itemID: itemId,
                engine: engine,
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
                playSessionID: info.playSessionId,
                method: method,
                signpostID: performanceSignpostID
            )
            self.reporting = reporting

            #if DEBUG
            // Deterministic UI-test hook for the otherwise tiny interval in
            // which dismissal can race a suspended startup request.
            let startupDelay = UserDefaults.standard.double(
                forKey: "debug.regressionPlaybackStartDelaySeconds"
            )
            if startupDelay > 0 {
                try await Task.sleep(for: .seconds(startupDelay))
            }
            #endif

            do {
                try await reporting.reportStart(at: resumeSeconds)
            } catch is CancellationError {
                // A cover dismissed while this request is suspended must not
                // resume below and recreate progress/HUD/next-up work after
                // `onDisappear` has already torn the session down.
                throw CancellationError()
            } catch {
                // Jellyfin reporting is advisory; a healthy local stream must
                // continue when the server declines or times out this call.
            }
            try Task.checkCancellation()
            guard self.engine === engine, self.reporting === reporting, reporting.isActive else {
                return
            }
            startProgressLoop()
            diagnosticSampler.cacheMetrics = { [weak self] in self?.playbackCache.current?.metrics }
            diagnosticSampler.startTrace(engine: engine) { [weak self] in
                self?.soakExitRequested = true
                self?.soakExitRequestedAt = ContinuousClock.now
            }
            diagnosticSampler.startHUD(
                source: source, method: method, engine: engine,
                context: { [weak self] in
                    guard let self else { return nil }
                    return .init(
                        cache: self.playbackCache.current?.metrics,
                        handoffMilliseconds: self.lastHandoffMilliseconds,
                        fallbackLines: self.deliveryFallbackHUDLines
                    )
                },
                publish: { [weak self] in self?.hudLines = $0 }
            )
            resolveNextUp(after: media, client: client)
        } catch {
            // This also claims the exactly-once stop report if cancellation
            // landed after the playback session became active.
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

    /// Whether a start-path error is the viewer leaving rather than a
    /// failure. A dismissed cover cancels the start task, and a request
    /// suspended in URLSession at that moment surfaces as
    /// `URLError.cancelled` (-999), not `CancellationError`; reported as
    /// is, it filed a `playback.startFailed` at error level for every
    /// back-out during a slow negotiation. The URL error only counts when
    /// the task or the controller was actually cancelled, so a session the
    /// transport tore down on its own still reports.
    nonisolated static func isStartCancellation(_ error: Error, taskCancelled: Bool, closed: Bool) -> Bool {
        if error is CancellationError { return true }
        guard let urlError = error as? URLError, urlError.code == .cancelled else { return false }
        return taskCancelled || closed
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

    private nonisolated static func selectionCandidate(_ stream: MediaStream) -> TrackSelectionCandidate {
        TrackSelectionCandidate(
            language: stream.language,
            isDefault: stream.isDefault == true,
            isOriginal: stream.isOriginal == true,
            isForced: stream.isForced == true,
            isHearingImpaired: stream.isHearingImpaired == true
        )
    }

    /// Seeds a first playback from the system's caption policy without
    /// overriding an explicit in-player choice carried from the last
    /// episode. Jellyfin's own default remains authoritative when present,
    /// except for Forced Only, whose meaning is unambiguous.
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
    /// Debug-only: the paired Apple TV cannot be driven by the
    /// simulator-only regression suite, but must run the identical bounded
    /// HEL-123/124 outages from a Debug build before either renderer-side
    /// conclusion is trusted on hardware.
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
    /// Deterministic integration coverage for events that CoreSimulator
    /// cannot cause by changing a physical HDMI or audio route.
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

    /// Looks up what plays next, off the critical path.
    ///
    /// Deliberately after the engine is running rather than alongside the
    /// negotiation: nothing on screen needs it for another forty minutes,
    /// and `start` is the one place in the app where a round trip costs a
    /// visibly later first frame (HEL-39).
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

    /// Negotiates and warms the successor only near the end of an episode.
    /// Eight MiB is enough to cover container probing and the first playback
    /// cushion without turning an unanswered Up Next card into a large
    /// background download.
    private func prepareNextIfNeeded(force: Bool = false) {
        guard !successorPreparation.hasPreparation,
              let next = nextUp, let client else { return }
        if !force {
            guard let engine, engine.duration > 0,
                  engine.duration - engine.timePosition <= 120 else { return }
        }
        // One proactive download at a time. Cached active-file bytes remain
        // readable while the successor gets priority near the ending.
        bufferFillTask?.cancel()
        bufferFillTask = nil
        successorPreparation.prepare(
            itemID: next.id,
            client: client,
            cache: playbackCache,
            allowsWarming: !isAdvancing,
            playbackState: { [weak engine] in
                guard let engine else { return nil }
                return .init(
                    isBuffering: engine.isBuffering,
                    stallCount: engine.stallCount,
                    isPaused: engine.isPaused
                )
            }
        )
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
        // The old card describes the item that is now becoming current. Do
        // not let it reappear over a successor that resumes near its end.
        nextUp = nil
        didFinish = false
        errorMessage = nil
        // Resume rather than restart: `episodeAfter` walks the series in
        // order, so the next one along can carry a position of its own.
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

    private func publishBufferMetrics(_ metrics: PlaybackCacheMetrics?) {
        bufferedFraction = metrics?.bufferedFraction
        bufferedRanges = metrics?.bufferedRanges ?? []
        playheadPrefetchCount = metrics?.playheadPrefetchCount ?? 0
    }

    /// Proactive fill starts only after the player has presented its initial
    /// cushion and advances in 1 MiB requests. `PlaybackFillPolicy` decides
    /// the pace from the cushion of cached media ahead of the playhead, backs
    /// off after a failed fetch instead of giving up, and gives the link to
    /// the foreground after a stall (HEL-160). Native foreground playback —
    /// not URLSession priority hints — stays the hard priority.
    private func startBufferFill(
        session: PlaybackCacheSession?,
        engine: SampleBufferPlayerEngine
    ) {
        bufferFillTask?.cancel()
        bufferFillTask = nil
        guard let session, session.directScope != nil else {
            publishBufferMetrics(session?.metrics)
            return
        }
        let generation = UUID()
        bufferFillGeneration = generation
        bufferFillTask = Task { [weak self, weak engine] in
            // A finished loop clears its handle so `resumeBufferFill` can
            // start a fresh one; a loop that was replaced leaves the newer
            // handle alone.
            defer {
                if let self, self.bufferFillGeneration == generation {
                    self.bufferFillTask = nil
                }
            }
            do {
                try await Task.sleep(for: .seconds(PlaybackFillPolicy.warmupSeconds))
            } catch {
                return
            }
            var policy = PlaybackFillPolicy()
            var observedStalls = engine?.stallCount ?? 0
            // Only the pre-fetch snapshot consumes a stall: the policy acts
            // on it there, so a stall that lands while a chunk is in flight
            // must survive the post-fetch snapshot and take the cooldown on
            // the next pass instead of being discarded.
            @MainActor func snapshot(
                _ metrics: PlaybackCacheMetrics,
                engine: SampleBufferPlayerEngine,
                consumingStall: Bool = true
            ) -> PlaybackFillPolicy.Snapshot {
                let newStall = engine.stallCount > observedStalls
                if consumingStall { observedStalls = engine.stallCount }
                return .init(
                    isPaused: engine.isPaused,
                    isBuffering: engine.isBuffering,
                    newStall: newStall,
                    aheadSeconds: PlaybackFillPolicy.aheadSeconds(
                        cachedBytesAhead: metrics.cachedBytesAheadOfPlayhead,
                        contentLength: metrics.contentLength,
                        durationSeconds: engine.duration
                    ),
                    averageBytesPerSecond: PlaybackFillPolicy.averageBytesPerSecond(
                        contentLength: metrics.contentLength,
                        durationSeconds: engine.duration
                    ),
                    playbackRate: engine.rate,
                    isWindowed: metrics.isWindowed,
                    bufferedFraction: metrics.bufferedFraction
                )
            }
            while !Task.isCancelled {
                guard let self, let engine,
                      self.engine === engine,
                      self.playbackCache.current === session else { return }

                let before = session.metrics
                self.publishBufferMetrics(before)
                switch policy.beforeFetch(snapshot(before, engine: engine)) {
                case .stop:
                    return
                case .wait(let seconds):
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                    continue
                case .fetch:
                    break
                }

                let outcome = await session.prefetchNextChunk()
                guard !Task.isCancelled,
                      self.engine === engine,
                      self.playbackCache.current === session else { return }
                let after = session.metrics
                self.publishBufferMetrics(after)
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Playback Buffer Progress",
                    signpostID: self.performanceSignpostID,
                    "cachedMB=%{public}.1f totalMB=%{public}.1f prefixFraction=%{public}.3f ranges=%{public}d playheadPrefetches=%{public}d stalls=%{public}d aheadMB=%{public}.1f outcome=%{public}s",
                    Double(after.cachedBytes) / 1_048_576,
                    Double(after.contentLength ?? 0) / 1_048_576,
                    after.bufferedFraction ?? -1,
                    after.bufferedRanges.count,
                    after.playheadPrefetchCount,
                    engine.stallCount,
                    Double(after.cachedBytesAheadOfPlayhead) / 1_048_576,
                    String(describing: outcome)
                )
                switch policy.afterFetch(outcome, snapshot(after, engine: engine, consumingStall: false)) {
                case .stop:
                    return
                case .wait(let seconds):
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                    } catch {
                        return
                    }
                case .fetch:
                    continue
                }
            }
        }
    }

    func suspendBufferFill() {
        bufferFillTask?.cancel()
        bufferFillTask = nil
    }

    func resumeBufferFill() {
        guard bufferFillTask == nil,
              !successorPreparation.isPreparing,
              let engine else { return }
        startBufferFill(session: playbackCache.current, engine: engine)
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

    /// Performs every resource-owning part of dismissal synchronously on the
    /// main actor. The Jellyfin report is returned as an independent task so
    /// neither UI dismissal nor its network latency retains this controller.
    @discardableResult
    func beginStop(
        preservingPreparedNext: Bool = false,
        preservingPlayerSurface: Bool = false
    ) -> Task<Void, Never>? {
        reporting?.cancelProgress()
        diagnosticSampler.stop()
        bufferFillTask?.cancel()
        bufferFillTask = nil
        nextUpTask?.cancel()
        nextUpTask = nil
        if !preservingPreparedNext {
            successorPreparation.cancel()
        }
        subtitleSearch.detach()
        let seconds = engine?.timePosition ?? lastKnownPosition
        lastKnownPosition = seconds
        incidents.endAttempt(engine: engine, outcome: stopOutcome)

        // Keep the dismissal-critical main-actor phase measurable and tiny.
        // The engine now serializes renderer flushing and queued-buffer
        // release on its existing pump queue (HEL-57).
        os_signpost(
            .begin,
            log: PlaybackPerformance.log,
            name: "Dismiss Main Actor Cleanup",
            signpostID: performanceSignpostID
        )
        if let engine {
            engine.onFinished = nil
            engine.onError = nil
            engine.onTrackSelectionChanged = nil
            engine.onPlaybackStarted = nil
            engine.onPlaybackCacheFallback = nil
            engine.shutdown()
            if !preservingPlayerSurface {
                self.engine = nil
            }
        }
        playbackCache.discardCurrent(preservingNext: preservingPreparedNext)
        publishBufferMetrics(nil)
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

    /// Terminal view dismissal. Unlike the internal episode-to-episode stop,
    /// this prevents any suspended preparation/report task from resurrecting
    /// an engine after the full-screen cover has gone away.
    @discardableResult
    func close() -> Task<Void, Never>? {
        isClosed = true
        guard let soakExitRequestedAt else { return beginStop() }
        // HEL-148 soak diagnostic: `soakExitRequestedAt` is only ever set by
        // the (decodeTrace-gated) soak-exit hook, so this print needs no
        // separate gate. `closeMs` is `beginStop()` alone; `sinceRequestMs`
        // is the whole exit, from the soak hook's request to here.
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
        // Stop reporting and local teardown are independent. Await them in
        // parallel so a slow Jellyfin response does not add to the renderer
        // retirement latency, while still preserving report-before-start.
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
            // This engine has said its piece; anything it reports from here
            // belongs to a session that is already being torn down.
            engine.onError = nil
            Task { await self.fallBack(to: next, after: failure) }
            return
        }
        finishEpisodeHandoff(outcome: "failed")
        incidents.endAttempt(engine: engine, outcome: "failed")
        let report = beginStop()
        errorMessage = failure.message
        // beginStop claims reporting ownership before returning, so a later
        // onDisappear remains idempotent while this fire-and-forget task runs.
        _ = report
    }

    #if DEBUG
    /// Fails the first negotiated attempt on purpose so the delivery ladder
    /// can be walked without a broken file. The fallback only ever runs when
    /// something is already wrong, which makes it exactly the path that never
    /// gets exercised in ordinary use.
    ///
    /// `debug.regressionFailFirstDelivery` is `delivery` (expect the cheap
    /// remux rung) or `undecodable` (expect the transcode rung, remux
    /// skipped). Injected after playback starts so the retry has a real
    /// position to resume from.
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

    /// Records a rung the ladder stepped past without trying it, so the
    /// HUD's `Rung:`/`Fell n:` lines still account for where playback ended
    /// up. `fallBack` cannot serve here: nothing has started yet, so there is
    /// no engine to retire and no position to resume from.
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

    /// Asks the server to deliver the same media a different way and starts
    /// over where the failure landed (HEL-100).
    ///
    /// The viewer sees the player reload rather than an error, so the rungs
    /// are worth their latency only because the alternative is the film
    /// ending here. Each rung is entered at most once — `next` only ever
    /// moves downward — so a stream that fails every way still terminates in
    /// the overlay.
    private func fallBack(to next: PlaybackDelivery, after failure: PlaybackEngineFailure) async {
        // Held across the restart as well: a failure arriving while the next
        // attempt is still starting up takes the terminal path rather than
        // tearing down an engine that is mid-flight. That is today's
        // behaviour for a rare race, never worse than it.
        defer { isFallingBack = false }
        guard !isClosed, let client, let media = currentMedia else { return }
        let resumeAt = engine?.timePosition ?? lastKnownPosition
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
        // Same teardown the episode handoff uses, and for the same reason:
        // keeping the display layer mounted lets the successor attach to the
        // surface that is already there. Tearing it down instead left the
        // outgoing renderer set registered as attached — its removal
        // completion never fired once SwiftUI had destroyed the layer under
        // it — and the retirement wait then timed out every single time.
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
            prepared: nil
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

    /// What the diagnostics history calls the end of an attempt. A failure
    /// is recorded by its own path before this runs.
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

    /// Why this rung is in force, and nothing at all when it is the one the
    /// server picked unaided — the `Method:` line above already says that,
    /// and a ladder that never ran has nothing to explain.
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
