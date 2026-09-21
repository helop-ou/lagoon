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

/// What the viewer's transport means when a server owns it.
///
/// Implemented by the SyncPlay driver and held weakly by the controller,
/// which is the one place every play, pause, seek and "next" passes
/// through. A request does nothing locally: the group answers everyone
/// with a command, and that command is what moves this player.
@MainActor
protocol GroupTransportRequests: AnyObject {
    func requestPlay()
    func requestPause()
    /// `resume` carries the tvOS commit grammar — land here *and* play on —
    /// so the implementation can order the two requests itself.
    func requestSeek(to seconds: Double, resume: Bool)
    func requestNextItem()
}

/// The transport intentions the player chrome states, and the owner acts
/// on.
///
/// Actions rather than an object, for the reason `CustomPlayerView` takes
/// `automation` and a handful of values rather than the controller: the
/// chrome says what the viewer asked for and stays out of who answers.
/// Closures, not a reference, also keep the engine out of anything SwiftUI
/// retains.
struct PlayerTransportActions {
    /// Idempotent, because the system integrations that use these describe
    /// the state they want rather than asking the app to invert its own.
    let play: () -> Void
    let pause: () -> Void
    let togglePause: () -> Void
    let seek: (_ seconds: Double, _ resume: Bool) -> Void
    let seekBy: (_ seconds: Double) -> Void
}

/// Soak diagnostic: milliseconds for a `Duration`, shared by the
/// DecodeTrace loop's `mainLateMs`/`pumpMs`/`Soak*` lines.
private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// Negotiates the stream with Jellyfin, runs the Lagoon engine (the app's
/// only player), and owns progress reporting.
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
    /// diagnostics hub, one attempt at a time.
    let incidents = PlaybackIncidentMonitor()

    /// The episode queued behind this one, resolved once at start so the Up
    /// Next card can appear the instant the credits do. Nil for
    /// movies and at the end of a series.
    private(set) var nextUp: MediaItem? {
        didSet { automation.setNextUpAvailable(nextUp != nil) }
    }
    /// Skip and Up Next timing, off the engine's clock.
    let automation = PlaybackAutomation()
    /// The end of the file is rolling into the next episode: set before the
    /// hand-off task runs, so the view's own end-of-file handling does not
    /// close the player underneath it.
    private(set) var isAutoplayPending = false
    /// The app is in the background on iOS and the picture is off: every
    /// engine, including a successor started by autoplay, plays audio only
    /// until the app is back.
    private var videoOutputSuspended = false
    /// The engine anchored its first frame after a load or a seek — every
    /// time, not once per engine. A SyncPlay driver reports Ready on it;
    /// the controller rewires it onto each successor engine, so
    /// the driver never has to hold one.
    @ObservationIgnored var onEngineReady: (() -> Void)?
    /// The player session is over for good. A driver leaves its group here
    /// rather than going on reporting from a controller with no engine.
    @ObservationIgnored var onClosed: (() -> Void)?
    /// The engine started or stopped buffering — a stall, a seek, the
    /// initial prime. A SyncPlay group's Buffering and Ready reports are
    /// this signal, since the slowest member sets the group's pace.
    /// Rewired onto each successor engine like `onEngineReady`.
    @ObservationIgnored var onBufferingChanged: ((Bool) -> Void)?
    /// Set while a SyncPlay group owns the transport. Weak: the
    /// store owns the driver, the driver holds this controller weakly, and
    /// neither end may keep the other alive. Nil is the ordinary case and
    /// the ordinary behaviour — every `user…` method below acts locally.
    @ObservationIgnored weak var groupTransport: (any GroupTransportRequests)?
    /// Extra playback-HUD lines from whatever else is driving this session.
    /// Supplied by the SyncPlay driver so the `Sync:` line is assembled by
    /// the object that knows the group.
    @ObservationIgnored var groupHUDLines: (() -> [String])?
    #if os(iOS)
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    /// Whether Picture in Picture is showing the picture, or about to. The
    /// player view answers, because the PiP coordinator is its state.
    @ObservationIgnored var isPictureInPictureShowing: () -> Bool = { false }
    #endif

    private(set) var hudLines: [String] = []
    /// The byte-zero prefix remains available for compatibility diagnostics,
    /// while the timeline renders every sparse range retained around seeks.
    /// HLS/native paths have no direct-file byte-range model.
    private(set) var bufferedFraction: Double?
    private(set) var bufferedRanges: [PlaybackBufferedRange] = []
    private(set) var playheadPrefetchCount = 0

    private var client: JellyfinClient?
    /// Retained so a failed attempt can be replayed on the next rung of the
    /// delivery ladder; everything else `start` needs is already
    /// controller state.
    private var currentMedia: MediaItem?
    /// How the current item is being delivered, and the position a retry
    /// resumes from. The ladder belongs to one item — a new one starts at
    /// the top.
    private var delivery: PlaybackDelivery = .negotiated
    private var deliveryItemId: String?
    private var resumeOverride: Double?
    /// A position handed to `start` by its caller, outranking every resume
    /// rule for that one start: joining a SyncPlay group means the
    /// server, not the viewer's own watch history, says where to begin.
    /// Deliberately not `resumeOverride`, which the new-item reset clears —
    /// and a group join is exactly when the item is new.
    private var startPositionOverride: Double?
    /// Whether the engine about to be built should sit at its start position
    /// instead of rolling. A group member loads, waits there,
    /// reports Ready, and is started later by `playGroup(atHostTime:)`.
    private var startsPaused = false
    /// Whether the attempt currently starting (or last started) is playing a
    /// downloaded file rather than a server stream. Always false
    /// on tvOS, which carries no downloads.
    private var isLocalPlayback = false
    /// Set once a local-playback attempt fails and falls back, so the retry
    /// negotiates with the server instead of finding the same broken file on
    /// disk again and replaying it forever. A new item resets it.
    private var skipsLocalPlayback = false
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
    /// ladder rung itself to tell a forced remux apart from an ordinary
    /// transcode.
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
    /// Soak hook (`debug.soakExitAtSeconds`): flips once the film
    /// reaches the configured position, so the view's `onChange` can drive
    /// the same `dismiss()` a real exit would. Observable so that onChange
    /// fires; kept separate from `didFinish`, which means something
    /// different (the file actually ran out).
    private(set) var soakExitRequested = false
    /// When the soak exit was requested, so `close()` can report how long
    /// the whole exit — not just `beginStop()` — took from that instant.
    @ObservationIgnored private var soakExitRequestedAt: ContinuousClock.Instant?
    /// What the viewer picked in the track panel, carried into the next
    /// episode. Nil on a first load — there is nothing to carry.
    private var trackPreference: TrackPreference?
    /// Series-scoped memory of the viewer's audio choice, which outlives
    /// this controller and so survives closing the player. Set by
    /// the player view before the first start; nil in tests and previews,
    /// where the in-session carry above is the whole mechanism.
    @ObservationIgnored var audioTrackMemory: AudioTrackMemoryStore?
    /// Which show (or film) the current item answers for in that memory.
    @ObservationIgnored private var audioMemoryScope: String?
    /// The audio layout that scope was resolved against. Held rather than
    /// re-read from `audioStreams` at exit, so the shape a choice is stored
    /// against is always the one it was chosen from — a start that fails
    /// partway cannot pair a new item's scope with the last one's streams.
    @ObservationIgnored private var audioMemoryLayout: [AudioLayoutStream] = []
    /// What automatic selection alone chose for this item, before any
    /// remembered override. Kept so the exit can tell an override from a
    /// viewer who simply left the default alone.
    @ObservationIgnored private var policyAudioOrdinal: Int?
    /// The same three for subtitles. Separate from the audio trio rather
    /// than folded in with it: an item can lose its remembered subtitle and
    /// keep its remembered audio, and a layout that describes one says
    /// nothing about the other.
    @ObservationIgnored var subtitleTrackMemory: SubtitleTrackMemoryStore?
    @ObservationIgnored private var subtitleMemoryScope: String?
    @ObservationIgnored private var subtitleMemoryLayout: [SubtitleLayoutStream] = []
    @ObservationIgnored private var policySubtitleOrdinal: Int?
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
        #if os(iOS)
        // Application notifications rather than SwiftUI's `scenePhase`: the
        // player is presented from UIKit (`PlayerPresentationHub`), where
        // the environment's phase never changes, which is how the old
        // pause-on-background silently never ran on iOS.
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

    /// `startPosition` and `startPaused` are the group-playback entry:
    /// the server names the position and whether the member
    /// waits there for a start instant. Both apply to this start only.
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
        // A failed or cancelled group start must not leak its position into
        // the next ordinary playback attempt.
        startPositionOverride = startPosition
        startsPaused = startPaused
        if deliveryItemId != media.id {
            // A different item negotiates from scratch: the previous one's
            // failures say nothing about this file.
            deliveryItemId = media.id
            delivery = .negotiated
            deliveryFallbacks = []
            resumeOverride = nil
            skipsLocalPlayback = false
            #if DEBUG
            // Regression hook: start on a chosen rung instead of negotiating,
            // so the HLS cases open a real playlist on a server whose content
            // would otherwise direct-play — every public-demo item is H.264
            // (audit A18). `debug.regressionInitialDelivery` is a
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
        // A downloaded title plays from its own file with no server round
        // trip at all: checked first, ahead of both negotiation and a
        // prepared successor, since a prepared successor still describes a
        // network stream. Only iOS carries downloads.
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
        // How far the attempt got, for the report if it fails: nothing
        // negotiated, or an engine that never became ready.
        var startStage: PlaybackFailureDetail.Stage = .negotiate
        do {
            // Chapters and trickplay ride alongside the negotiation rather
            // than after it — neither is in PlaybackInfo, and waiting for a
            // second round trip would delay the first frame. A
            // downloaded title has no negotiation to ride alongside, and
            // asking anyway would burn the client's full request timeout
            // against an unreachable server before the engine ever starts;
            // chapters, trickplay and skip segments are accepted losses
            // offline for this MVP.
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
                // A disc cannot be played from the bytes this rung serves,
                // whatever the server answers about direct play, so the
                // ladder steps past it before an attempt rather than after
                // one. No engine starts, but the HUD still gets a
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
            playMethod = method
            // A disc image Lagoon can read is played by reading it, not by
            // asking the server to rebuild it — but only when the bytes on
            // offer are the image itself. A transcode of the same title is an
            // ordinary stream and must stay one. A downloaded file
            // is never a raw disc image on disk, and disc reading depends on
            // the cache session a local file deliberately has none of.
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
            // disc image, whose reader lives behind the session.
            let transportCache = PlaybackBufferPolicy.engineUsesCacheSession(
                playsFromCompleteFile: playbackURL.isFileURL,
                disc: discRequest != nil,
                method: method
            ) ? cacheSession : nil
            publishBufferMetrics(cacheSession?.metrics)

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

            // A downloaded original is the stored file, so its source
            // streams describe it and drive selection exactly as a
            // negotiated stream would. A transcode download is a different
            // file the server built for offline use (one audio track, no
            // external subtitles, a container the source metadata never
            // described), so its source streams do not describe what is
            // actually on disk; empty metadata here is safe; the ordinal
            // policies below and the engine's own track building already
            // degrade to what the file demuxes to when given nothing.
            #if os(iOS)
            let sourceStreams: [MediaStream] = localIsTranscode ? [] : (source.mediaStreams ?? [])
            #else
            let sourceStreams = source.mediaStreams ?? []
            #endif
            // The server's default audio choice (user language preferences
            // applied server-side) maps to the demuxer's per-type 1-based
            // ordinal: embedded streams keep their demux order.
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
            // A choice carried in from the previous episode outranks the
            // server's default: the viewer overrode it once already.
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
            // And a choice the viewer made for this show outranks both, for
            // as long as it still describes a track here. Its last rung is
            // the track's position, which speaks only where the layout
            // offers nothing else to reason about.
            if let scope = audioMemoryScope,
               let remembered = audioTrackMemory?.choice(for: scope),
               let carried = AudioTrackMemoryPolicy.ordinal(
                   for: remembered,
                   in: audioLayout
               ) {
                initialAudioOrdinal = carried
            }

            // Subtitles share the ordinal convention, with external
            // (sidecar) streams appended after the embedded ones — the
            // engine lists them in the same order.
            let allSubtitles = sourceStreams.filter { $0.type == "Subtitle" }
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
            // What automatic selection would choose here, whether or not
            // anything overrules it below: the exit compares against it to
            // tell a deliberate change from the default left alone.
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
            // And a choice the viewer made for this show outranks both, for
            // as long as it still describes a track here, or says there
            // should be none.
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
            // Hands-off soak/bench hook, mirroring
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
            if startsPaused {
                // Before the view attaches and priming begins, so
                // `beginPlayback` anchors the clock at rate 0 and the member
                // sits on its first frame until the group is started.
                engine.pause()
            }
            startsPaused = false
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
                // A timed skip waits for the picture to be moving again
                // before it spends the buffer on a seek.
                self.automation.isBuffering = buffering
                self.onBufferingChanged?(buffering)
            }
            engine.setVideoOutputSuspended(videoOutputSuspended)
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
                // Identity-guarded: a shut-down engine keeps reporting the
                // track it had, and this writes durable state.
                if let self, let engine, self.engine === engine {
                    self.rememberAudioChoice(engine: engine)
                    self.rememberSubtitleChoice(engine: engine)
                }
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
            automation.beginItem(identity: media.id, segments: playerInfo.segments)
            // Seeded, not waited for: the callback above only reports
            // changes, and it was installed before this engine was the
            // controller's own.
            automation.isBuffering = engine.isBuffering
            // Through the controller rather than straight to the engine, so
            // a skip inside a group becomes the group's seek and everyone
            // skips the intro together.
            automation.onSkip = { [weak self] segment in self?.userSeek(to: segment.end) }
            automation.onPlayNext = { [weak self] in
                guard let self, !self.isClosed, !self.isAdvancing else { return }
                // In a group the queue decides what comes next, and the
                // server tells every member — including this one, which is
                // why nothing local starts here.
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
            // Deterministic UI-test hook for the otherwise tiny interval in
            // which dismissal can race a suspended startup request.
            let startupDelay = UserDefaults.standard.double(
                forKey: "debug.regressionPlaybackStartDelaySeconds"
            )
            if startupDelay > 0 {
                try await Task.sleep(for: .seconds(startupDelay))
            }
            #endif

            if isLocalPlayback {
                // A downloaded title plays regardless of whether the server
                // ever hears about it, so nothing below should wait on this
                // call: an unreachable server would otherwise hold up the
                // progress loop, HUD and next-up warm-up for the client's
                // full request timeout, entirely off the local file.
                // The report still goes out when the server is
                // reachable; a failure is silently dropped either way.
                Task {
                    try? await reporting.reportStart(at: resumeSeconds)
                }
            } else {
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
                            + (self.groupHUDLines?() ?? [])
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

    /// Which resume position wins when a title starts. An override always
    /// outranks the rest — a fallback retry's exact landing spot, or the
    /// position a SyncPlay group is at. Neither is a stored
    /// position the viewer could be overruling: one is the internal
    /// recovery of a rung the viewer never chose, the other is where
    /// everyone else already is. So both apply even when the viewer chose
    /// to start over. Short of
    /// that, starting from beginning always starts at 0: a downloaded
    /// title's own local position only resumes it in place of the
    /// server's last known position, since a fresh negotiation never runs
    /// to ask the server anything for a local file.
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

    /// Persists — or drops — an audio choice the viewer just made.
    ///
    /// Driven by the engine's selection callback, which only `selectAudioTrack`
    /// fires and only the track panel and the system now-playing menu reach.
    /// Automatic selection takes the engine's internal path instead, so
    /// everything recorded here is a deliberate act. Recording at
    /// the moment of the act, rather than reading a selection back at exit,
    /// is also what keeps the item, its layout and the live engine in step:
    /// at exit any of the three can already belong to the next episode.
    private func rememberAudioChoice(engine: SampleBufferPlayerEngine) {
        guard let audioTrackMemory,
              let scope = audioMemoryScope,
              let selected = engine.audioTracks.first(where: \.isSelected),
              audioMemoryLayout.indices.contains(selected.engineID - 1),
              // Engine ordinals count what was delivered; the layout counts
              // what the server described. On a remux or transcode rung
              // those differ — one delivered track against the source's
              // several — and an ordinal from one means nothing in the
              // other.
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

    /// Persists — or drops — a subtitle choice the viewer just made, on the
    /// same terms as `rememberAudioChoice`.
    ///
    /// Two differences, both from the ordinal space. Nothing selected is
    /// ordinal 0 and a real answer, so this records a selection *and* its
    /// absence. And subtitle search appends tracks while the episode plays,
    /// so the engine can list more than the layout captured at start: the
    /// prefix still lines up, which is why this asks for at least as many
    /// rather than exactly as many, and refuses an ordinal naming one of the
    /// appended tracks.
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
    /// outages from a Debug build before either renderer-side conclusion is
    /// trusted on hardware.
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
    /// visibly later first frame.
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

    /// Roll into the queued episode without leaving the player.
    ///
    /// The order is the whole of it: the finished episode's stop report has
    /// to land *before* the next one starts. Jellyfin marks an item played
    /// off that report, and starting a second session for the same device
    /// first leaves the one just finished unresolved.
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
            // The file's own title, not Jellyfin's synthesized display
            // title: the latter is built from codec and channel layout, so
            // it reads the same on every untagged track and would match the
            // first of them rather than the one the viewer picked.
            audioTitle: audioStream?.title,
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
    /// the foreground after a stall. Native foreground playback —
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

    /// The file ran out. A countdown still running when it did finishes
    /// the job here — without an `Outro` segment to anchor it the two land
    /// within a frame of each other, and whichever arrives first should
    /// win; `playNextEpisode` is guarded against being taken up on it
    /// twice. Decided here rather than in the view so a locked phone rolls
    /// into the next episode too.
    private func playbackDidFinish() {
        didFinish = true
        // A group's queue is the group's business: the end of the file asks
        // the server for the next entry whether or not this item has a
        // series successor, and whether or not this viewer's autoplay
        // preference would have rolled on alone.
        if let groupTransport {
            groupTransport.requestNextItem()
            return
        }
        guard automation.autoplaysOnFinish, nextUp != nil, !isAdvancing else { return }
        automation.playNext()
    }

    #if os(iOS)
    /// The app left the screen: the phone was locked or the viewer went
    /// home. Audio carries on under the `audio` background mode; the
    /// picture is dropped unless something is still showing it — PiP, or
    /// an AirPlay route — and proactive cache fill stops.
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
    // The transport a SyncPlay driver drives, deliberately separate from the
    // viewer-facing controls below. The driver intercepts those and turns
    // them into group requests, and needs a way back down that does not
    // recurse into itself. It also means the driver never holds the engine:
    // the controller stays the boundary, and a successor engine is picked up
    // for free.

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

    /// A drift nudge on top of the viewer's chosen speed, which it leaves
    /// alone. 1 is no correction.
    func setCorrectionRate(_ multiplier: Double) {
        engine?.setCorrectionRate(multiplier)
    }

    /// The media clock as the synchronizer reports it, and the position a
    /// group report carries. 0 with no engine. For the driver, not for a
    /// view: this reads tick-rate engine state, which the player root must
    /// stay out of.
    var clockPosition: Double { engine?.clockPosition ?? 0 }

    /// Loaded and anchored without rolling: a member that has reported Ready
    /// and is waiting for the group to start — or simply a paused player.
    var isPrimedAndPaused: Bool {
        guard let engine else { return false }
        return engine.isPaused && !engine.isBuffering
    }

    /// The media clock is actually advancing, which is what a group
    /// readiness report means by `IsPlaying`. Not the inverse of
    /// `isPrimedAndPaused`: a buffering engine is neither.
    var isClockRunning: Bool {
        guard let engine else { return false }
        return !engine.isPaused && !engine.isBuffering
    }

    /// Swaps the item inside one player session, for a group that moved to
    /// another queue entry while the player is open. The same
    /// stop-then-start `playNextEpisode` does — so the SwiftUI branch and
    /// its UIKit video surface survive — minus the successor warm-up, since
    /// the group, not the series order, decided what comes next.
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
    // Every control the viewer touches comes through here rather than
    // reaching the engine itself, so that one `groupTransport` check turns
    // the whole transport over to the server when a SyncPlay group owns it.
    // Outside a group each of these is the engine call the caller
    // used to make. Audio and subtitle tracks, audio delay and playback
    // speed stay local and are not routed: they are this viewer's, not the
    // group's.

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

    /// `resume` is the tvOS scrub-commit grammar: land here *and* play on.
    func userSeek(to seconds: Double, resume: Bool = false) {
        guard let groupTransport else {
            // Resume before seeking: the engine re-anchors the synchronizer
            // when the seek primes, so unpausing afterwards fights that
            // hand-off. The group path is the other way round and says why.
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

    /// Handed to the player chrome so it can state an intention without
    /// knowing who acts on it.
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
        // A countdown still sleeping must not wake up on an engine that is
        // gone; `start` wires the successor's own.
        automation.invalidate()
        if !preservingPreparedNext {
            successorPreparation.cancel()
        }
        subtitleSearch.detach()
        let seconds = engine?.timePosition ?? lastKnownPosition
        lastKnownPosition = seconds
        incidents.endAttempt(engine: engine, outcome: stopOutcome)

        // Keep the dismissal-critical main-actor phase measurable and tiny.
        // The engine now serializes renderer flushing and queued-buffer
        // release on its existing pump queue.
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
        // After the teardown either way, so a group driver leaves on a
        // controller that has already let go of its engine.
        defer { onClosed?() }
        guard let soakExitRequestedAt else { return beginStop() }
        // Soak diagnostic: `soakExitRequestedAt` is only ever set by
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
            #if os(iOS)
            if isLocalPlayback {
                // A download the engine could not play must not keep
                // replaying itself: the next rung reaches the server instead
                // of finding the same file on disk again. The entry
                // is left alone; one failed attempt is not proof the file is
                // bad, and the viewer can delete it from its page.
                skipsLocalPlayback = true
                DownloadStore.log.error(
                    "Downloaded file failed to play, falling back to the server: \(self.itemId, privacy: .public)"
                )
            }
            #endif
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
    /// over where the failure landed.
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
        // A replacement starts buffering before its callbacks are wired.
        // Tell the group now so its later Ready is a new state, even when
        // the outgoing engine had already reported Ready.
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
            prepared: nil,
            // A delivery retry must prime and report Ready before the
            // server starts the group; autoplay would bypass its authority.
            startPaused: groupTransport != nil
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
