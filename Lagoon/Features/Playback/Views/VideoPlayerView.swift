import LagoonEngine
import SwiftUI
import UIKit

struct VideoPlayerView: View {
    let playerItem: PlayerItem
    var registerPresentationCleanup: ((@escaping () -> Void) -> Void)? = nil
    var onPresentationClose: (() -> Void)? = nil
    var onPictureInPictureStarted: (() -> Void)? = nil
    var onPictureInPictureRestore: ((@escaping (Bool) -> Void) -> Void)? = nil
    @State private var leftForPictureInPicture = false

    @Environment(SessionStore.self) private var session
    /// Watch Together. Always present — `RootView` injects it,
    /// and so does the iOS UIKit player host, which rebuilds the
    /// environment from scratch. Outside a group `attach` does nothing.
    @Environment(SyncPlayStore.self) private var syncPlay
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PlaybackController()
    @State private var pictureInPicture = SampleBufferPictureInPicture()
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    /// Outlives the player presentation by writing straight through to
    /// UserDefaults, so a corrected audio track is still remembered when
    /// the viewer comes back to the show tomorrow.
    @State private var audioTrackMemory = AudioTrackMemoryStore()
    @State private var subtitleTrackMemory = SubtitleTrackMemoryStore()
    @State private var panelOpen = false
    #if os(iOS)
    /// The iPhone's swipe grammar. A downward drag carries the
    /// whole player with the finger, YouTube-style, and past the threshold
    /// minimizes it into the phone's popup player, Picture in Picture; an
    /// upward swipe opens the options panel. Close closes, nothing else.
    @State private var minimizeDrag: CGFloat = 0
    #endif
    @State private var openPanelRequest = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the panel's Together tab draws, or nil outside a group. Read
    /// here rather than in the panel so `CustomPlayerView` stays a view
    /// over values, and so the store's membership has exactly one reader
    /// in the player.
    private var togetherState: PlayerTogetherState? {
        guard syncPlay.isJoined else { return nil }
        return PlayerTogetherState(
            groupName: syncPlay.session.groupName ?? String(localized: "Watch Together"),
            participants: syncPlay.session.participants,
            state: syncPlay.session.state,
            ignoresWait: syncPlay.ignoresWait
        )
    }

    /// What the Up Next card draws, or nil when there is nothing queued.
    private var nextUpEpisode: NextUpEpisode? {
        guard let next = controller.nextUp else { return nil }
        return NextUpEpisode(
            title: next.name ?? "",
            subtitle: next.episodeLabel,
            imageURL: session.client.imageURL(for: next, kind: .thumb, maxWidth: 480)
        )
    }

    /// The player and the observers that belong to the engine.
    ///
    /// Split from `body` rather than left as one chain: with the engine
    /// behind a package boundary the combined modifier chain stopped
    /// type-checking in reasonable time.
    private var playerStack: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage = controller.errorMessage {
                // The engine is gone on purpose: the error overlay carries
                // its own focus and exit handling so Menu never strands.
                errorOverlay(errorMessage)
            } else if let engine = controller.engine {
                playerSurface(engine: engine)
            } else {
                LoadingView()
            }

            if !controller.hudLines.isEmpty, !panelOpen {
                playbackHUD
            }

            // A leaf that reads the notices itself, so this body never
            // subscribes to them and a toast costs the player nothing
            // but its own render.
            SyncPlayNoticeToast(store: syncPlay, reduceMotion: reduceMotion)

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
                frameLossRegressionProbe(bench: bench)
            }
            #endif
        }
        .interactiveDismissDisabled()
        #if os(iOS)
        // No clip here: a clip shape bounds the view to the safe area and
        // cuts the black that `ignoresSafeArea` paints beyond it, which let
        // the screen underneath show through at the bottom.
        .offset(y: minimizeDrag)
        .scaleEffect(1 - min(minimizeDrag / 1600, 0.25), anchor: .center)
        .gesture(minimizeGesture)
        #endif
        .task {
            registerPresentationCleanup? { [controller, pictureInPicture] in
                pictureInPicture.onStarted = nil
                pictureInPicture.onStopped = nil
                pictureInPicture.onRestore = nil
                pictureInPicture.detach()
                controller.close()
            }
            pictureInPicture.onStarted = {
                guard onPictureInPictureStarted != nil else { return }
                leftForPictureInPicture = true
                #if os(iOS)
                minimizeDrag = 0
                #endif
                onPictureInPictureStarted?()
            }
            pictureInPicture.onStopped = {
                if leftForPictureInPicture { closePlayer() }
            }
            #if os(iOS)
            controller.isPictureInPictureShowing = { [pictureInPicture] in
                pictureInPicture.isActive || pictureInPicture.isTransitioning
            }
            #endif
            pictureInPicture.onRestore = { completion in
                if let onPictureInPictureRestore {
                    onPictureInPictureRestore { restored in
                        if restored { leftForPictureInPicture = false }
                        completion(restored)
                    }
                } else { completion(true) }
            }
            guard controller.engine == nil else { return }
            subtitlePreferences.configure(accountID: session.activeAccount?.id)
            trackPreferences.configure(accountID: session.activeAccount?.id)
            audioTrackMemory.configure(accountID: session.activeAccount?.id)
            controller.audioTrackMemory = audioTrackMemory
            subtitleTrackMemory.configure(accountID: session.activeAccount?.id)
            controller.subtitleTrackMemory = subtitleTrackMemory
            // Before the start, so the group's driver has its readiness and
            // buffering hooks on the controller by the time the first
            // engine is built.
            syncPlay.attach(controller)
            await controller.start(
                media: playerItem.media,
                startFromBeginning: playerItem.startFromBeginning,
                client: session.client,
                trackPreferences: trackPreferences.values,
                preferredAudioLanguages: trackPreferences.preferredAudioLanguages,
                preferredSubtitleLanguages: subtitlePreferences.preferredLanguages,
                missingSubtitleMode: subtitlePreferences.values.missingMode,
                startPosition: playerItem.startPosition,
                startPaused: playerItem.startPaused
            )
        }
        .onChange(of: controller.didFinish) { _, finished in
            guard finished else { return }
            // The controller decides whether the end of the file rolls
            // into the next episode. `.card` means never acting
            // alone, so an offer that went unanswered closes the player
            // exactly as `.off` does. An *accepted* offer is a different
            // thing: the file can run out while the successor is still
            // being prepared, and dismissing there tears down a handoff the
            // viewer asked for and drops them back on the browse screen.
            if !controller.isAdvancing, !controller.isAutoplayPending {
                closePlayer()
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
    }

    var body: some View {
        playerStack
        // Backgrounding mid-playback must hand the display back — the
        // home screen has no business running at the content's mode — and
        // returning re-requests it.
        // tvOS only in effect: on iOS the player is presented from UIKit
        // and this environment value never changes there, so the
        // controller listens to the application's own notifications
        // instead and keeps playing in the background.
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
                closePlayer()
            }
        }
        // Soak hook (debug.soakExitAtSeconds): the film reached the
        // configured position, so leave through the same clean teardown
        // path a real exit takes.
        .onChange(of: controller.soakExitRequested) { _, requested in
            if requested {
                closePlayer()
            }
        }
        .onDisappear {
            guard !leftForPictureInPicture else { return }
            applyDisplayMatch(nil)
            pictureInPicture.onStarted = nil
            pictureInPicture.onStopped = nil
            pictureInPicture.onRestore = nil
            pictureInPicture.detach()
            controller.close()
        }
    }

    #if os(iOS)
    /// Vertical only, and a child gesture wins: the timeline's own drag, the
    /// buttons, and the surface taps all take precedence, so this sees only
    /// swipes over free video area. The panel sheet covers everything while
    /// it is up, so no gesture reaches here then.
    private var minimizeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                guard !panelOpen, abs(value.translation.height) > abs(value.translation.width) else { return }
                minimizeDrag = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !panelOpen else { return }
                let vertical = value.translation.height
                let predicted = value.predictedEndTranslation.height
                guard abs(vertical) > abs(value.translation.width) else {
                    withAnimation(.spring(duration: Motion.standard)) { minimizeDrag = 0 }
                    return
                }
                if vertical < -60 {
                    openPanelRequest += 1
                } else if vertical > 140 || predicted > 320 {
                    minimize()
                    return
                }
                withAnimation(.spring(duration: Motion.standard)) { minimizeDrag = 0 }
            }
    }

    /// The popup player is Picture in Picture; where PiP is not possible
    /// (the simulator, an unsupported route) the swipe closes instead, which
    /// is the nearest thing to the gesture's meaning.
    private func minimize() {
        if onPictureInPictureStarted != nil, pictureInPicture.isPossible {
            pictureInPicture.toggle()
        } else {
            closePlayer()
        }
    }
    #endif

    private func closePlayer() {
        leftForPictureInPicture = false
        pictureInPicture.onStarted = nil
        pictureInPicture.onStopped = nil
        pictureInPicture.onRestore = nil
        pictureInPicture.detach()
        controller.close()
        if let onPresentationClose { onPresentationClose() } else { dismiss() }
    }

    /// tvOS Match Content: ask the display for the video's own
    /// frame rate and dynamic range instead of letting the compositor
    /// cadence-convert and tone-map every full-4K frame. Lagoon always
    /// provides the criteria; the system's own Match Content settings are
    /// the user-facing gate beneath that request.
    private func applyDisplayMatch(_ request: DisplayMatchRequest?) {
        #if os(tvOS)
        DisplayModeMatcher.apply(request)
        #endif
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
                closePlayer()
            }
            .buttonStyle(.glass)
        }
        #if os(tvOS)
        .onExitCommand {
            closePlayer()
        }
        #endif
    }

#if DEBUG
    /// A zero-size accessibility element carrying the bench line, for the
    /// frame-loss UI regression to read.
    ///
    /// Extracted from the body rather than inlined: with the engine behind a
    /// package boundary the whole `body` stopped type-checking in reasonable
    /// time, and this chain was the expensive part.
    @ViewBuilder
    private func frameLossRegressionProbe(bench: String) -> some View {
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


    /// The player surface and its panel.
    ///
    /// Extracted from `body` rather than inlined: with the engine
    /// behind a package boundary the whole body stopped type-checking
    /// in reasonable time, and this call was the expensive part.
    @ViewBuilder
    private func playerSurface(engine: SampleBufferPlayerEngine) -> some View {
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
                automation: controller.automation,
                transport: controller.transportActions,
                onDismiss: { closePlayer() },
                onPanelToggle: { panelOpen = $0 },
                openPanelRequest: openPanelRequest,
                nextUp: nextUpEpisode,
                isPictureInPicturePossible: pictureInPicture.isPossible,
                isPictureInPictureActive: pictureInPicture.isActive,
                onTogglePictureInPicture: { pictureInPicture.toggle() },
                together: togetherState,
                onLeaveGroup: { Task { await syncPlay.leave() } },
                onSetIgnoreWait: { ignore in Task { await syncPlay.setIgnoreWait(ignore) } },
                isWaitingForGroup: syncPlay.isWaitingForGroup,
                subtitleStyle: subtitlePreferences.renderStyle,
                subtitleSearch: controller.subtitleSearch
            ) { [weak engine] in
                // Weak for the same reason the player views hold the
                // engine through `PlayerEngineRef`: SwiftUI
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
    }
}
