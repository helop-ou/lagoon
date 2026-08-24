import AVFAudio
import AVFoundation
import UIKit
import Foundation
import Testing
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
        // The whole point of HEL-91: a 403 is a server permission, not an
        // exhausted provider quota, and the two need different answers.
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 403)) == .notPermitted)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 401)) == .sessionExpired)
        #expect(SubtitleDownloadError.classify(JellyfinError.unauthorized) == .sessionExpired)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 429)) == .rateLimited)
        // No body: nothing better to say than our own wording.
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 502)) == .providerUnavailable)
        #expect(SubtitleDownloadError.classify(JellyfinError.server(status: 404)) == .server(404))
        #expect(SubtitleDownloadError.classify(URLError(.timedOut)) == .timedOut)
        #expect(SubtitleDownloadError.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(SubtitleDownloadError.classify(SubtitleDownloadError.unsupportedFile) == .unsupportedFile)

        let permission = try? #require(SubtitleDownloadError.notPermitted.errorDescription)
        #expect(permission?.contains("Subtitle Management") == true)
        // The quota wording must not appear on failures that are not quota.
        #expect(SubtitleDownloadError.notPermitted.errorDescription?.contains("download limit") == false)
        #expect(SubtitleDownloadError.timedOut.errorDescription?.contains("download limit") == false)
    }

    @Test func theServersOwnExplanationBeatsOneInventedHere() {
        // The reported case: an admin who could search but whose download
        // failed got "the provider could not supply this file — it may have
        // been removed or the limit reached", which is two guesses. Jellyfin
        // wraps the provider's exception into a 500 and puts the real reason
        // in the body; it was being discarded (HEL-98).
        let quota = JellyfinError.server(
            status: 500,
            message: "OpenSubtitles download limit reached for today"
        )
        let classified = SubtitleDownloadError.classify(quota)
        #expect(classified == .reported(status: 500, message: "OpenSubtitles download limit reached for today"))
        #expect(classified.localizedDescription.contains("download limit reached"))
        // Not the hedge it used to be.
        #expect(classified != .providerUnavailable)

        // Statuses we understand keep our wording, which is better than the
        // server's terse one and is actionable.
        #expect(SubtitleDownloadError.classify(
            JellyfinError.server(status: 403, message: "Forbidden")) == .notPermitted)
        #expect(SubtitleDownloadError.classify(
            JellyfinError.server(status: 401, message: "Unauthorized")) == .sessionExpired)

        // A reported 5xx is still transient; a reported 4xx is not.
        #expect(SubtitleDownloadError.reported(status: 503, message: "busy").isRetryable)
        #expect(!SubtitleDownloadError.reported(status: 400, message: "bad request").isRetryable)
    }

    @Test func aBodyCarryingResponseIsStillRecognisedByItsStatus() {
        // The compatibility fallback and the item-missing branch key off 404.
        // Once a 404 can carry a message it is no longer `.server(404)`, so
        // they have to branch on the status instead of on case equality.
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

        // The 403 from a real Jellyfin is an HTML page — chrome, not an
        // explanation, and it must not be pasted into the UI.
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

        // Administrators pass regardless of the flag. Jellyfin hides the
        // checkbox for them because the permission is implied, so an admin's
        // stored value is routinely false — reading that as a denial locked
        // administrators out of their own servers (HEL-96).
        #expect(try decode(#"{"IsAdministrator": true, "EnableSubtitleManagement": false}"#).allowsSubtitleManagement)
        #expect(try decode(#"{"IsAdministrator": true}"#).allowsSubtitleManagement)

        // Unknown is not a denial: the server is the authority and answers
        // 403 if it disagrees, which HEL-91 reports properly.
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

    @Test func remoteSubtitleFallbackAcceptsTextCuesAndRejectsOtherFiles() {
        let srt = Data("1\n00:00:01,000 --> 00:00:03,000\nFallback works\n".utf8)
        let utf16 = "1\n00:00:01,000 --> 00:00:03,000\nUTF-16 works\n"
            .data(using: .utf16)!
        #expect(SubtitleParser.cues(from: srt).count == 1)
        #expect(SubtitleParser.cues(from: utf16).count == 1)
        #expect(SubtitleParser.cues(from: Data("not a subtitle".utf8)).isEmpty)
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
        // A symbol that does not exist on this OS renders as nothing at all —
        // no crash, no warning, just a hole in the tab bar. Naming them in one
        // place is only half the fix; this is the other half.
        for name in [
            ContentIcon.home,
            ContentIcon.discover,
            ContentIcon.movies,
            ContentIcon.shows,
            ContentIcon.libraries,
            ContentIcon.settings,
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

    @Test func playbackRateTitlesAndIdentifiersAreStable() {
        // The panel's rows, the readout beside the player's title and the UI
        // test's accessibility queries all read from these, so they cannot
        // drift apart.
        #expect(PlaybackRatePolicy.title(1) == "1×")
        #expect(PlaybackRatePolicy.title(1.25) == "1.25×")
        #expect(PlaybackRatePolicy.title(0.5) == "0.5×")
        // Remote Command Center can hand the engine a value outside the set;
        // it is still rendered, and still clamped.
        #expect(PlaybackRatePolicy.title(99) == "2×")

        #expect(PlaybackRatePolicy.identifier(1) == "1")
        #expect(PlaybackRatePolicy.identifier(1.25) == "1_25")
        #expect(PlaybackRatePolicy.identifier(0.75) == "0_75")
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
        // Apple's two players disagree on the default, and the sample-buffer
        // one is the stingier: `AVPlayerItem` documents
        // `monoStereoAndMultichannel` for video content, while
        // `AVSampleBufferAudioRenderer` documents `multichannel` alone. The
        // first expectation pins that difference — if a future SDK closes it,
        // this test says so and the override becomes redundant.
        #expect(AVSampleBufferAudioRenderer().allowedAudioSpatializationFormats == .multichannel)
        #expect(
            SampleBufferPlayerEngine.makeAudioRenderer().allowedAudioSpatializationFormats
                == .monoStereoAndMultichannel
        )
        #expect(SampleBufferPlayerEngine.makeAudioRenderer().audioTimePitchAlgorithm == .timeDomain)
    }

    @Test func assOverrideSubsetPreservesPlacementAndInlineStyle() throws {
        let resolution = ASSSubtitleTextParser.playResolution(from: """
        [Script Info]
        PlayResX: 1920
        PlayResY: 1080
        """)
        #expect(resolution == ASSPlayResolution(width: 1920, height: 1080))

        let cue = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\an7\pos(1280,180)\b1\i1\c&H332211&}Top{\b0\i0} sign"#,
            playResolution: resolution
        ))
        #expect(cue.alignment == .topLeft)
        #expect(abs((cue.position?.x ?? 0) - (2.0 / 3.0)) < 0.000_001)
        #expect(abs((cue.position?.y ?? 0) - (1.0 / 6.0)) < 0.000_001)
        #expect(cue.text == "Top sign")
        #expect(cue.runs.count == 2)
        #expect(cue.runs[0] == SubtitleTextRun(
            text: "Top",
            primaryColor: SubtitleTextColor(red: 0x11, green: 0x22, blue: 0x33, alpha: 0xFF),
            isBold: true,
            isItalic: true
        ))
        #expect(cue.runs[1].text == " sign")
        #expect(!cue.runs[1].isBold)
        #expect(!cue.runs[1].isItalic)
    }

    @Test func assResetOnlyClearsTheOverridesBeforeIt() throws {
        // Override tags apply left to right, so where the reset sits decides
        // what survives it. Reading style tags from the whole block made
        // `{\i1\r}` italic, which is the one thing it cannot be.
        let resetLast = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\b1\i1\r}Plain"#
        ))
        #expect(resetLast.usesDefaultStyle)

        let resetFirst = try #require(ASSSubtitleTextParser.cue(
            from: #"0,0,Default,,0,0,0,,{\r\i1}Italic"#
        ))
        #expect(resetFirst.runs.first?.isItalic == true)
        #expect(resetFirst.runs.first?.isBold == false)

        // Placement is not part of the inline style table, so a reset in the
        // same block must not take the alignment with it.
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

    @Test func subtitleStoreKeepsSimultaneousAuthoredCompositionsSeparate() {
        let store = SubtitleStore()
        let left = SubtitleTextCue(
            runs: [SubtitleTextRun(text: "Left")],
            alignment: .middleLeft,
            position: nil
        )
        let right = SubtitleTextCue(
            runs: [SubtitleTextRun(text: "Right")],
            alignment: .middleRight,
            position: nil
        )
        store.add(SubtitleCue(start: 1, end: 3, textCues: [left], images: []))
        store.add(SubtitleCue(start: 1, end: 3, textCues: [right], images: []))

        #expect(store.active(at: 2).textCues == [left, right])
    }

    @Test @MainActor func aShutDownEngineCannotBeBroughtBackToLife() async {
        // SwiftUI re-mounts the player surface after a failed playback, and
        // `makeUIView` attaches unconditionally. `finishRendererShutdown`
        // nils the renderer, so an emptiness check alone let a retired engine
        // pass: it re-registered a renderer set that could never detach — its
        // `shutdown` early-returns once requested — and started a second
        // demux loop that reopened the stream, server transcode and all
        // (HEL-110).
        let before = PlaybackLifecycleDiagnostics.snapshot()
        let engine = SampleBufferPlayerEngine()
        engine.prepare(
            url: URL(string: "https://media.test/never-opened.mkv")!,
            startSeconds: 0,
            initialAudioOrdinal: nil
        )
        engine.shutdown()
        engine.attach(displayLayer: AVSampleBufferDisplayLayer())

        // Nothing was registered, so nothing is left needing an asynchronous
        // AVFoundation completion to balance it.
        let after = PlaybackLifecycleDiagnostics.snapshot()
        #expect(after.attachedRendererSets == before.attachedRendererSets)
        #expect(after.activeDemuxLoops == before.activeDemuxLoops)
        #expect(await engine.waitForMediaResourcesToRetire(timeout: .seconds(5)))
    }

    @Test func onlyAMediaServicesResetLeavesThePlayerPaused() {
        // Apple requires an app to wait for an explicit viewer action after a
        // media-services reset, so that replacement stays paused. A renderer
        // that failed on its own is nothing the viewer did or can fix, and
        // resuming is the whole point of replacing it.
        #expect(AudioRendererReplacement.mediaServicesReset.staysPaused)
        #expect(!AudioRendererReplacement.rendererFailed.staysPaused)
    }

    @Test func aFailedAudioRendererReportsItsOwnReasonWhenItCannotBeReplaced() {
        // Reached only when the replacement itself fails, which leaves
        // playback with no audio path at all — so the message has to carry
        // whatever AVFoundation said rather than a guess of ours.
        #expect(
            AudioRendererReplacement.rendererFailed
                .failureMessage(detail: "The operation could not be completed")
                .contains("The operation could not be completed")
        )
        // No error attached is the common case: say what happened, without a
        // dangling empty parenthetical.
        let bare = AudioRendererReplacement.rendererFailed.failureMessage(detail: nil)
        #expect(!bare.contains("("))
        #expect(AudioRendererReplacement.rendererFailed.failureMessage(detail: "") == bare)
        // A reset says why it happened; the renderer's own error is noise
        // next to "the media service restarted".
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

    @Test func playbackURLResolutionPreservesTheNegotiatedTransportMatrix() throws {
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

        let directStream = try mediaSource(#"""
        {
          "Id":"remux", "Container":"mov,mp4,m4a",
          "SupportsDirectPlay":false, "SupportsDirectStream":true
        }
        """#)
        let directStreamResult = try client.streamURL(itemId: "item", source: directStream)
        #expect(directStreamResult.method == .directStream)
        #expect(directStreamResult.url.path == "/jellyfin/Videos/item/stream.mov")

        let transcode = try mediaSource(#"""
        {
          "Id":"hls", "SupportsDirectPlay":false, "SupportsDirectStream":false,
          "SupportsTranscoding":true,
          "TranscodingUrl":"/Videos/item/master.m3u8?PlaySessionId=session"
        }
        """#)
        let transcodeResult = try client.streamURL(itemId: "item", source: transcode)
        #expect(transcodeResult.method == .transcode)
        #expect(transcodeResult.url.path == "/Videos/item/master.m3u8")
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

    @Test @MainActor func downloadedSubtitleIsInsertedAndSelectedAtRuntime() {
        let engine = SampleBufferPlayerEngine()
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

        // This is the same search/download sequence triggered by the
        // in-player Find Subtitles result button.
        coordinator.startSearch()
        try await waitUntil { !coordinator.results.isEmpty }
        let result = try #require(coordinator.results.first)
        coordinator.startDownload(result)
        try await waitUntil { coordinator.phase == .downloaded }
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
                && $0.query == "api_key=test-token"
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
        // permission. Asking once means the viewer is told what is actually
        // wrong, and no provider request is spent discovering it.
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

        // Jellyfin's save path fetches from the provider a second time, so it
        // must not run for a failure no retry could fix: that only spends the
        // provider's download quota on the way to the same 403.
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
        // Candidate ids are namespaced by source now that results can come
        // from Jellyfin or the provider directly.
        let missing = try #require(coordinator.results.first { $0.jellyfinID == "missing-provider-file" })
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
}

private nonisolated struct RecordedSubtitleRequest: Sendable {
    let method: String
    let path: String
    let percentEncodedPath: String
    let query: String?
    let authorization: String?
    let body: String?
}

/// A deterministic Jellyfin transport for the complete user download flow.
/// PlaybackInfo deliberately remains stale so the coordinator must fetch and
/// parse the provider's real subtitle bytes before activating the track.
private nonisolated final class SubtitleDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedRequests: [RecordedSubtitleRequest] = []

    static var requests: [RecordedSubtitleRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    /// Mirrors Jellyfin's own default: a non-administrator has subtitle
    /// management switched off unless someone turns it on.
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
            headerFields: ["Content-Type": "application/json"]
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
