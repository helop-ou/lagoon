import AVFAudio
import AVFoundation
import UIKit
import Foundation
import Testing
@testable import LagoonEngine
@testable import Lagoon

@Suite("Player system integration", .serialized)
struct PlayerSystemIntegrationTests {
    @Test func privateRouteLossPausesButHDMIDisplayChangeDoesNot() {
        #expect(PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .oldDeviceUnavailable,
            previousOutputs: [.headphones]
        ))
        #expect(PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .oldDeviceUnavailable,
            previousOutputs: [.bluetoothA2DP]
        ))
        #expect(!PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .oldDeviceUnavailable,
            previousOutputs: [.HDMI]
        ))
        #expect(!PlaybackAudioSession.shouldPauseAfterRouteLoss(
            reason: .newDeviceAvailable,
            previousOutputs: [.headphones]
        ))
    }

    @Test func appleLanguagesAreOrderedDeduplicatedAndConvertedForJellyfin() {
        #expect(SubtitlePreferencesStore.deduplicated([
            "et-EE", "en-US", "et", "EN_GB",
        ]) == ["et", "en"])
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "et-EE") == "est")
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "en") == "eng")
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "ar") == "ara")
        #expect(JellyfinSubtitleLanguageCode.threeLetter(for: "cs-CZ") == "ces")
    }

    @Test func remoteSubtitleMetadataDecodesWithoutProviderSpecificLogic() throws {
        let json = Data(#"""
        {
          "Id": "eng-provider-42",
          "Name": "Release.Name",
          "ThreeLetterISOLanguageName": "eng",
          "ProviderName": "Open Subtitles",
          "Format": "srt",
          "CommunityRating": 8.7,
          "DownloadCount": 1234,
          "IsHashMatch": true,
          "HearingImpaired": true,
          "MachineTranslated": false,
          "AiTranslated": false,
          "FrameRate": 23.976
        }
        """#.utf8)
        let result = try JellyfinClient.decoder.decode(RemoteSubtitleInfo.self, from: json)
        #expect(result.id == "eng-provider-42")
        #expect(result.threeLetterISOLanguageName == "eng")
        #expect(result.providerName == "Open Subtitles")
        #expect(result.hearingImpaired == true)
        #expect(result.isHashMatch == true)
    }

    @Test @MainActor func inPlayerLanguageChoicesStayCompactAndPreferenceOrdered() {
        let choices = SubtitleSearchCoordinator.makeLanguageChoices(
            preferredLanguages: ["is-IS", "en-US", "is"]
        )
        #expect(choices.prefix(2) == ["is", "en"])
        #expect(Set(choices).count == choices.count)
        #expect(choices.count <= SubtitlePreferencesStore.commonLanguageChoices.count + 2)
        #expect(choices.count < SubtitlePreferencesStore.allLanguageChoices.count)
    }

    @Test func subtitleFailuresKeepTheCauseTheViewerCanActOn() {
        // A 403 is a server permission, not an exhausted quota.
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 403)) == .notPermitted)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 401)) == .sessionExpired)
        #expect(SubtitleDownloadError.classify(JellyfinError.unauthorized) == .sessionExpired)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 429)) == .rateLimited)
        // No body: use our own wording.
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 502)) == .providerUnavailable)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 404)) == .server(404))
        #expect(SubtitleDownloadError.classify(URLError(.timedOut)) == .timedOut)
        #expect(SubtitleDownloadError.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(SubtitleDownloadError.classify(SubtitleDownloadError.unsupportedFile) == .unsupportedFile)

        let permission = SubtitleDownloadError.notPermitted.errorDescription ?? ""
        // The message names the dashboard switch the administrator flips.
        #expect(permission.contains("Allow subtitle management"))
        // The quota wording must not appear on failures that are not quota.
        #expect(SubtitleDownloadError.notPermitted.errorDescription?.contains("download limit") == false)
        #expect(SubtitleDownloadError.timedOut.errorDescription?.contains("download limit") == false)
    }

    @Test func theServersOwnExplanationBeatsOneInventedHere() {
        // Jellyfin wraps a provider exception in a 500 with the real reason
        // in the body. Show that instead of guessing.
        let quota = JellyfinError.server(
            status: 500,
            message: "OpenSubtitles download limit reached for today"
        )
        let classified = SubtitleDownloadError.classify(quota)
        #expect(classified == .reported(status: 500, message: "OpenSubtitles download limit reached for today"))
        #expect(classified.localizedDescription.contains("download limit reached"))
        #expect(classified != .providerUnavailable)

        // Statuses we understand keep our own, actionable wording.
        #expect(SubtitleDownloadError.classify(
            JellyfinError.server(status: 403, message: "Forbidden")) == .notPermitted)
        #expect(SubtitleDownloadError.classify(
            JellyfinError.server(status: 401, message: "Unauthorized")) == .sessionExpired)

        // A reported 5xx is still transient; a reported 4xx is not.
        #expect(SubtitleDownloadError.reported(status: 503, message: "busy").isRetryable)
        #expect(!SubtitleDownloadError.reported(status: 400, message: "bad request").isRetryable)
    }

    @Test func aBodyCarryingResponseIsStillRecognisedByItsStatus() {
        // A 404 with a body is not `.server(404)`, so callers that key off 404
        // must branch on the status, not on case equality.
        let bare = SubtitleDownloadError.classify(JellyfinError.server(status: 404))
        let withBody = SubtitleDownloadError.classify(
            JellyfinError.server(status: 404, message: "Item not found"))
        #expect(bare.httpStatus == 404)
        #expect(withBody.httpStatus == 404)
        #expect(bare != withBody)
    }

    @Test func onlyBodiesThatSaySomethingAreShown() {
        let json = Data(#"{"detail":"Provider returned no results","status":500}"#.utf8)
        #expect(JellyfinClient.serverMessage(from: json) == "Provider returned no results")

        let plain = Data("  Download limit reached\n".utf8)
        #expect(JellyfinClient.serverMessage(from: plain) == "Download limit reached")

        // A real Jellyfin 403 is an HTML page; never show it.
        #expect(JellyfinClient.serverMessage(from: Data("<html><body>no</body></html>".utf8)) == nil)
        #expect(JellyfinClient.serverMessage(from: Data()) == nil)

        // Long bodies are truncated rather than filling the screen.
        let long = JellyfinClient.serverMessage(from: Data(String(repeating: "x", count: 400).utf8))
        #expect((long?.count ?? 0) <= 181)
    }

    @Test func subtitleRetriesOnlyCoverFastFailingTransientErrors() {
        // Retrying a 90 s timeout would leave a spinner up for minutes, and
        // retrying a rate limit inside seconds only spends more quota.
        #expect(SubtitleDownloadError.offline.isRetryable)
        #expect(SubtitleDownloadError.providerUnavailable.isRetryable)
        #expect(!SubtitleDownloadError.timedOut.isRetryable)
        #expect(!SubtitleDownloadError.rateLimited.isRetryable)
        #expect(!SubtitleDownloadError.notPermitted.isRetryable)
        #expect(!SubtitleDownloadError.sessionExpired.isRetryable)
        #expect(!SubtitleDownloadError.unsupportedFile.isRetryable)

        #expect(SubtitleRetryPolicy.shouldRetry(.offline, afterAttempt: 1))
        #expect(SubtitleRetryPolicy.shouldRetry(.offline, afterAttempt: 2))
        #expect(!SubtitleRetryPolicy.shouldRetry(.offline, afterAttempt: 3))
        #expect(!SubtitleRetryPolicy.shouldRetry(.notPermitted, afterAttempt: 1))
    }

    @Test @MainActor func aPermissionFailureOutranksWhicheverLanguageFailedFirst() {
        // Concurrent language searches complete out of order; a 403 explains
        // every sibling failure, so it must not be masked by a stray timeout.
        #expect(SubtitleSearchCoordinator.mostActionable([.timedOut, .notPermitted]) == .notPermitted)
        #expect(SubtitleSearchCoordinator.mostActionable([.server(500), .sessionExpired]) == .sessionExpired)
        #expect(SubtitleSearchCoordinator.mostActionable([.timedOut, .offline]) == .timedOut)
        #expect(SubtitleSearchCoordinator.mostActionable([]) == nil)
    }

    @Test func subtitleManagementOnlyBlocksWhenTheAnswerIsKnown() throws {
        let decode = { (json: String) in
            try JellyfinClient.decoder.decode(UserPolicy.self, from: Data(json.utf8))
        }
        #expect(try decode(#"{"EnableSubtitleManagement": true}"#).allowsSubtitleManagement)

        // The only case that blocks: told no, and not an administrator.
        #expect(try !decode(#"{"IsAdministrator": false, "EnableSubtitleManagement": false}"#).allowsSubtitleManagement)
        #expect(try !decode(#"{"EnableSubtitleManagement": false}"#).allowsSubtitleManagement)

        // Administrators pass regardless. Jellyfin hides the checkbox for
        // them, so their stored value is often false.
        #expect(try decode(#"{"IsAdministrator": true, "EnableSubtitleManagement": false}"#).allowsSubtitleManagement)
        #expect(try decode(#"{"IsAdministrator": true}"#).allowsSubtitleManagement)

        // Unknown is not a denial; the server answers 403 if it disagrees.
        #expect(try decode(#"{}"#).allowsSubtitleManagement)
        #expect(try decode(#"{"IsAdministrator": false}"#).allowsSubtitleManagement)
    }

    @Test @MainActor func downloadedSubtitleWaitsForRefreshAndMatchesRequestedLanguage() async throws {
        let stale = try playbackInfo(#"""
        { "MediaSources": [{
          "Id": "source-1",
          "MediaStreams": [
            { "Type": "Subtitle", "Index": 2, "Language": "eng", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/2/0/Stream.vtt" }
          ]
        }]}
        """#)
        let refreshed = try playbackInfo(#"""
        { "MediaSources": [{
          "Id": "source-1",
          "MediaStreams": [
            { "Type": "Subtitle", "Index": 2, "Language": "eng", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/2/0/Stream.vtt" },
            { "Type": "Subtitle", "Index": 3, "Language": "fra", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/3/0/Stream.vtt" },
            { "Type": "Subtitle", "Index": 4, "Language": "eng", "IsExternal": true,
              "DeliveryUrl": "/Videos/item/Subtitles/4/0/Stream.vtt" }
          ]
        }]}
        """#)
        let existingStream = try #require(stale.mediaSources.first?.mediaStreams?.first)
        var fetchCount = 0
        let poller = DownloadedSubtitlePoller(refreshDelays: [.zero, .zero])

        let stream = try await poller.waitForStream(
            mediaSourceID: "source-1",
            existingSignatures: [SubtitleStreamSignature(existingStream)],
            requestedLanguage: "eng"
        ) {
            fetchCount += 1
            return fetchCount == 1 ? stale : refreshed
        }

        #expect(fetchCount == 2)
        #expect(stream.index == 4)
        #expect(stream.language == "eng")
    }

    @Test @MainActor func downloadedSubtitleTimeoutHasSubtitleSpecificError() async throws {
        let stale = try playbackInfo(#"""
        { "MediaSources": [{ "Id": "source-1", "MediaStreams": [] }] }
        """#)
        let poller = DownloadedSubtitlePoller(refreshDelays: [.zero])

        do {
            _ = try await poller.waitForStream(
                mediaSourceID: "source-1",
                existingSignatures: [],
                requestedLanguage: "eng"
            ) { stale }
            Issue.record("Expected the subtitle refresh to time out")
        } catch let error as SubtitleDownloadError {
            #expect(error.errorDescription?.contains("subtitle") == true)
            #expect(error.errorDescription?.contains("device") == false)
        }
    }

    @Test @MainActor func preferencesStayScopedToTheirServerAccount() {
        let suiteName = "PlayerSystemIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SubtitlePreferencesStore(defaults: defaults)
        first.configure(accountID: "server-a:user")
        first.setPrimaryLanguage("et")
        var values = first.values
        values.edgeStyle = .outline
        values.followsSystemAppearance = false
        first.values = values

        let second = SubtitlePreferencesStore(defaults: defaults)
        second.configure(accountID: "server-b:user")
        #expect(second.values.followsSystemAppearance)
        #expect(second.values.languageOverrides.isEmpty)

        let restored = SubtitlePreferencesStore(defaults: defaults)
        restored.configure(accountID: "server-a:user")
        #expect(restored.values.languageOverrides.first == "et")
        #expect(restored.values.edgeStyle == .outline)
    }

    @Test @MainActor func systemCommandsUseIdempotentPlaybackState() {
        let engine = SampleBufferPlayerEngine()
        engine.pause()
        engine.pause()
        #expect(engine.isPaused)
        engine.play()
        engine.play()
        #expect(!engine.isPaused)
    }

    @Test @MainActor func playbackRateSurvivesPauseAndIsBounded() {
        let engine = SampleBufferPlayerEngine()
        engine.setRate(1.5)
        #expect(engine.rate == 1.5)
        engine.pause()
        engine.play()
        #expect(engine.rate == 1.5)
        engine.setRate(99)
        #expect(engine.rate == PlaybackRatePolicy.maximum)
        engine.setRate(.nan)
        #expect(engine.rate == 1)
    }

    @Test @MainActor func everyContentIconResolvesToARealSymbol() {
        // A missing SF Symbol renders as nothing, with no crash or warning.
        for name in [
            ContentIcon.home,
            ContentIcon.discover,
            ContentIcon.movies,
            ContentIcon.shows,
            ContentIcon.libraries,
            ContentIcon.search,
            ContentIcon.settings,
            ContentIcon.Settings.account,
            ContentIcon.Settings.playback,
            ContentIcon.Settings.audio,
            ContentIcon.Settings.subtitles,
            ContentIcon.Settings.advanced,
            ContentIcon.Settings.developer,
            ContentIcon.Settings.about,
            ContentIcon.library(collectionType: "tvshows"),
            ContentIcon.library(collectionType: "movies"),
            ContentIcon.library(collectionType: nil),
        ] {
            #expect(UIImage(systemName: name) != nil, "no SF Symbol named \(name)")
        }

        // Movies and Shows must not collapse to the same glyph, or the tabs
        // stop telling you which library you are in.
        #expect(ContentIcon.movies != ContentIcon.shows)
        #expect(ContentIcon.library(collectionType: "tvshows") == ContentIcon.shows)
        #expect(ContentIcon.library(collectionType: nil) == ContentIcon.movies)
    }

    @Test func playbackRateStepsAndRendersFromOnePlace() {
        // The panel, the title readout and the UI tests all read these.
        #expect(PlaybackRatePolicy.title(1) == "1×")
        #expect(PlaybackRatePolicy.title(1.25) == "1.25×")
        #expect(PlaybackRatePolicy.title(0.5) == "0.5×")
        // Remote Command Center can send a rate outside the set; it renders clamped.
        #expect(PlaybackRatePolicy.title(99) == "2×")

        // Stepping clamps, never wraps.
        #expect(PlaybackRatePolicy.stepped(from: 1, by: 1) == 1.25)
        #expect(PlaybackRatePolicy.stepped(from: 1, by: -1) == 0.75)
        #expect(PlaybackRatePolicy.stepped(from: 2, by: 1) == 2)
        #expect(PlaybackRatePolicy.stepped(from: 0.5, by: -1) == 0.5)
        // A value the engine accepts but the set does not contain still steps.
        #expect(PlaybackRatePolicy.stepped(from: 1.1, by: 1) == 1.25)
        #expect(PlaybackRatePolicy.stepped(from: 1.1, by: -1) == 1)

        #expect(PlaybackRatePolicy.identifier(1) == "1")
        #expect(PlaybackRatePolicy.identifier(1.25) == "1_25")
        #expect(PlaybackRatePolicy.identifier(0.75) == "0_75")
    }

    @Test func aSyncCorrectionRidesOnTheViewersRateWithoutLeavingTheEnvelope() {
        // A group nudge multiplies the viewer's rate; no correction leaves it alone.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1, correction: 1) == 1)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.5, correction: 1) == 1.5)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1, correction: 1.05) == 1.05)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 2, correction: 0.5) == 1)

        // The product stays inside the engine's rate envelope.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 2, correction: 4) == PlaybackRatePolicy.maximum)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 0.5, correction: 0.1) == PlaybackRatePolicy.minimum)
        // The viewer's rate is clamped before the correction applies.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 99, correction: 0.5) == 1)

        // A nonsense multiplier is ignored; stopping is `pause`, never a zero correction.
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: 0) == 1.25)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: -1) == 1.25)
        #expect(PlaybackRatePolicy.effectiveRate(userRate: 1.25, correction: .nan) == 1.25)
    }

    @Test @MainActor func aCorrectionRateLeavesTheViewersChosenRateAlone() {
        // The speed row and Now Playing show `rate`, so a nudge must not move it.
        let engine = SampleBufferPlayerEngine()
        engine.setRate(1.25)
        engine.setCorrectionRate(1.05)
        #expect(engine.rate == 1.25)
        #expect(engine.correctionRate == 1.05)
        engine.setCorrectionRate(1)
        #expect(engine.rate == 1.25)
        #expect(engine.correctionRate == 1)
    }

    @Test func stallRecoveryKeepsItsWallClockCushionAtFasterRates() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 12,
            videoQueueFinished: false,
            playbackRate: 1.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 18,
            videoQueueFinished: false,
            playbackRate: 1.5
        ) == .resume)
    }

    @Test @MainActor func everyAudioRendererSpatializesStereoTheWayAVPlayerDoes() {
        // `AVSampleBufferAudioRenderer` defaults to `multichannel` only, unlike
        // `AVPlayerItem`. The first check fails if a future SDK changes that.
        #expect(AVSampleBufferAudioRenderer().allowedAudioSpatializationFormats == .multichannel)
        #expect(
            SampleBufferPlayerEngine.makeAudioRenderer().allowedAudioSpatializationFormats
                == .monoStereoAndMultichannel
        )
        #expect(SampleBufferPlayerEngine.makeAudioRenderer().audioTimePitchAlgorithm == .timeDomain)
    }

    @Test func assResetOnlyClearsTheOverridesBeforeIt() throws {
        // Override tags apply left to right, so `{\i1\r}` ends up plain.
        let resetLast = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\b1\i1\r}Plain"#
        ))
        #expect(resetLast.usesDefaultStyle)

        let resetFirst = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\r\i1}Italic"#
        ))
        #expect(resetFirst.runs.first?.isItalic == true)
        #expect(resetFirst.runs.first?.isBold == false)

        // A reset keeps the alignment; placement is not an inline style.
        let placed = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\an8\b1\r}Top"#
        ))
        #expect(placed.alignment == .topCenter)
        #expect(placed.usesDefaultStyle)
    }

    @Test func ordinaryASSDialogueKeepsTheLegacyBottomCentrePresentation() throws {
        let cue = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,Hello\Nworld"#
        ))
        #expect(cue.text == "Hello\nworld")
        #expect(cue.usesDefaultPlacement)
        #expect(cue.usesDefaultStyle)
    }

    @Test @MainActor func aShutDownEngineCannotBeBroughtBackToLife() async {
        // SwiftUI re-mounts the player surface after a failure and `makeUIView`
        // attaches unconditionally. A shut-down engine must ignore it, or it
        // registers renderers that never detach and reopens the stream.
        let before = PlaybackLifecycleDiagnostics.snapshot()
        let engine = SampleBufferPlayerEngine()
        engine.prepare(
            url: URL(string: "https://media.test/never-opened.mkv")!,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        engine.shutdown()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())

        // Nothing registered, so nothing waits on an AVFoundation completion.
        let after = PlaybackLifecycleDiagnostics.snapshot()
        #expect(after.attachedRendererSets == before.attachedRendererSets)
        #expect(after.activeDemuxLoops == before.activeDemuxLoops)
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(5)))
    }

    @Test func onlyAMediaServicesResetLeavesThePlayerPaused() {
        // Apple requires waiting for the viewer after a media-services reset.
        // A renderer that failed on its own is replaced and resumes.
        #expect(AudioRendererReplacement.mediaServicesReset.staysPaused)
        #expect(!AudioRendererReplacement.rendererFailed.staysPaused)
    }

    @Test func aFailedAudioRendererReportsItsOwnReasonWhenItCannotBeReplaced() {
        // Reached only when replacement fails, so show AVFoundation's reason.
        #expect(
            AudioRendererReplacement.rendererFailed
                .failureMessage(detail: "The operation could not be completed")
                .contains("The operation could not be completed")
        )
        // No error: no empty parenthetical.
        let bare = AudioRendererReplacement.rendererFailed.failureMessage(detail: nil)
        #expect(!bare.contains("("))
        #expect(AudioRendererReplacement.rendererFailed.failureMessage(detail: "") == bare)
        // A reset states its cause; the renderer's error is noise.
        #expect(
            AudioRendererReplacement.mediaServicesReset.failureMessage(detail: "ignored")
                == "Playback audio could not recover after the media service restarted."
        )
    }

    @Test func stallRecoveryResumesOnlyWithACushionAndCannotWaitForever() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount - 1,
            videoQueueFinished: false
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: 0,
            videoQueueFinished: true
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: StallRecoveryPolicy.reprimeAfter,
            videoQueueCount: 0,
            videoQueueFinished: false
        ) == .reprime)
    }

    /// The credential travels as a header (`MediaRequestAuthorization`), so no
    /// resolved media URL carries `ApiKey` or `api_key`, even when the server put one in.
    @Test func playbackURLResolutionNeverCarriesTheCredentialInTheQuery() throws {
        let client = JellyfinClient(deviceId: "stream-resolution-test")
        client.configure(serverURL: URL(string: "https://media.test/jellyfin")!)
        client.activateSession(token: "token", userId: "user")

        let directPlay = try mediaSource(#"""
        {
          "Id":"direct", "Container":"mkv",
          "SupportsDirectPlay":true, "SupportsDirectStream":true
        }
        """#)
        let directPlayResult = try client.streamURL(itemId: "item", source: directPlay)
        #expect(directPlayResult.method == .directPlay)
        #expect(directPlayResult.url.path == "/jellyfin/Videos/item/stream")
        #expect(queryValue("ApiKey", in: directPlayResult.url) == nil)
        #expect(queryValue("api_key", in: directPlayResult.url) == nil)

        let directStream = try mediaSource(#"""
        {
          "Id":"remux", "Container":"mov,mp4,m4a",
          "SupportsDirectPlay":false, "SupportsDirectStream":true
        }
        """#)
        let directStreamResult = try client.streamURL(itemId: "item", source: directStream)
        #expect(directStreamResult.method == .directStream)
        #expect(directStreamResult.url.path == "/jellyfin/Videos/item/stream.mov")
        #expect(queryValue("ApiKey", in: directStreamResult.url) == nil)
        #expect(queryValue("api_key", in: directStreamResult.url) == nil)

        let transcode = try mediaSource(#"""
        {
          "Id":"hls", "SupportsDirectPlay":false, "SupportsDirectStream":false,
          "SupportsTranscoding":true,
          "TranscodingUrl":"/Videos/item/master.m3u8?PlaySessionId=session&api_key=legacy-token"
        }
        """#)
        let transcodeResult = try client.streamURL(itemId: "item", source: transcode)
        #expect(transcodeResult.method == .transcode)
        // A server-relative TranscodingUrl keeps the reverse-proxy base path.
        #expect(transcodeResult.url.path == "/jellyfin/Videos/item/master.m3u8")
        // The legacy token is stripped; other query items survive.
        #expect(queryValue("PlaySessionId", in: transcodeResult.url) == "session")
        #expect(queryValue("ApiKey", in: transcodeResult.url) == nil)
        #expect(queryValue("api_key", in: transcodeResult.url) == nil)

        let sidecar = try #require(client.externalSubtitleURL(
            deliveryUrl: "/Videos/item/source/Subtitles/2/0/Stream.srt?api_key=legacy-token"
        ))
        #expect(sidecar.path == "/jellyfin/Videos/item/source/Subtitles/2/0/Stream.srt")
        #expect(queryValue("ApiKey", in: sidecar) == nil)
        #expect(queryValue("api_key", in: sidecar) == nil)

        // A foreign origin is left untouched.
        let externalSidecar = try #require(client.externalSubtitleURL(
            deliveryUrl: "https://subtitles.example.test/item.srt"
        ))
        #expect(externalSidecar.absoluteString == "https://subtitles.example.test/item.srt")

        let tile = try JellyfinClient.decoder.decode(
            TrickplayTileInfo.self,
            from: Data(#"{"Width":320,"Height":180,"TileWidth":10,"TileHeight":10,"ThumbnailCount":1,"Interval":10000}"#.utf8)
        )
        let trickplay = try #require(client.trickplaySource(
            itemId: "item",
            mediaSourceId: "direct",
            extras: .init(chapters: [], trickplay: ["direct": ["320": tile]])
        ))
        let sheet = try #require(trickplay.sheetURLs.first)
        #expect(queryValue("ApiKey", in: sheet) == nil)
        #expect(queryValue("api_key", in: sheet) == nil)
        // The sheet fetch authenticates through the source's header.
        let sheetAuthorization = try #require(trickplay.authorization)
        #expect(sheetAuthorization.applies(to: sheet))
        #expect(sheetAuthorization.headerValue.contains("Token=\"token\""))
    }

    /// `serverRelativeURL` is what makes a base-path server work for the
    /// routes Jellyfin hands back inside response bodies.
    @Test func serverRelativeRoutesKeepTheBasePath() throws {
        let client = JellyfinClient(deviceId: "relative-route-test")

        client.configure(serverURL: URL(string: "https://media.test/jellyfin/")!)
        #expect(
            client.serverRelativeURL("/videos/abc/master.m3u8?PlaySessionId=s&x=1")?.absoluteString
                == "https://media.test/jellyfin/videos/abc/master.m3u8?PlaySessionId=s&x=1"
        )
        #expect(
            client.serverRelativeURL("videos/abc/main.m3u8")?.absoluteString
                == "https://media.test/jellyfin/videos/abc/main.m3u8"
        )
        // Percent-encoding in the reference survives as encoded bytes.
        #expect(
            client.serverRelativeURL("/Videos/it%20em/Subtitles/2/0/Stream.srt")?.absoluteString
                == "https://media.test/jellyfin/Videos/it%20em/Subtitles/2/0/Stream.srt"
        )
        // An absolute reference is returned as given, wherever it points.
        #expect(
            client.serverRelativeURL("https://cdn.example.test/seg.mp4?k=v")?.absoluteString
                == "https://cdn.example.test/seg.mp4?k=v"
        )

        client.configure(serverURL: URL(string: "https://media.test:8920")!)
        #expect(
            client.serverRelativeURL("/videos/abc/master.m3u8?PlaySessionId=s")?.absoluteString
                == "https://media.test:8920/videos/abc/master.m3u8?PlaySessionId=s"
        )
    }

    @Test func episodePosterUsesSeriesArtworkInsteadOfTheEpisodeStill() throws {
        let client = JellyfinClient(deviceId: "poster-resolution-test")
        client.configure(serverURL: URL(string: "https://media.test/jellyfin")!)
        let episode = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"""
            {
              "Id":"episode-1", "Type":"Episode", "SeriesId":"series-1",
              "ImageTags":{"Primary":"episode-still-tag"},
              "SeriesPrimaryImageTag":"series-poster-tag"
            }
            """#.utf8)
        )

        let poster = try #require(client.imageURL(for: episode, kind: .poster, maxWidth: 400))
        let still = try #require(client.imageURL(for: episode, kind: .primary, maxWidth: 400))

        #expect(poster.path == "/jellyfin/Items/series-1/Images/Primary")
        #expect(URLComponents(url: poster, resolvingAgainstBaseURL: false)?.queryItems?.contains {
            $0.name == "tag" && $0.value == "series-poster-tag"
        } == true)
        #expect(still.path == "/jellyfin/Items/episode-1/Images/Primary")
    }

    @Test func episodeHandoffWaitsForTheSpecificOutgoingPipeline() async {
        let outgoing = UUID()
        let unrelated = UUID()
        PlaybackLifecycleDiagnostics.demuxStarted(outgoing)
        PlaybackLifecycleDiagnostics.renderersAttached(outgoing)
        PlaybackLifecycleDiagnostics.demuxStarted(unrelated)
        defer {
            PlaybackLifecycleDiagnostics.demuxEnded(outgoing)
            PlaybackLifecycleDiagnostics.renderersDetached(outgoing)
            PlaybackLifecycleDiagnostics.demuxEnded(unrelated)
        }

        let retirement = Task {
            await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
                for: outgoing,
                timeout: .seconds(1)
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        PlaybackLifecycleDiagnostics.demuxEnded(outgoing)
        PlaybackLifecycleDiagnostics.renderersDetached(outgoing)

        #expect(await retirement.value)
        #expect(PlaybackLifecycleDiagnostics.snapshot().activeDemuxLoops >= 1)
    }

    @Test func episodeHandoffRetirementTimeoutCannotBecomeSuccess() async {
        let outgoing = UUID()
        PlaybackLifecycleDiagnostics.renderersAttached(outgoing)
        defer { PlaybackLifecycleDiagnostics.renderersDetached(outgoing) }

        let retired = await PlaybackLifecycleDiagnostics.waitForMediaResourcesToRetire(
            for: outgoing,
            timeout: .milliseconds(20)
        )

        #expect(!retired)
    }

    @Test @MainActor func downloadedSubtitleIsInsertedAndSelectedAtRuntime() async throws {
        let engine = SampleBufferPlayerEngine()
        defer { engine.shutdown() }
        engine.addExternalSubtitle(ExternalSubtitleTrack(
            url: URL(string: "https://example.invalid/subtitle.vtt")!,
            preloadedData: Data("WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nHello\n".utf8),
            title: "English SDH",
            language: "eng",
            select: true,
            isHearingImpaired: true,
            isDownloaded: true
        ))
        #expect(engine.subtitleTracks.count == 1)
        try await waitUntil { engine.subtitleTracks[0].isSelected }
        #expect(engine.subtitleTracks[0].isSelected)
        #expect(engine.subtitleTracks[0].source == .downloaded)
        #expect(engine.subtitleTracks[0].isHearingImpaired)
    }

    @Test @MainActor func remoteSubtitleUserFlowDownloadsValidCuesAndActivatesTrack() async throws {
        SubtitleDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleDownloadURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "subtitle-download-test",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://subtitle.test")!)
        client.activateSession(token: "test-token", userId: "user-1")

        let engine = SampleBufferPlayerEngine()
        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        let addedStreams = AddedStreams()
        coordinator.configure(
            client: client,
            engine: engine,
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { addedStreams.streams.append($0) }
        )

        // The same sequence as the in-player Find Subtitles button.
        coordinator.startSearch()
        try await waitUntil { !coordinator.results.isEmpty }
        let result = try #require(coordinator.results.first)
        coordinator.startDownload(result)
        try await waitUntil { coordinator.phase == .downloaded }
        // No server stream exists yet, but the controller needs one entry per
        // engine track to carry the choice into the next episode.
        let added = try #require(addedStreams.streams.first)
        #expect(addedStreams.streams.count == 1)
        #expect(added.type == "Subtitle")
        #expect(added.language == "eng")
        #expect(added.displayTitle == result.name)
        #expect(added.isExternal == true)
        #expect(added.isHearingImpaired == true)
        try await waitUntil {
            SubtitleDownloadURLProtocol.requests.contains {
                $0.method == "POST" && $0.path == "/Videos/item-1/Subtitles"
            }
        }

        let track = try #require(engine.subtitleTracks.first)
        #expect(track.isSelected)
        #expect(track.source == .downloaded)
        #expect(track.languageTag == "eng")
        #expect(track.isHearingImpaired)

        let requests = SubtitleDownloadURLProtocol.requests
        #expect(requests.contains {
            $0.method == "GET"
                && $0.path == "/Items/item-1/RemoteSearch/Subtitles/eng"
        })
        #expect(requests.contains {
            $0.method == "GET"
                && $0.percentEncodedPath
                    == "/Providers/Subtitles/Subtitles/srt-eng-42%2Fprovider%3Fpart%23100%25"
                && $0.query == nil
        })
        let upload = try #require(requests.first {
            $0.method == "POST" && $0.path == "/Videos/item-1/Subtitles"
        })
        #expect(upload.body?.contains(#""Format":"vtt""#) == true)
        #expect(upload.body?.contains(#""Language":"eng""#) == true)
        #expect(upload.body?.contains(#""IsHearingImpaired":true"#) == true)
        #expect(!requests.contains {
            $0.method == "POST" && $0.path.contains("RemoteSearch/Subtitles")
        })
        #expect(requests.allSatisfy { $0.authorization?.contains(#"Token="test-token""#) == true })
    }

    @Test @MainActor func remoteSubtitleSearchKeepsResultsWhenAnotherLanguageFails() async throws {
        SubtitleDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleDownloadURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "subtitle-search-test",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://subtitle.test")!)
        client.activateSession(token: "test-token", userId: "user-1")

        let coordinator = SubtitleSearchCoordinator()
        coordinator.configure(
            client: client,
            engine: SampleBufferPlayerEngine(),
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["fr", "en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        coordinator.startSearch()
        try await waitUntil { coordinator.phase != .searching }

        #expect(coordinator.phase == .idle)
        #expect(coordinator.results.count == 2)
        #expect(SubtitleDownloadURLProtocol.requests.contains {
            $0.path == "/Items/item-1/RemoteSearch/Subtitles/fra"
        })
        #expect(SubtitleDownloadURLProtocol.requests.contains {
            $0.path == "/Items/item-1/RemoteSearch/Subtitles/eng"
        })
    }

    @Test @MainActor func anAccountWithoutSubtitleManagementIsToldSoBeforeAnyRequest() async throws {
        SubtitleDownloadURLProtocol.reset(subtitleManagement: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleDownloadURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "subtitle-permission-test",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://subtitle.test")!)
        client.activateSession(token: "test-token", userId: "user-1")

        let coordinator = SubtitleSearchCoordinator()
        coordinator.configure(
            client: client,
            engine: SampleBufferPlayerEngine(),
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en", "fr"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        coordinator.startSearch()
        try await waitUntil { coordinator.phase != .searching }

        // Jellyfin answers 403 to every remote subtitle endpoint without this
        // permission, so check once and spend no provider request.
        #expect(coordinator.phase == .notPermitted)
        #expect(coordinator.results.isEmpty)
        #expect(!SubtitleDownloadURLProtocol.requests.contains {
            $0.path.contains("RemoteSearch")
        })
    }

    @Test @MainActor func aForbiddenProviderFetchNeverRetriesThroughJellyfin() async throws {
        SubtitleDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleDownloadURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "subtitle-forbidden-test",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://subtitle.test")!)
        client.activateSession(token: "test-token", userId: "user-1")

        let engine = SampleBufferPlayerEngine()
        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        coordinator.configure(
            client: client,
            engine: engine,
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        let forbidden = try JellyfinClient.decoder.decode(
            RemoteSubtitleInfo.self,
            from: Data(#"{ "Id": "forbidden-file", "Name": "Forbidden", "ThreeLetterISOLanguageName": "eng", "ProviderName": "Test Provider", "Format": "srt" }"#.utf8)
        )
        coordinator.startDownload(SubtitleCandidate(forbidden))
        try await waitUntil { coordinator.phase == .notPermitted }

        // Jellyfin's save path refetches from the provider; after a 403 that
        // only spends quota.
        #expect(!SubtitleDownloadURLProtocol.requests.contains {
            $0.method == "POST" && $0.path.contains("RemoteSearch")
        })
        #expect(engine.subtitleTracks.isEmpty)
    }

    @Test @MainActor func missingProviderFileExplainsRemovalOrDownloadLimit() async throws {
        SubtitleDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubtitleDownloadURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "subtitle-failure-test",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://subtitle.test")!)
        client.activateSession(token: "test-token", userId: "user-1")

        let engine = SampleBufferPlayerEngine()
        let coordinator = SubtitleSearchCoordinator(
            downloadedSubtitlePoller: DownloadedSubtitlePoller(refreshDelays: [.zero])
        )
        coordinator.configure(
            client: client,
            engine: engine,
            itemID: "item-1",
            mediaSourceID: "source-1",
            streams: [],
            preferredLanguages: ["en"],
            missingMode: .ask,
            hasSuitableLocalTrack: false,
            onTrackAdded: { _ in }
        )
        coordinator.startSearch()
        try await waitUntil { coordinator.results.count == 2 }
        // Candidate ids are namespaced by source, so match on providerID.
        let missing = try #require(coordinator.results.first { $0.providerID == "missing-provider-file" })
        coordinator.startDownload(missing)
        try await waitUntil {
            if case .downloadFailed = coordinator.phase { return true }
            return false
        }

        guard case .downloadFailed(let message) = coordinator.phase else {
            Issue.record("Expected a provider-specific download failure")
            return
        }
        #expect(message.contains("removed"))
        #expect(message.contains("download limit"))
        #expect(engine.subtitleTracks.isEmpty)
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 200,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the subtitle workflow")
    }

    private func playbackInfo(_ json: String) throws -> PlaybackInfoResponse {
        try JellyfinClient.decoder.decode(PlaybackInfoResponse.self, from: Data(json.utf8))
    }

    private func mediaSource(_ json: String) throws -> MediaSource {
        try JellyfinClient.decoder.decode(MediaSource.self, from: Data(json.utf8))
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

private nonisolated struct RecordedSubtitleRequest: Sendable {
    let method: String
    let path: String
    let percentEncodedPath: String
    let query: String?
    let authorization: String?
    let body: String?
}

/// Fake Jellyfin transport. PlaybackInfo stays stale, so the coordinator must
/// fetch and parse the provider's bytes before activating the track.
private nonisolated final class SubtitleDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedRequests: [RecordedSubtitleRequest] = []

    static var requests: [RecordedSubtitleRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private nonisolated(unsafe) static var userPolicyPayload = #"{ "Id": "user-1", "Name": "Tester", "Policy": { "IsAdministrator": false, "EnableSubtitleManagement": true } }"#

    static func reset(subtitleManagement: Bool = true) {
        lock.lock()
        recordedRequests = []
        userPolicyPayload = #"{ "Id": "user-1", "Name": "Tester", "Policy": { "IsAdministrator": false, "EnableSubtitleManagement": \#(subtitleManagement) } }"#
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "subtitle.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let percentEncodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath ?? url.path
        Self.lock.lock()
        Self.recordedRequests.append(RecordedSubtitleRequest(
            method: request.httpMethod ?? "GET",
            path: url.path,
            percentEncodedPath: percentEncodedPath,
            query: url.query,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: bodyString(from: request)
        ))
        Self.lock.unlock()

        let payload: Data
        let status: Int
        switch (request.httpMethod ?? "GET", percentEncodedPath) {
        case ("GET", "/Items/item-1/RemoteSearch/Subtitles/eng"):
            payload = Data(#"""
            [{
              "Id": "srt-eng-42/provider?part#100%",
              "Name": "English provider subtitle",
              "ThreeLetterISOLanguageName": "eng",
              "ProviderName": "Test Provider",
              "Format": "vtt",
              "HearingImpaired": true
            }, {
              "Id": "missing-provider-file",
              "Name": "Deleted provider subtitle",
              "ThreeLetterISOLanguageName": "eng",
              "ProviderName": "Test Provider",
              "Format": "srt"
            }]
            """#.utf8)
            status = 200
        case ("GET", "/Items/item-1/RemoteSearch/Subtitles/fra"):
            payload = Data()
            status = 500
        case ("POST", "/Items/item-1/PlaybackInfo"):
            payload = Data(#"{ "MediaSources": [{ "Id": "source-1", "MediaStreams": [] }] }"#.utf8)
            status = 200
        case ("GET", "/Providers/Subtitles/Subtitles/srt-eng-42%2Fprovider%3Fpart%23100%25"):
            payload = Data(#"""
            WEBVTT

            00:00:00.000 --> 00:00:02.000
            Downloaded subtitle cue
            """#.utf8)
            status = 200
        case ("GET", "/Providers/Subtitles/Subtitles/missing-provider-file"):
            payload = Data()
            status = 404
        case ("GET", "/Providers/Subtitles/Subtitles/forbidden-file"):
            payload = Data()
            status = 403
        case ("GET", "/Users/Me"):
            payload = Data(Self.userPolicyPayload.utf8)
            status = 200
        case ("POST", "/Items/item-1/RemoteSearch/Subtitles/missing-provider-file"):
            // Jellyfin 10.11 returns 204 even when its internal provider
            // operation throws; PlaybackInfo remains stale below.
            payload = Data()
            status = 204
        case ("POST", "/Videos/item-1/Subtitles"):
            payload = Data()
            status = 204
        default:
            payload = Data()
            status = 404
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": url.path.hasPrefix("/Providers/Subtitles/Subtitles/") && status == 200
                          ? "application/x-subrip" : "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty {
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Empty audio must count as starvation, or a film plays silent while every
/// indicator reads healthy.
@Suite("Playback starvation")
struct PlaybackStarvationTests {
    private func healthy(
        _ mutate: (inout PlaybackStarvationPolicy.Snapshot) -> Void = { _ in }
    ) -> PlaybackStarvationPolicy.Snapshot {
        var snapshot = PlaybackStarvationPolicy.Snapshot()
        snapshot.position = 100
        snapshot.duration = 6_000
        snapshot.rate = 1
        snapshot.videoQueueCount = 30
        snapshot.videoBufferedTo = 130
        snapshot.hasAudio = true
        snapshot.audioDeliveryLeadSeconds = 2
        mutate(&snapshot)
        return snapshot
    }

    @Test func healthyPlaybackIsNotStarved() {
        #expect(PlaybackStarvationPolicy.starvation(healthy()) == .none)
    }

    /// Video is full but the renderer has consumed every audio sample. App
    /// queue depth plays no part.
    @Test func exhaustedRendererAudioLeadIsStarvationEvenWithVideoFull() {
        let snapshot = healthy {
            $0.videoQueueCount = 30
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .audio)
    }

    /// Lead is measured at the renderer; Lagoon's own queue is ignored.
    @Test func audioIsJudgedOnRendererDeliveryLead() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = PlaybackStarvationPolicy.audioFloorSeconds + 0.01
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = PlaybackStarvationPolicy.audioFloorSeconds - 0.01
        }) == .audio)
    }

    @Test func audioCannotBeCalledStarvedBeforeTheRendererReceivesItsFirstSample() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = nil
        }) == .none)
    }

    /// Both dry reports video: it is the half the viewer can see freeze,
    /// and the recovery wanted is the same either way.
    @Test func videoWinsWhenBothAreDry() {
        let snapshot = healthy {
            $0.videoQueueCount = 0
            $0.videoBufferedTo = $0.position
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .video)
    }

    /// A silent film cannot starve for sound, and must not be held in
    /// buffering waiting for a cushion that will never arrive.
    @Test func aTitleWithoutAudioNeverStarvesOnIt() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.hasAudio = false
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioQueueFinished = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
    }

    /// The margin is media time, so it has to scale with rate to keep the
    /// same wall-clock cushion.
    @Test func theAudioFloorScalesWithPlaybackRate() {
        let justOverAt1x = PlaybackStarvationPolicy.audioFloorSeconds + 0.01
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.audioDeliveryLeadSeconds = justOverAt1x
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.rate = 2
            $0.audioDeliveryLeadSeconds = justOverAt1x
        }) == .audio)
    }

    @Test func statesThatCannotStarve() {
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.isPaused = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.isBuffering = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.didFinish = true
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
        #expect(PlaybackStarvationPolicy.starvation(healthy {
            $0.position = $0.duration - 0.5
            $0.audioDeliveryLeadSeconds = 0
        }) == .none)
    }

    // MARK: - Why audio does not stop the clock

    /// Audio gates recovery only when the engine sets `audioRequired`.
    /// Unset, video decides alone.
    @Test func recoveryDependsOnVideoAlone() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount - 1,
            videoQueueFinished: false
        ) == .wait)
    }

    /// Audio starvation is still detected for the counter and HUD, but never
    /// stops the picture.
    @Test func audioStarvationIsStillReportedEvenThoughItNeverStopsTheClock() {
        let snapshot = healthy {
            $0.videoQueueCount = 30
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .audio)
    }

    // MARK: - Buffering on audio starvation(off by default)

    @Test func confirmsGatesAudioOnTheModeAndAlwaysConfirmsVideo() {
        #expect(StallRecoveryPolicy.confirms(.video, buffersOnAudioStarvation: false))
        #expect(StallRecoveryPolicy.confirms(.video, buffersOnAudioStarvation: true))
        #expect(!StallRecoveryPolicy.confirms(.audio, buffersOnAudioStarvation: false))
        #expect(StallRecoveryPolicy.confirms(.audio, buffersOnAudioStarvation: true))
        #expect(!StallRecoveryPolicy.confirms(.none, buffersOnAudioStarvation: false))
        #expect(!StallRecoveryPolicy.confirms(.none, buffersOnAudioStarvation: true))
    }

    /// With `audioRequired` true, resume needs the renderer's own lead back
    /// as well as the video cushion; either missing waits, and a wait long
    /// enough still falls back to reprime.
    @Test func audioRequiredResumeNeedsBothQueuesReady() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.0
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: nil
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: StallRecoveryPolicy.reprimeAfter,
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.5
        ) == .reprime)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount - 1,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 3.0
        ) == .wait)
    }

    /// The renderer's own readiness flag lets a resume through once the
    /// lead clears `resumeAudioLeadFloorSeconds`, without waiting for the
    /// full-second fallback; without the flag, only the full second does.
    @Test func rendererReadinessFlagResumesAboveTheFloor() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.6,
            audioRendererHasSufficientData: true
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.2,
            audioRendererHasSufficientData: true
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.6,
            audioRendererHasSufficientData: false
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.0,
            audioRendererHasSufficientData: false
        ) == .resume)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: true,
            audioDeliveryLeadSeconds: nil,
            audioRendererHasSufficientData: true
        ) == .wait)
        let requiredAtDoubleRate = Int(ceil(Double(StallRecoveryPolicy.resumeVideoCount) * 2))
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 0.9,
            audioRendererHasSufficientData: true
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.0,
            audioRendererHasSufficientData: true
        ) == .resume)
    }

    /// The mode-off contract: with `audioRequired` false, a dry renderer
    /// never blocks a video-ready resume.
    @Test func audioNotRequiredResumesOnVideoAloneWithNoLead() {
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: StallRecoveryPolicy.resumeVideoCount,
            videoQueueFinished: false,
            audioRequired: false,
            audioDeliveryLeadSeconds: 0
        ) == .resume)
    }

    /// The audio lead floor scales with rate exactly as the video cushion
    /// does.
    @Test func audioLeadFloorScalesWithPlaybackRate() {
        let requiredAtDoubleRate = StallRecoveryPolicy.resumeVideoCount * 2
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 1.5
        ) == .wait)
        #expect(StallRecoveryPolicy.decision(
            elapsed: .seconds(1),
            videoQueueCount: requiredAtDoubleRate,
            videoQueueFinished: false,
            playbackRate: 2,
            audioRequired: true,
            audioDeliveryLeadSeconds: 2.0
        ) == .resume)
    }
}

@Suite("Uncached delivery cushion")
struct UncachedDeliveryCushionTests {
}

/// A Jellyfin HLS fragment's `mdat` holds all its video before its audio, so
/// the decoded video queue fills before any audio is read. When that queue is
/// full and `audioCanCoverDrain` is false, the loop reads on for audio into a
/// compressed-packet intake, until the audio queue reaches high water or the
/// intake hits its count or byte bound. Then it falls back to pacing one slot
/// below the hard limit.
@Suite("Demux read-ahead for a starving audio track")
struct DemuxReadAheadPolicyTests {
}

@MainActor
private final class AddedStreams {
    var streams: [MediaStream] = []
}
