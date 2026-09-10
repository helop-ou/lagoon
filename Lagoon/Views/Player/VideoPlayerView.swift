import MediaAccessibility
import Observation
import OSLog
import SwiftUI
import UIKit

private enum PlaybackStartError: LocalizedError {
    case previousEngineDidNotRetire

    var errorDescription: String? {
        switch self {
        case .previousEngineDidNotRetire:
            "The previous video could not release its player resources. Close the player and try again."
        }
    }
}

/// Identifiable wrapper so `fullScreenCover(item:)` can present playback.
nonisolated struct PlayerItem: Identifiable {
    let id = UUID()
    let media: MediaItem
    var startFromBeginning = false
}

private let reportLog = Logger(subsystem: "ee.helop.lagoon", category: "playback-reports")

/// HEL-148 soak diagnostic: milliseconds for a `Duration`, shared by the
/// DecodeTrace loop's `mainLateMs`/`pumpMs`/`Soak*` lines.
private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// HEL-148 soak diagnostic: holds the DecodeTrace loop's pump-queue ping
/// result. A box rather than a local var because the callback that fills it
/// runs on the main actor a tick later than the print that reads it.
@MainActor
private final class PumpPing {
    var lastMs: Double = -1
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

    /// The episode queued behind this one, resolved once at start so the Up
    /// Next card can appear the instant the credits do (HEL-66). Nil for
    /// movies and at the end of a series.
    private(set) var nextUp: MediaItem?

    private(set) var hudLines: [String] = []
    private var hudTask: Task<Void, Never>?
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
    private var playSessionId: String?
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
    private var progressTask: Task<Void, Never>?
    private var decodeTraceTask: Task<Void, Never>?
    private var bufferFillTask: Task<Void, Never>?
    private var didReportStop = false
    private var playbackSessionActive = false
    /// Mirrors `playbackSessionActive` in `client.playbackReports`, so the
    /// screen underneath can wait for the stop report before it re-fetches
    /// (HEL-132).
    private var reportLedgerSession: UUID?
    private var isClosed = false
    private var lastKnownPosition: Double = 0
    private var nextUpTask: Task<Void, Never>?
    private var nextPreparationTask: Task<PreparedNextPlayback?, Never>?
    /// The successor's byte warm-up, held separately from the preparation
    /// task around it so an accepted Up Next offer can end the trickle
    /// without discarding the negotiation it is nested in (HEL-144).
    private var nextWarmTask: Task<Void, Never>?
    private var preparedNext: PreparedNextPlayback?
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

    private struct PreparedNextPlayback {
        let mediaID: String
        let info: PlaybackInfoResponse
        let source: MediaSource
        let streamURL: URL
        let method: PlayMethod
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
        prepared: PreparedNextPlayback?
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
        do {
            // Chapters and trickplay ride alongside the negotiation rather
            // than after it — neither is in PlaybackInfo, and waiting for a
            // second round trip would delay the first frame (HEL-39).
            async let extras = client.playbackExtras(itemId: media.id)
            async let segments = client.mediaSegments(itemId: media.id)
            let info: PlaybackInfoResponse
            let source: MediaSource
            let streamURL: URL
            let method: PlayMethod
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
            mediaSourceId = source.id
            playSessionId = info.playSessionId
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
            let cacheSession = playbackCache.activate(
                itemID: media.id,
                url: streamURL,
                method: method,
                expectedLength: source.size,
                authorization: client.mediaRequestAuthorization()
            )
            let playbackURL = cacheSession?.completeFileURL ?? streamURL
            let transportCache = !playbackURL.isFileURL
                && PlaybackBufferPolicy.customIOEnabled(for: method)
                ? cacheSession
                : nil
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
            playbackSessionActive = true
            reportLedgerSession = client.playbackReports.open()

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
                try await client.reportPlaybackStart(.init(
                    itemId: itemId,
                    mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId,
                    positionTicks: Ticks.ticks(resumeSeconds),
                    playMethod: playMethod.rawValue,
                    canSeek: true
                ))
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
            guard self.engine === engine, playbackSessionActive, !didReportStop else {
                return
            }
            startProgressLoop()
            startDecodeTrace()
            startHUD(source: source, method: method)
            resolveNextUp(after: media, client: client)
        } catch {
            // This also claims the exactly-once stop report if cancellation
            // landed after the playback session became active.
            finishEpisodeHandoff(outcome: error is CancellationError ? "cancelled" : "failed")
            _ = beginStop()
            if !(error is CancellationError) {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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
        nextPreparationTask?.cancel()
        nextPreparationTask = nil
        nextWarmTask?.cancel()
        nextWarmTask = nil
        preparedNext = nil
        playbackCache.discardNext()
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
        guard preparedNext == nil, nextPreparationTask == nil,
              let next = nextUp, let client else { return }
        if !force {
            guard let engine, engine.duration > 0,
                  engine.duration - engine.timePosition <= 120 else { return }
        }
        // One proactive download at a time. The active file remains readable
        // from everything already cached while the final two minutes give
        // the successor's startup bytes priority.
        bufferFillTask?.cancel()
        bufferFillTask = nil
        nextPreparationTask = Task { [weak self] in
            guard let self else { return nil }
            defer { self.nextPreparationTask = nil }
            do {
                let info = try await client.playbackInfo(itemId: next.id)
                guard !Task.isCancelled,
                      info.errorCode == nil,
                      let source = info.mediaSources.first else { return nil }
                // Warming a disc would download the opening megabytes of an
                // image nothing here can read, and the successor negotiates
                // its own rung when it starts anyway (HEL-133).
                let layout = PlaybackSourceLayout(
                    videoType: source.videoType,
                    isoType: source.isoType
                )
                guard !layout.isDisc else { return nil }
                let (url, method) = try client.streamURL(itemId: next.id, source: source)
                guard !Task.isCancelled, self.nextUp?.id == next.id else { return nil }
                let scope = self.playbackCache.stageNext(
                    itemID: next.id,
                    url: url,
                    method: method,
                    expectedLength: source.size,
                    authorization: client.mediaRequestAuthorization()
                )
                // The warm-up runs in a task of its own so an advance can end
                // it without cancelling the preparation around it: what the
                // handoff needs from here is the negotiated source and the
                // staged scope, not a full cushion (HEL-144).
                if !self.isAdvancing {
                    let warm = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.warmPreparedNext(scope, byteCount: 8 * 1_024 * 1_024)
                    }
                    self.nextWarmTask = warm
                    await warm.value
                    self.nextWarmTask = nil
                }
                guard !Task.isCancelled, self.nextUp?.id == next.id else {
                    self.playbackCache.discardNext(itemID: next.id)
                    return nil
                }
                let prepared = PreparedNextPlayback(
                    mediaID: next.id,
                    info: info,
                    source: source,
                    streamURL: url,
                    method: method
                )
                self.preparedNext = prepared
                return prepared
            } catch {
                return nil
            }
        }
    }

    /// Warms a successor in the same cooperative 1 MiB slices as the active
    /// title. This avoids the old eight-megabyte burst during credits—the
    /// exact window in which autoplay stalls were previously reproducible.
    private func warmPreparedNext(
        _ session: PlaybackCacheSession?,
        byteCount: Int64
    ) async {
        guard let session, session.directScope != nil, byteCount > 0 else { return }
        let startingBytes = session.metrics.contiguousCachedBytes
        var observedStalls = engine?.stallCount ?? 0
        while !Task.isCancelled,
              session.metrics.contiguousCachedBytes - startingBytes < byteCount {
            guard let engine else { return }
            if engine.isBuffering || engine.stallCount > observedStalls {
                observedStalls = engine.stallCount
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continue
            }
            let before = session.metrics
            guard await session.prefetchNextChunk() else { return }
            let after = session.metrics
            guard !Task.isCancelled else { return }
            if !engine.isPaused {
                let requestSeconds = max(
                    after.networkRequestSeconds - before.networkRequestSeconds,
                    0.125
                )
                do {
                    try await Task.sleep(for: .seconds(min(requestSeconds * 4, 8)))
                } catch {
                    return
                }
            }
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
        beginEpisodeHandoff(to: next)
        prepareNextIfNeeded(force: true)
        // The warm-up exists to make *this* moment instant; it is not
        // something to sit out once the moment has arrived. Its cooperative
        // pacing spreads eight MiB over tens of seconds on a slow server,
        // and the viewer is already watching a spinner. `isAdvancing` covers
        // a warm that has not started yet (HEL-144).
        nextWarmTask?.cancel()
        let prepared = await nextPreparationTask?.value
        nextPreparationTask = nil
        nextWarmTask = nil
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
            preparedNext = nil
            _ = beginStop()
            errorMessage = PlaybackStartError.previousEngineDidNotRetire.errorDescription
            return
        }
        guard !isClosed else { return }
        // The old card describes the item that is now becoming current. Do
        // not let it reappear over a successor that resumes near its end.
        nextUp = nil
        didFinish = false
        didReportStop = false
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
        preparedNext = nil
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
    /// cushion. It advances in 1 MiB requests, yields between every request,
    /// and enters a long cooldown after any renderer stall. That makes native
    /// foreground playback—not URLSession priority hints—the hard priority.
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
        bufferFillTask = Task { [weak self, weak engine] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            var observedStalls = engine?.stallCount ?? 0
            while !Task.isCancelled {
                guard let self, let engine,
                      self.engine === engine,
                      self.playbackCache.current === session else { return }

                let before = session.metrics
                self.publishBufferMetrics(before)
                // A title that fits under the cap finishes and the loop ends.
                // A larger one is buffered through a window that travels with
                // the playhead, so reaching capacity is its steady state, not
                // its end: the loop has to keep running for the whole title.
                if before.bufferedFraction == 1 {
                    return
                }

                if engine.isBuffering || engine.stallCount > observedStalls {
                    observedStalls = engine.stallCount
                    do {
                        try await Task.sleep(for: .seconds(20))
                    } catch {
                        return
                    }
                    continue
                }

                let advanced = await session.prefetchNextChunk()
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
                    "cachedMB=%{public}.1f totalMB=%{public}.1f prefixFraction=%{public}.3f ranges=%{public}d playheadPrefetches=%{public}d stalls=%{public}d",
                    Double(after.cachedBytes) / 1_048_576,
                    Double(after.contentLength ?? 0) / 1_048_576,
                    after.bufferedFraction ?? -1,
                    after.bufferedRanges.count,
                    after.playheadPrefetchCount,
                    engine.stallCount
                )
                if !advanced {
                    // Nothing to fetch right now. For a windowed cache that
                    // means the read-ahead is full and the loop waits for the
                    // playhead to make room rather than giving up on the rest
                    // of the movie.
                    guard after.isWindowed else { return }
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    continue
                }

                if !engine.isPaused {
                    // Keep proactive traffic at roughly <=20% of the link
                    // time it just measured. A paused viewer gets full-speed
                    // fill because no foreground demux request is consuming.
                    let requestSeconds = max(
                        after.networkRequestSeconds - before.networkRequestSeconds,
                        0.125
                    )
                    do {
                        try await Task.sleep(for: .seconds(min(requestSeconds * 4, 8)))
                    } catch {
                        return
                    }
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
              nextPreparationTask == nil,
              let engine else { return }
        startBufferFill(session: playbackCache.current, engine: engine)
    }

    func updateNowPlayingTimeline() {
        nowPlaying.updateTimeline()
    }

    /// A console time series of the software decode path, every two seconds
    /// (HEL-137).
    ///
    /// The HUD shows the same numbers, but a HUD reading is one glance at one
    /// moment, and the question this ticket is stuck on is a *curve*: cost per
    /// frame climbs from 31 ms to past the 41.7 ms budget within half a
    /// minute, and whether the queue depth and footprint move with it is what
    /// separates memory pressure from heat from scene complexity. Reading that
    /// off a television by eye loses exactly the correlation that matters.
    ///
    /// `devicectl ... --console` streams this from a real Apple TV, where the
    /// unified log is out of reach. Off unless `-debug.decodeTrace YES`.
    private func startDecodeTrace() {
        guard UserDefaults.standard.bool(forKey: "debug.decodeTrace") else { return }
        decodeTraceTask = Task { [weak self] in
            let cpuTrace = ProcessCPUTrace()
            let pumpPing = PumpPing()
            // HEL-148 soak hooks: a hands-off pause/resume and a hands-off
            // exit at fixed media-time positions, each off (0) unless set.
            // Read once so a value that changes mid-soak (it shouldn't)
            // can't retrigger either one.
            let soakPauseAtSeconds = UserDefaults.standard.double(forKey: "debug.soakPauseAtSeconds")
            let soakExitAtSeconds = UserDefaults.standard.double(forKey: "debug.soakExitAtSeconds")
            var didSoakPause = false
            var didSoakExit = false
            while !Task.isCancelled {
                // HEL-148 soak diagnostic: overshoot past the requested 2 s
                // sleep is time the main actor was unavailable to resume
                // this task — this loop runs on the main actor because it
                // was created inside `PlaybackController`, a `@MainActor`
                // type.
                let sleepStart = ContinuousClock.now
                try? await Task.sleep(for: .seconds(2))
                let mainLateMs = max(0, ms(ContinuousClock.now - sleepStart) - 2_000)
                guard let self, let engine = self.engine else { return }
                // Whether frames take the direct-display path or are being
                // composited with UI — readable here with the HUD off, which
                // the HUD itself never could be (HEL-137).
                engine.refreshVideoPerformanceMetrics()
                let performance = engine.videoPerformance
                let memory = MemorySnapshot.current()
                let depths = engine.queueDepths
                // Last tick's completed pump-queue ping; the one fired below
                // lands in time for the next tick to read.
                let lastPumpMs = pumpPing.lastMs
                let thermalName: String
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: thermalName = "nominal"
                case .fair: thermalName = "fair"
                case .serious: thermalName = "serious"
                case .critical: thermalName = "critical"
                @unknown default: thermalName = "unknown"
                }
                // The renderer-side audio signal (HEL-123) rides on the same
                // line, so a device console can correlate it with position
                // and the queues without the HUD or the accessibility probe.
                var trace = "DecodeTrace"
                    + String(format: " position=%.2f", engine.timePosition)
                    + " video=\(engine.videoQueueCountDiagnostic)/\(engine.maximumVideoBacklogDiagnostic)/\(engine.videoQueueHardLimitDiagnostic)"
                    + " intake=\(engine.videoIntakeCountDiagnostic)/\(engine.maximumVideoIntakeDiagnostic)"
                    + " audio=\(depths.audio)"
                    + String(format: " lead=%.3f", engine.audioDeliveryLeadSeconds)
                    + " ready=\(engine.audioRendererReadyForPlayback ? 1 : 0)"
                    + " buffering=\(engine.isBuffering ? 1 : 0)"
                    + " aDry=\(engine.audioStarvationCount)"
                    + String(format: " footprintMB=%.1f availableMB=%.1f",
                        memory.footprintMB, memory.availableMB)
                    + " stalls=\(engine.stallCount) audioStalls=\(engine.audioStallCount)"
                    + " reprimes=\(engine.stallReprimeCount)"
                    + " shown=\(performance?.totalFrames ?? -1)"
                    + " opt=\(performance?.optimizedCompositingFrames ?? -1)"
                    + " dropped=\(performance?.droppedFrames ?? -1)"
                    + " swdec=\"\(engine.softwareDecodeBenchField ?? "n/a")\""
                    // HEL-148 soak diagnostics: main-actor scheduling
                    // latency, pump-queue ping, the 10 Hz tick summary,
                    // subtitle cue count, renderer observer count, thermal
                    // state — everything the 100-minute soak needs to show
                    // whether the engine degrades over a long film.
                    + String(format: " mainLateMs=%.0f pumpMs=%.1f", mainLateMs, lastPumpMs)
                    + " \(engine.drainMainTickDiagnostic())"
                    + " cues=\(engine.subtitleCueCountDiagnostic)"
                    + " observers=\(engine.rendererObserverCountDiagnostic)"
                    + " thermal=\(thermalName)"
                #if os(tvOS)
                // Whether the display actually matched the content: a
                // 60 Hz SDR mode left in place makes the compositor
                // cadence-convert and tone-map every HDR frame, which is
                // the standing suspect for the composited-path drops.
                trace += " display=\"\(DisplayModeMatcher.statusDescription)"
                    + " · \(UIScreen.main.maximumFramesPerSecond) Hz\""
                #endif
                #if DEBUG
                trace += " audioHeld=\(engine.audioDeliverySuspendedForDiagnostics ? 1 : 0)"
                    + " deliveryHeld=\(engine.demuxDeliverySuspendedForDiagnostics ? 1 : 0)"
                #endif
                print(trace)
                print(cpuTrace.tick())
                engine.measurePumpQueueLatency { duration in
                    Task { @MainActor in pumpPing.lastMs = ms(duration) }
                }

                if soakPauseAtSeconds > 0, !didSoakPause,
                   engine.timePosition >= soakPauseAtSeconds, !engine.isPaused {
                    didSoakPause = true
                    let pauseStart = ContinuousClock.now
                    engine.pause()
                    print(String(
                        format: "SoakPause position=%.2f pauseCallMs=%.1f",
                        engine.timePosition, ms(ContinuousClock.now - pauseStart)
                    ))
                    try? await Task.sleep(for: .seconds(5))
                    let resumeStart = ContinuousClock.now
                    engine.play()
                    print(String(
                        format: "SoakResume position=%.2f playCallMs=%.1f",
                        engine.timePosition, ms(ContinuousClock.now - resumeStart)
                    ))
                }
                if soakExitAtSeconds > 0, !didSoakExit, engine.timePosition >= soakExitAtSeconds {
                    didSoakExit = true
                    self.soakExitRequested = true
                    self.soakExitRequestedAt = ContinuousClock.now
                    print(String(format: "SoakExit requested position=%.2f", engine.timePosition))
                }
            }
        }
    }

    private func startProgressLoop() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, let client = self.client, let engine = self.engine else { return }
                self.lastKnownPosition = engine.timePosition
                self.nowPlaying.updateTimeline()
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
                self.prepareNextIfNeeded()
            }
        }
    }

    /// Performs every resource-owning part of dismissal synchronously on the
    /// main actor. The Jellyfin report is returned as an independent task so
    /// neither UI dismissal nor its network latency retains this controller.
    @discardableResult
    func beginStop(
        preservingPreparedNext: Bool = false,
        preservingPlayerSurface: Bool = false
    ) -> Task<Void, Never>? {
        progressTask?.cancel()
        decodeTraceTask?.cancel()
        decodeTraceTask = nil
        progressTask = nil
        hudTask?.cancel()
        hudTask = nil
        bufferFillTask?.cancel()
        bufferFillTask = nil
        nextUpTask?.cancel()
        nextUpTask = nil
        if !preservingPreparedNext {
            nextPreparationTask?.cancel()
            nextPreparationTask = nil
            nextWarmTask?.cancel()
            nextWarmTask = nil
            preparedNext = nil
        }
        subtitleSearch.detach()
        let seconds = engine?.timePosition ?? lastKnownPosition
        lastKnownPosition = seconds

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

        guard let client, playbackSessionActive, !didReportStop else { return nil }
        didReportStop = true
        playbackSessionActive = false
        let ledgerSession = reportLedgerSession
        reportLedgerSession = nil
        let itemId = itemId
        let mediaSourceId = mediaSourceId
        let playSessionId = playSessionId
        let signpostID = performanceSignpostID
        return Task {
            os_signpost(
                .begin,
                log: PlaybackPerformance.log,
                name: "Playback Stopped Report",
                signpostID: signpostID
            )
            do {
                try await client.reportPlaybackStopped(.init(
                    itemId: itemId,
                    mediaSourceId: mediaSourceId,
                    playSessionId: playSessionId,
                    positionTicks: Ticks.ticks(seconds)
                ))
                reportLog.notice("stopped at \(seconds, format: .fixed(precision: 1)) s reported")
            } catch {
                // Advisory, like every other report — but the one that moves
                // the resume point, so a failure is worth a line.
                reportLog.error("stopped report failed: \(error.localizedDescription, privacy: .public)")
            }
            os_signpost(
                .end,
                log: PlaybackPerformance.log,
                name: "Playback Stopped Report",
                signpostID: signpostID
            )
            // Whether the report landed or failed, the server's answer is
            // final now; let the screen underneath re-fetch.
            if let ledgerSession {
                client.playbackReports.close(ledgerSession)
            }
        }
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
        if !isClosed, !isFallingBack, currentMedia != nil, client != nil,
           let next = PlaybackFallbackPolicy.next(after: delivery, cause: failure.cause) {
            isFallingBack = true
            // This engine has said its piece; anything it reports from here
            // belongs to a session that is already being torn down.
            engine.onError = nil
            Task { await self.fallBack(to: next, after: failure) }
            return
        }
        finishEpisodeHandoff(outcome: "failed")
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
        didReportStop = false
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
            if let width = video.width, let height = video.height {
                let bitDepth = video.bitDepth ?? (video.videoRangeType == "SDR" ? 8 : 10)
                let frameMB = Double(DecodedFrameMemory.bytesPer420Frame(
                    width: width,
                    height: height,
                    bitDepth: bitDepth
                )) / 1_048_576
                let hardQueueMB = Double(DecodedFrameMemory.queuedBytes(
                    width: width,
                    height: height,
                    bitDepth: bitDepth,
                    frames: DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: true)
                )) / 1_048_576
                negotiated.append(String(
                    format: "Surface: %.1f MB/frame · %.0f MB app hard queue",
                    frameMB,
                    hardQueueMB
                ))
            }
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
                var live = Self.liveHUDLines(
                    for: engine,
                    cache: self.playbackCache.current?.metrics
                )
                if let milliseconds = self.lastHandoffMilliseconds {
                    live.insert(String(format: "Handoff: %.0f ms to ready", milliseconds), at: 0)
                }
                self.hudLines = negotiated + live + self.deliveryFallbackHUDLines
            }
        }
    }

    private func beginEpisodeHandoff(to next: MediaItem) {
        guard handoffStartedAt == nil else { return }
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

    private static func liveHUDLines(
        for engine: SampleBufferPlayerEngine,
        cache: PlaybackCacheMetrics?
    ) -> [String] {
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
        // App-side count/seconds explain demux backpressure. `lead` is the
        // separate renderer-side starvation signal: media already handed to
        // AVFoundation beyond the clock, which stays positive after Lagoon's
        // own queue drains to zero (HEL-123). `+cur/peak` is compressed video
        // parked in the intake, past the decoded limit, waiting for the
        // demuxer to reach it again (HEL-124).
        lines.append(String(
            format: "Queues:  V %d/%d/%d +%d/%d · A %d/%d (%.1fs) · lead %.2fs ready%d · stalls %d (%d audio) · reprime %d · aDry %d · aGaps %d",
            engine.videoQueueCountDiagnostic,
            engine.maximumVideoBacklogDiagnostic,
            engine.videoQueueHardLimitDiagnostic,
            engine.videoIntakeCountDiagnostic,
            engine.maximumVideoIntakeDiagnostic,
            depths.audio,
            engine.audioCushionTarget,
            engine.audioBufferedSeconds,
            engine.audioDeliveryLeadSeconds,
            engine.audioRendererReadyForPlayback ? 1 : 0,
            engine.stallCount,
            engine.audioStallCount,
            engine.stallReprimeCount,
            engine.audioStarvationCount,
            engine.audioTimingGapCount
        ))
        #if DEBUG
        if engine.audioDeliverySuspendedForDiagnostics
            || engine.demuxDeliverySuspendedForDiagnostics {
            lines.append(
                "Fault: audio \(engine.audioDeliverySuspendedForDiagnostics ? "held" : "live")"
                    + " · delivery \(engine.demuxDeliverySuspendedForDiagnostics ? "held" : "live")"
            )
        }
        #endif
        // Audio thrown away in the demuxer, which no other counter can show:
        // dropped packets never reach the renderer, so aGaps above reads 0
        // through exactly the failure this line exists to catch.
        if let drops = engine.audioPacketDropInfo {
            lines.append("AudDrop: \(drops)")
        }
        // Only once something has actually been rebuilt. A renderer that
        // failed and was replaced leaves no other trace — playback simply
        // carries on, which is the point (HEL-101).
        if engine.audioRendererRecoveryCount > 0 || engine.mediaServicesResetRecoveryCount > 0 {
            lines.append(
                "Recovery: audio ×\(engine.audioRendererRecoveryCount) · service ×\(engine.mediaServicesResetRecoveryCount)"
            )
        }
        if let cache {
            if let fraction = cache.bufferedFraction,
               let contentLength = cache.contentLength {
                lines.append(String(
                    format: "Buffer:  %.1f/%.1f MB · %.0f%% prefix · %d ranges · %d playhead fills",
                    Double(cache.cachedBytes) / 1_048_576,
                    Double(contentLength) / 1_048_576,
                    fraction * 100,
                    cache.bufferedRanges.count,
                    cache.playheadPrefetchCount
                ))
            }
            lines.append(String(
                format: "Cache:   %.1f/%.0f MB · %.0f%% hit · %d req · %.0fms avg · %d res · %d evict",
                Double(cache.cachedBytes) / 1_048_576,
                Double(cache.capacityBytes) / 1_048_576,
                cache.hitRate * 100,
                cache.requestCount,
                cache.averageRequestMilliseconds,
                cache.resourceCount,
                cache.evictionCount
            ))
        }
        if let videoTiming = engine.videoTimingDiagnostic {
            lines.append("Vtime:   \(videoTiming)")
        }
        // Where the software path's frame budget goes, split three ways so a
        // slow one can be attributed rather than guessed at (HEL-137). Each
        // percentage is a share of one core on its own queue; they overlap,
        // so they are not meant to sum.
        if let software = engine.softwareDecodeDiagnostic {
            lines.append("SWdec:   \(software)")
        }
        if let dovi = engine.dolbyVisionRewriteInfo {
            lines.append("DoVi P7: \(dovi)")
        }
        #if os(tvOS)
        // Every gate between the request and the glass. Lagoon always asks;
        // the system's Match Content setting remains the user's authority.
        if let request = engine.displayMatchRequest {
            lines.append(String(
                format: "Display: request %.3f Hz · %@",
                Double(request.frameRate),
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
                    + " · opt \(metrics.optimizedCompositingFrames)"
                    + String(format: " · delay %.0fms", metrics.accumulatedFrameDelay * 1000)
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
    @State private var pictureInPicture = SampleBufferPictureInPicture()
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    @State private var panelOpen = false
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
                    playbackIdentity: controller.playbackIdentity,
                    playerSurfaceIdentity: controller.playerSurfaceIdentity,
                    handoffMilliseconds: controller.lastHandoffMilliseconds,
                    playbackMethod: controller.activePlayMethod,
                    deliveryRung: controller.activeDeliveryRung,
                    isPlaybackCacheActive: controller.isPlaybackCacheActive,
                    bufferedFraction: controller.bufferedFraction,
                    bufferedRanges: controller.bufferedRanges,
                    playheadPrefetchCount: controller.playheadPrefetchCount,
                    info: fallbackInfo,
                    onDismiss: { dismiss() },
                    onPanelToggle: { panelOpen = $0 },
                    nextUp: nextUpEpisode,
                    onPlayNext: { advance() },
                    onCancelNextUp: { autoplayCancelled = true },
                    isPictureInPicturePossible: pictureInPicture.isPossible,
                    isPictureInPictureActive: pictureInPicture.isActive,
                    onTogglePictureInPicture: { pictureInPicture.toggle() },
                    subtitleStyle: subtitlePreferences.renderStyle,
                    subtitleSearch: controller.subtitleSearch
                ) { [weak engine] in
                    // Weak for the same reason the player views hold the
                    // engine through `PlayerEngineRef` (HEL-152): SwiftUI
                    // keeps copies of `CustomPlayerView`, this closure
                    // included, past the next episode handoff, and a strong
                    // capture here would pin the outgoing engine just as the
                    // view's own field did. The controller has the engine
                    // for every body evaluation that actually builds the
                    // surface, so the `nil` branch is never what is shown.
                    if let engine {
                        SampleBufferVideoSurface(engine: engine) { displayLayer in
                            let identity = String(ObjectIdentifier(displayLayer).hashValue)
                            Task { @MainActor in
                                controller.recordPlayerSurface(identity: identity)
                            }
                            pictureInPicture.attach(displayLayer: displayLayer, engine: engine)
                        }
                    }
                }
            } else {
                LoadingView()
            }

            if !controller.hudLines.isEmpty, !panelOpen {
                playbackHUD
            }

            // Keep CustomPlayerView and, critically, its UIKit-backed
            // AVSampleBufferDisplayLayer mounted while the old renderer set
            // retires and the successor attaches. The cover therefore never
            // flashes back to its presenting view between episodes.
            if controller.isTransitionOverlayVisible, controller.errorMessage == nil {
                episodeTransition
            }

            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debug.playerRegression"),
               let bench = controller.hudLines.first(where: { $0.hasPrefix("Bench:") }) {
                Text("Frame-loss regression")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Frame-loss regression")
                    .accessibilityValue(bench)
                    .accessibilityIdentifier("player.regression.frameLoss")
                    .allowsHitTesting(false)
            }
            #endif
        }
        .interactiveDismissDisabled()
        .task {
            subtitlePreferences.configure(accountID: session.activeAccount?.id)
            trackPreferences.configure(accountID: session.activeAccount?.id)
            await controller.start(
                media: playerItem.media,
                startFromBeginning: playerItem.startFromBeginning,
                client: session.client,
                trackPreferences: trackPreferences.values,
                preferredAudioLanguages: trackPreferences.preferredAudioLanguages,
                preferredSubtitleLanguages: subtitlePreferences.preferredLanguages,
                missingSubtitleMode: subtitlePreferences.values.missingMode
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
            } else if !controller.isAdvancing {
                // `.card` means never acting alone, so an offer that went
                // unanswered closes the player exactly as `.off` does.
                // An *accepted* offer is a different thing: the file can run
                // out while the successor is still being prepared, and
                // dismissing there tears down a handoff the viewer asked for
                // and drops them back on the browse screen (HEL-144).
                dismiss()
            }
        }
        .onChange(of: controller.engine?.displayMatchRequest) { _, request in
            // A shutting-down engine temporarily has no successor criteria.
            // Preserve the current display mode until the next engine can
            // state its own request, avoiding an unnecessary HDMI mode round
            // trip at every episode boundary.
            if request != nil || !controller.isAdvancing {
                applyDisplayMatch(request)
            }
        }
        .onChange(of: controller.errorMessage) { _, message in
            if message != nil {
                applyDisplayMatch(nil)
            }
        }
        .onChange(of: controller.engine?.isPaused) { _, _ in
            pictureInPicture.invalidatePlaybackState()
        }
        .onChange(of: controller.engine?.rate) { _, _ in
            pictureInPicture.invalidatePlaybackState()
            controller.updateNowPlayingTimeline()
        }
        .onChange(of: controller.engine?.duration) { _, _ in
            pictureInPicture.invalidatePlaybackState()
        }
        // Backgrounding mid-playback must hand the display back — the
        // home screen has no business running at the content's mode — and
        // returning re-requests it (HEL-64).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                controller.suspendBufferFill()
                applyDisplayMatch(nil)
                if !pictureInPicture.isActive,
                   !pictureInPicture.isTransitioning,
                   !controller.isExternalPlaybackRouteActive {
                    controller.engine?.pause()
                }
            case .inactive:
                // Control Center, route pickers, permission alerts, and the
                // first phase of automatic PiP all make a scene inactive.
                // None means the user asked playback to stop — and the
                // display is deliberately *kept* for the same reason. Handing
                // it back here cost two HDMI renegotiations for an overlay
                // that never interrupted the film: the TV blanked to its idle
                // mode on the way in and blanked again re-matching on the way
                // out. Only `.background` releases it. AVPlayerViewController,
                // which DisplayModeMatcher hand-rolls, does not blink here
                // either; nothing in preferredDisplayCriteria asks it to.
                break
            case .active:
                subtitlePreferences.refreshSystemAppearance()
                controller.resumeBufferFill()
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
        // HEL-148 soak hook (debug.soakExitAtSeconds): the film reached the
        // configured position, so leave through the same clean teardown
        // path a real exit takes.
        .onChange(of: controller.soakExitRequested) { _, requested in
            if requested {
                dismiss()
            }
        }
        .onDisappear {
            applyDisplayMatch(nil)
            pictureInPicture.detach()
            controller.close()
        }
    }

    /// tvOS Match Content (HEL-64): ask the display for the video's own
    /// frame rate and dynamic range instead of letting the compositor
    /// cadence-convert and tone-map every full-4K frame. Lagoon always
    /// provides the criteria; the system's own Match Content settings are
    /// the user-facing gate beneath that request.
    private func applyDisplayMatch(_ request: DisplayMatchRequest?) {
        #if os(tvOS)
        DisplayModeMatcher.apply(request)
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

    private var episodeTransition: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .accessibilityLabel("Loading next episode")
            .accessibilityIdentifier("player.episodeTransition")
        // Focus stays on the persistent video surface so the transition
        // cannot create a focusless frame or steal the Siri Remote.
        .allowsHitTesting(false)
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
