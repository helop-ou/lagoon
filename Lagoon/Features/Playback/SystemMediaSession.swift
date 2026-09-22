import AVFAudio
import Foundation
import LagoonEngine
import MediaPlayer
import UIKit

/// Owns the AVAudioSession lifecycle. Renderers never configure the
/// process-wide session: interruptions and routes belong to the playback
/// session.
@MainActor
final class PlaybackAudioSession {
    var onPauseRequested: (() -> Void)?
    var onResumeRequested: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?
    var onRouteAvailabilityChanged: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var notificationTokens: [NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
    private(set) var isActive = false

    var isExternalPlaybackRouteActive: Bool {
        session.currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    func activate(isPlaying: @escaping () -> Bool) throws {
        deactivateNotificationsOnly()
        #if os(iOS)
        try session.setCategory(
            .playback,
            mode: .moviePlayback,
            policy: .longFormVideo,
            options: []
        )
        #else
        // longFormVideo is an iOS route-sharing policy; tvOS already owns the
        // long-form route.
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        #endif
        try session.setSupportsMultichannelContent(true)
        try session.setActive(true)
        isActive = true
        installNotifications(isPlaying: isPlaying)
        onRouteAvailabilityChanged?(isExternalPlaybackRouteActive)
    }

    func deactivate() {
        deactivateNotificationsOnly()
        guard isActive else { return }
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            onError?(error)
        }
        isActive = false
    }

    private func installNotifications(isPlaying: @escaping () -> Bool) {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification, isPlaying: isPlaying)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreAfterMediaServicesReset()
            }
        })
    }

    private func deactivateNotificationsOnly() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func handleInterruption(_ notification: Notification, isPlaying: () -> Bool) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying()
            Diagnostics.record(.audioInterruption, ["interruption": .string("began"), "paused": .bool(!wasPlayingBeforeInterruption)])
            if wasPlayingBeforeInterruption {
                onPauseRequested?()
            }
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            Diagnostics.record(.audioInterruption, ["interruption": .string(shouldResume ? "endedResume" : "ended")])
            wasPlayingBeforeInterruption = false
            if shouldResume {
                onResumeRequested?()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) ?? .unknown
        let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            as? AVAudioSessionRouteDescription
        Diagnostics.record(.audioRoute, ["routeReason": .string(Self.routeChangeReasonName(reason))])
        if ProcessCPUTrace.enabled {
            // Report-only: route churn on the DecodeTrace console, gated the same.
            // Never changes behaviour.
            let previousPortTypes = (previousRoute?.outputs.map(\.portType.rawValue) ?? [])
                .joined(separator: ",")
            let currentPortTypes = session.currentRoute.outputs.map(\.portType.rawValue)
                .joined(separator: ",")
            print(String(
                format: "RouteTrace reason=%@ previous=[%@] current=[%@] uptime=%.3f",
                Self.routeChangeReasonName(reason),
                previousPortTypes,
                currentPortTypes,
                ProcessInfo.processInfo.systemUptime
            ))
        }
        if Self.shouldPauseAfterRouteLoss(
            reason: reason,
            previousOutputs: previousRoute?.outputs.map(\.portType) ?? []
        ) {
            onPauseRequested?()
        }
        onRouteAvailabilityChanged?(isExternalPlaybackRouteActive)
    }

    /// For `RouteTrace` only. `shouldPauseAfterRouteLoss` switches on the raw
    /// reason.
    private static func routeChangeReasonName(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: "unknown"
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        @unknown default: "unknown"
        }
    }

    private func restoreAfterMediaServicesReset() {
        // The media server discarded every session property and the renderer.
        // Apple requires recreating them and waiting for user action before
        // resuming.
        isActive = false
        wasPlayingBeforeInterruption = false
        do {
            #if os(iOS)
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
            #else
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            #endif
            try session.setSupportsMultichannelContent(true)
            try session.setActive(true)
            isActive = true
            onMediaServicesReset?()
            onRouteAvailabilityChanged?(isExternalPlaybackRouteActive)
        } catch {
            onError?(error)
        }
    }

    #if DEBUG
    func simulateMediaServicesResetForRegression() {
        restoreAfterMediaServicesReset()
    }
    #endif

    /// Apple recommends pausing for old-device-unavailable, but only a
    /// private output disappearing should pause here. tvOS changes HDMI timing
    /// when matching content; treating HDMI as headphones paused every 24 Hz
    /// movie as it began.
    nonisolated static func shouldPauseAfterRouteLoss(
        reason: AVAudioSession.RouteChangeReason,
        previousOutputs: [AVAudioSession.Port]
    ) -> Bool {
        guard reason == .oldDeviceUnavailable else { return false }
        let personalOutputs: Set<AVAudioSession.Port> = [
            .headphones,
            .bluetoothA2DP,
            .bluetoothLE,
            .bluetoothHFP,
            .airPlay,
        ]
        return previousOutputs.contains { personalOutputs.contains($0) }
    }
}

/// Publishes engine state to the system and routes lock-screen, Control
/// Center, Siri Remote and headset commands back to the PlayerEngine.
@MainActor
final class NowPlayingCoordinator {
    private weak var engine: (any PlayerEngine)?
    /// Where a transport command goes, so system controls reach the same
    /// interception point as the player chrome. In a SyncPlay group they become
    /// server requests. Track selection, rate and the timeline are this
    /// viewer's and are not routed.
    private var transport: PlayerTransportActions?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var nowPlayingInfo: [String: Any] = [:]
    private var languageActions: [String: (PlayerTrack.Kind, Int)] = [:]
    private var artworkTask: Task<Void, Never>?

    func activate(
        info: PlayerItemInfo,
        itemID: String,
        engine: any PlayerEngine,
        transport: PlayerTransportActions? = nil,
        replacingActiveSession: Bool = false
    ) {
        reset(publishStopped: !replacingActiveSession)
        self.engine = engine
        self.transport = transport
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyMediaType: MPMediaType.anyVideo.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: itemID,
        ]
        if let subtitle = info.subtitle {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        registerCommands()
        updateTimeline()
        updateLanguageOptions()
        loadArtwork(from: info.posterURL)
    }

    func updateTimeline() {
        guard let engine else { return }
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = engine.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.timePosition
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPaused ? 0.0 : engine.rate
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = engine.rate
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nowPlayingInfo
        center.playbackState = engine.isPaused ? .paused : .playing
    }

    func updateLanguageOptions() {
        guard let engine else { return }
        languageActions.removeAll()
        var groups: [MPNowPlayingInfoLanguageOptionGroup] = []
        var current: [MPNowPlayingInfoLanguageOption] = []

        if let group = languageGroup(for: engine.audioTracks, type: .audible, allowEmptySelection: false) {
            groups.append(group.group)
            current.append(contentsOf: group.current)
        }
        if let group = languageGroup(for: engine.subtitleTracks, type: .legible, allowEmptySelection: true) {
            groups.append(group.group)
            current.append(contentsOf: group.current)
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyAvailableLanguageOptions] = groups
        nowPlayingInfo[MPNowPlayingInfoPropertyCurrentLanguageOptions] = current
        updateTimeline()
    }

    func stop() {
        reset(publishStopped: true)
    }

    /// Releases the previous engine. During a handoff, publishing `.stopped`
    /// before the new metadata makes Control Center and HDMI receivers flicker.
    private func reset(publishStopped: Bool) {
        artworkTask?.cancel()
        artworkTask = nil
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets.removeAll()
        languageActions.removeAll()
        engine = nil
        transport = nil
        nowPlayingInfo.removeAll()
        if publishStopped {
            let center = MPNowPlayingInfoCenter.default()
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
        }
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { [weak self] _ in
            guard let self else { return }
            if let transport = self.transport { transport.play() } else { self.engine?.play() }
            self.updateTimeline()
        }
        add(center.pauseCommand) { [weak self] _ in
            guard let self else { return }
            if let transport = self.transport { transport.pause() } else { self.engine?.pause() }
            self.updateTimeline()
        }
        add(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return }
            if let transport = self.transport { transport.togglePause() } else { self.engine?.togglePause() }
            self.updateTimeline()
        }
        center.skipForwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { [weak self] _ in
            self?.seek(by: 10)
        }
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipBackwardCommand) { [weak self] _ in
            self?.seek(by: -10)
        }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let position = event as? MPChangePlaybackPositionCommandEvent else { return }
            if let transport = self.transport {
                transport.seek(position.positionTime, false)
            } else {
                self.engine?.seek(to: position.positionTime)
            }
            self.updateTimeline()
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = PlaybackRatePolicy.supported.map {
            NSNumber(value: $0)
        }
        add(center.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return }
            self?.engine?.setRate(Double(event.playbackRate))
            self?.updateTimeline()
        }
        add(center.enableLanguageOptionCommand) { [weak self] event in
            guard let event = event as? MPChangeLanguageOptionCommandEvent,
                  let identifier = event.languageOption.identifier,
                  let action = self?.languageActions[identifier] else { return }
            self?.selectLanguage(action)
        }
        add(center.disableLanguageOptionCommand) { [weak self] event in
            guard let event = event as? MPChangeLanguageOptionCommandEvent else { return }
            if event.languageOption.languageOptionType == .legible {
                self?.engine?.selectSubtitleTrack(id: nil)
                self?.updateLanguageOptions()
            }
        }
    }

    private func seek(by seconds: Double) {
        if let transport { transport.seekBy(seconds) } else { engine?.seek(by: seconds) }
        updateTimeline()
    }

    private func add(_ command: MPRemoteCommand, handler: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { event in
            // MediaPlayer does not promise its callback queue, so hop to the main actor.
            Task { @MainActor in handler(event) }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func selectLanguage(_ action: (PlayerTrack.Kind, Int)) {
        switch action.0 {
        case .audio: engine?.selectAudioTrack(id: action.1)
        case .subtitle: engine?.selectSubtitleTrack(id: action.1)
        }
        updateLanguageOptions()
    }

    private func languageGroup(
        for tracks: [PlayerTrack],
        type: MPNowPlayingInfoLanguageOptionType,
        allowEmptySelection: Bool
    ) -> (group: MPNowPlayingInfoLanguageOptionGroup, current: [MPNowPlayingInfoLanguageOption])? {
        guard !tracks.isEmpty else { return nil }
        let options = tracks.map { track in
            let identifier = track.id
            languageActions[identifier] = (track.kind, track.engineID)
            var characteristics: [String] = []
            if track.isForced { characteristics.append(MPLanguageOptionCharacteristicContainsOnlyForcedSubtitles) }
            if track.isHearingImpaired {
                characteristics.append(MPLanguageOptionCharacteristicTranscribesSpokenDialog)
                characteristics.append(MPLanguageOptionCharacteristicDescribesMusicAndSound)
            }
            return MPNowPlayingInfoLanguageOption(
                type: type,
                languageTag: track.languageTag ?? "und",
                characteristics: characteristics,
                displayName: track.displayName,
                identifier: identifier
            )
        }
        let selected = zip(tracks, options).first(where: { $0.0.isSelected })?.1
        return (
            MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: options,
                defaultLanguageOption: selected,
                allowEmptySelection: allowEmptySelection
            ),
            selected.map { [$0] } ?? []
        )
    }

    private func loadArtwork(from url: URL?) {
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let image = await ImageCache.shared.load(url, maxPixelSize: 1024),
                  !Task.isCancelled,
                  let self else { return }
            self.nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.updateTimeline()
        }
    }
}
