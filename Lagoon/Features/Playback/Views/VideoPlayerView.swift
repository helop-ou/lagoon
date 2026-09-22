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
    /// Always injected, including by the iOS UIKit player host. Outside a
    /// group `attach` does nothing.
    @Environment(SyncPlayStore.self) private var syncPlay
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PlaybackController()
    @State private var pictureInPicture = SampleBufferPictureInPicture()
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    /// Writes straight through to UserDefaults, so it outlives the player.
    @State private var audioTrackMemory = AudioTrackMemoryStore()
    @State private var subtitleTrackMemory = SubtitleTrackMemoryStore()
    @State private var panelOpen = false
    #if os(iOS)
    /// Swipe down drags the player and past the threshold minimizes it into
    /// PiP; swipe up opens the options panel.
    @State private var minimizeDrag: CGFloat = 0
    #endif
    @State private var openPanelRequest = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nil outside a group. Read here so `CustomPlayerView` stays a view
    /// over values and the store has one reader in the player.
    private var togetherState: PlayerTogetherState? {
        guard syncPlay.isJoined else { return nil }
        return PlayerTogetherState(
            groupName: syncPlay.session.groupName ?? String(localized: "Watch Together"),
            participants: syncPlay.session.participants,
            state: syncPlay.session.state,
            ignoresWait: syncPlay.ignoresWait
        )
    }

    private var nextUpEpisode: NextUpEpisode? {
        guard let next = controller.nextUp else { return nil }
        return NextUpEpisode(
            title: next.name ?? "",
            subtitle: next.episodeLabel,
            imageURL: session.client.imageURL(for: next, kind: .thumb, maxWidth: 480)
        )
    }

    /// Split from `body` so the modifier chain type-checks in reasonable time.
    private var playerStack: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let errorMessage = controller.errorMessage {
                // The error overlay carries its own focus and exit handling
                // so Menu never strands.
                errorOverlay(errorMessage)
            } else if let engine = controller.engine {
                playerSurface(engine: engine)
            } else {
                LoadingView()
            }

            if !controller.hudLines.isEmpty, !panelOpen {
                playbackHUD
            }

            // A leaf reads the notices, so this body never subscribes to them.
            SyncPlayNoticeToast(store: syncPlay, reduceMotion: reduceMotion)

            // Keep CustomPlayerView and its display layer mounted across the
            // episode handoff, so the cover never flashes its presenter.
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
        // No clip: it would cut the black painted beyond the safe area and
        // show the screen underneath.
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
            // Before start, so the group's hooks are in place before the
            // first engine is built.
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
            // An unanswered `.card` offer closes like `.off`. An accepted
            // one must not: the file can end while the successor is still
            // being prepared, and closing would tear down that handoff.
            if !controller.isAdvancing, !controller.isAutoplayPending {
                closePlayer()
            }
        }
        .onChange(of: controller.engine?.displayMatchRequest) { _, request in
            // Keep the display mode through a handoff, so episode
            // boundaries cost no HDMI mode round trip.
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
        // Background hands the display mode back; active re-requests it.
        // tvOS only in effect: under the iOS UIKit host scenePhase never
        // changes, so the controller uses app notifications there.
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
                // Overlays (Control Center, alerts, PiP start) make the scene
                // inactive. Keep playing and keep the display mode: releasing
                // it here costs two HDMI renegotiations for an overlay.
                break
            case .active:
                subtitlePreferences.refreshSystemAppearance()
                controller.resumeBufferFill()
                applyDisplayMatch(controller.engine?.displayMatchRequest)
            @unknown default:
                break
            }
        }
        // Harness hook (debug.benchAutoExit): leave through the clean
        // teardown path so scripted runs never kill the app mid-playback.
        .onChange(of: controller.engine?.benchCompleted) { _, completed in
            if completed == true, UserDefaults.standard.bool(forKey: "debug.benchAutoExit") {
                closePlayer()
            }
        }
        // Soak hook (debug.soakExitAtSeconds): same clean teardown path.
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
    /// Vertical only. Child gestures (timeline drag, buttons, surface taps)
    /// win, so this sees only swipes over free video.
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

    /// Where PiP is not possible (simulator, unsupported route) the swipe
    /// closes instead.
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

    /// tvOS Match Content: request the video's frame rate and dynamic
    /// range. The system's Match Content settings gate the request.
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
        // Focus stays on the video surface, so the transition never
        // leaves a focusless frame.
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
    /// Carries the bench line for the frame-loss UI regression to read.
    /// Extracted so `body` type-checks in reasonable time.
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


    /// Extracted so `body` type-checks in reasonable time.
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
                // Weak, like `PlayerEngineRef`: SwiftUI keeps copies of this
                // closure past an episode handoff, and a strong capture
                // would pin the outgoing engine. Never capture it strongly.
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
