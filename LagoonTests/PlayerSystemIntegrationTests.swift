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
        // HEL-146: the message names the dashboard switch the administrator flips.
        #expect(permission?.contains("Allow subtitle management") == true)
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
        // The panel's rows, the readout beside the player's title and the UI
        // test's accessibility queries all read from these, so they cannot
        // drift apart.
        #expect(PlaybackRatePolicy.title(1) == "1×")
        #expect(PlaybackRatePolicy.title(1.25) == "1.25×")
        #expect(PlaybackRatePolicy.title(0.5) == "0.5×")
        // Remote Command Center can hand the engine a value outside the set;
        // it is still rendered, and still clamped.
        #expect(PlaybackRatePolicy.title(99) == "2×")

        // Stepping is clamped, not wrapped: a plus at 2x that landed on 0.5x
        // would read as a bug.
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
        // A server-relative TranscodingUrl keeps the reverse-proxy base path
        // (HEL-144): resolving it against the origin alone sent every
        // transcode on a base-path server to a route that does not exist.
        #expect(transcodeResult.url.path == "/jellyfin/Videos/item/master.m3u8")
        // The server's own legacy token is stripped, but its other query
        // items (here PlaySessionId) survive untouched.
        #expect(queryValue("PlaySessionId", in: transcodeResult.url) == "session")
        #expect(queryValue("ApiKey", in: transcodeResult.url) == nil)
        #expect(queryValue("api_key", in: transcodeResult.url) == nil)

        let sidecar = try #require(client.externalSubtitleURL(
            deliveryUrl: "/Videos/item/source/Subtitles/2/0/Stream.srt?api_key=legacy-token"
        ))
        #expect(sidecar.path == "/jellyfin/Videos/item/source/Subtitles/2/0/Stream.srt")
        #expect(queryValue("ApiKey", in: sidecar) == nil)
        #expect(queryValue("api_key", in: sidecar) == nil)

        // A foreign origin is never touched at all — not even to strip a
        // token it never had.
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
        // The sheet fetch still authenticates: the credential rides with the
        // source as the header the loader applies per request.
        let sheetAuthorization = try #require(trickplay.authorization)
        #expect(sheetAuthorization.applies(to: sheet))
        #expect(sheetAuthorization.headerValue.contains("Token=\"token\""))
    }

    /// `serverRelativeURL` is what makes a base-path server work for the
    /// routes Jellyfin hands back inside response bodies (HEL-144).
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

/// The starvation half of HEL-123: an audio queue at zero used to produce no
/// stall, no buffering state and no counter movement, so a film played on
/// with the picture running and no sound while every indicator read healthy.
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

    /// The reported shape: video full off its own buffer, but AVFoundation
    /// has consumed every audio sample it was handed. App queue depth is not
    /// part of this decision.
    @Test func exhaustedRendererAudioLeadIsStarvationEvenWithVideoFull() {
        let snapshot = healthy {
            $0.videoQueueCount = 30
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .audio)
    }

    /// Lead is measured after enqueueing to the renderer. Lagoon's own queue
    /// may be at zero in both assertions and is deliberately absent here.
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

    /// Nothing is starving while paused, buffering, finished, or within a
    /// second of the end.
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

    /// The revert, pinned so it is not re-introduced: with the defaults
    /// these calls use, audio gates recovery only through renderer
    /// delivery lead, and only when the engine asks for it via
    /// `audioRequired`. Left unset, as here, video decides alone.
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

    /// Audio starvation is still *detected* — the counter and the HUD line
    /// depend on it — it simply is not a reason to stop the picture.
    @Test func audioStarvationIsStillReportedEvenThoughItNeverStopsTheClock() {
        let snapshot = healthy {
            $0.videoQueueCount = 30
            $0.audioDeliveryLeadSeconds = 0
        }
        #expect(PlaybackStarvationPolicy.starvation(snapshot) == .audio)
    }

    // MARK: - Buffering on audio starvation (HEL-123, off by default)

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
    /// Audio grows and video does not, which is the whole design: a decoded
    /// 4K frame is 24.9 MB and a second of compressed audio is about 80 KB.
    @Test func onlyTheAudioCushionGrowsWithoutACache() {
        #expect(
            DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: false)
                > DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: true)
        )
        // Video's hard limit is not a function of delivery at all.
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: true) == 30)
        #expect(DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: false) == 120)
    }

    /// The cached profile is unchanged, so a direct play behaves exactly as
    /// it did before this existed. Video has to be off the floor first:
    /// the policy never parks on audio while video is the starved one.
    @Test func aCachedStreamKeepsTheWatermarksItAlwaysHad() {
        #expect(DemuxBackpressurePolicy.audioCushionTarget(deliveryIsCached: true) == 180)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 12,
            audioCount: 180,
            audioBufferedSeconds: 6,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .waitForAudio(below: 144))
    }

    /// The same queue depth that parks a cached stream keeps reading on an
    /// uncached one, which is the cushion actually being built.
    @Test func anUncachedStreamKeepsReadingWhereACachedOneParks() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 12,
            audioCount: 180,
            audioBufferedSeconds: 6,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
    }

    /// Video may not park on its own high water while audio is short of the
    /// drain it would have to survive, and without a cache that margin is
    /// larger because the drain is a network round trip rather than a cache
    /// read.
    @Test func videoWaitsLongerForAudioWithoutACache() {
        // 18 frames of 24 fps video drains to 12 in 0.25 s; a cached stream
        // needs 1.25 s + that, an uncached one 3 s + that.
        let betweenTheTwo = 2.0
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 18,
            audioCount: 40,
            audioBufferedSeconds: betweenTheTwo,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .waitForVideo(below: 12))
        // The same state, uncached, keeps reading to build audio instead.
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 18,
            audioCount: 40,
            audioBufferedSeconds: betweenTheTwo,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
    }

    /// The absolute bound still holds: a deeper cushion is not an unbounded
    /// one, and video's hard limit is untouched by any of this.
    @Test func theHardLimitsStillBound() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 40,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
        // The decoded queue's own bound hands over to the intake's, which is
        // what still bounds it once that fills too.
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 40,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit
        ) == .waitForVideo(below: 30))
        // Audio parks at its own high water once video is off the floor,
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 12,
            audioCount: 360,
            audioBufferedSeconds: 12,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .waitForAudio(below: 288))
        // and is stopped by the absolute bound even when video is starved
        // and the loop would otherwise keep reading for it.
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 0,
            audioCount: 540,
            audioBufferedSeconds: 20,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .waitForAudio(below: 540))
    }
}

/// HEL-124 reopened once the app-side queue was cleared as a suspect: a
/// Jellyfin HLS fragment's `mdat` is one contiguous video block followed by
/// one contiguous audio block, so `primeAndStart` fills the decoded video
/// queue to its hard limit and starts the clock before any of that
/// fragment's audio has even been read, and the one-slot pacing at the hard
/// limit then only reaches a fragment's audio after its last video frame.
/// Hardware measurement moved the fix into the existing hard-limit branch
/// itself rather than a separate renderer-side-lead gate: once the decoded
/// video queue is full and `audioCanCoverDrain` is false, the loop now
/// reads on for audio anyway — holding what it reads as compressed packets
/// in an intake rather than decoded frames — as long as the app-side audio
/// queue has not itself reached its own high water and the intake has not
/// reached its own count and byte bounds. Any of those failing falls back
/// to the one-slot-below-the-hard-limit pacing this branch always had.
@Suite("Demux read-ahead for a starving audio track")
struct DemuxReadAheadPolicyTests {
    /// At the hard limit on every decode path, with audio still short of
    /// its own high water, the loop reads on instead of parking. Once it
    /// does, video parked in the intake does not count against the decoded
    /// queue's own hard limit, so the same shape keeps reading even once
    /// `videoCount` has run past it.
    @Test func fullDecodedQueueReadsAheadForAudio() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 120,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: false,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 42,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            videoIsSoftwareDecoded: true,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 45,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
    }

    /// A silent title cannot starve on audio, so it never reaches this
    /// branch at all: `audioCanCoverDrain` is vacuously true without audio,
    /// which is the pre-existing one-slot-below-the-high-water pacing.
    @Test func silentTitleKeepsOneSlotPacing() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: false
        ) == .waitForVideo(below: 12))
    }

    /// The read-ahead only exists to keep audio from starving, so it stops
    /// the moment audio itself has enough queued: 180 packets is the cached
    /// profile's own high water, and going uncached moves that ceiling to
    /// 360 rather than changing the rule.
    @Test func audioHighWaterStopsTheReadAhead() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 180,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .waitForVideo(below: 30))
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 180,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 360,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            deliveryIsCached: false
        ) == .waitForVideo(below: 30))
    }

    /// The intake this rule reads into is bounded on its own, both by count
    /// and by bytes, so a stuck audio track cannot turn it into an unbounded
    /// compressed-packet queue: hitting either cap falls back to the
    /// ordinary hard-limit pacing even while audio is short of its own high
    /// water.
    @Test func intakeBoundsStopTheReadAhead() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit
        ) == .waitForVideo(below: 30))
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            videoIntakeCount: 10,
            videoIntakeBytes: DemuxBackpressurePolicy.videoIntakeByteBudget
        ) == .waitForVideo(below: 30))
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 30,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true,
            videoIntakeCount: DemuxBackpressurePolicy.videoIntakeHardLimit - 1,
            videoIntakeBytes: DemuxBackpressurePolicy.videoIntakeByteBudget - 1
        ) == .read)
    }

    /// Below the hard limit this is all unchanged: over the high water but
    /// short of the hard limit already read on for audio before any of this
    /// existed, because the batch-drain branch above it returns `.read`
    /// directly whenever audio cannot cover the drain and the hard limit has
    /// not been reached.
    @Test func belowTheHardLimitNothingChanged() {
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 20,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
        #expect(DemuxBackpressurePolicy.decision(
            videoCount: 10,
            audioCount: 0,
            audioBufferedSeconds: 0,
            videoFrameRate: 24,
            videoIsDecoded: true,
            hasAudio: true
        ) == .read)
    }
}
