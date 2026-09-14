# Build 100 recheck — September 14, 2026

## Scope and environment

Reviewed the 275 commits in `859e0d2..5318798d5b21caf6ae22ca03f79708b0477e1956`
and the uncommitted Build 100 changes in this checkout. `859e0d2` is the
Build 99 bump. Starting at Build 100's changelog commit would miss the
interlaced H.264 implementation that preceded it.

The review covered downloads (HEL-166), detail layouts (HEL-169), interlaced
video (HEL-170), categorized changelog (HEL-171), Watch Together (HEL-172),
Baby Pink (HEL-173), discovery details (HEL-174), series episode selection
(HEL-175), background playback/automation (HEL-176), and Top 10 (HEL-121).

Xcode 26.6, build 17F113; dedicated iPhone 17 Pro / iOS 26.0 simulator
`9552F734-A3FF-4D64-A055-9F02383F335A` and Apple TV 4K (3rd generation) /
tvOS 26.5 simulator `60E82094-C734-4D74-B4F6-578DB4DC937D`. Xcode and
CoreSimulator access succeeded outside the filesystem sandbox. The earlier
sandbox blockage is superseded by the executable results below.
Touch layout was also exercised on an iPad Pro 13-inch (M4) / iOS 26.0
simulator, `6B64C50C-AFAD-4A67-AB3D-672108C3F87F`.

## Findings corrected

- Downloads: fixed cross-file access that failed actual compilation;
  serialized delegate completion with commands on MainActor; preserved the
  active observed manifest; rejected stale attempts and empty responses;
  guarded account switches, concurrent starts, pause/resume and reconciliation;
  bounded artwork; made the artwork index's lock contract compiler-checked.
- Permission refresh: an old request cannot return a new account's cached
  download/transcode permission.
- Watch Together: snapshot credentials per account; cancel all queued
  requests; reject obsolete membership/item results; retain actionable join,
  play, and loading errors; acknowledge Ignore Waiting before publishing;
  retry readiness once; preserve paused readiness through delivery fallback.
- Playback: commit a seek before notifying automation so a synchronous intro
  skip cannot be overwritten; publish the buffering target before callbacks;
  reset the start-position override between sessions.
- Home: match typed exact TMDB IDs, deduplicate and retain provider ranking;
  keep Top 10's bounded scan independent of other shelves; guard cancellation
  and late results; clear successful empty collection results.
- Series: reject obsolete episode responses even after an A → B → A season
  selection, and guard load/reload publication by item and session generation.
- Presentation: warmer rose-based Baby Pink, themed discovery fallbacks,
  categorized historical changelog, and safe developer-preview decoding.
- Compiler/test hygiene: remove the surfaced actor/captured-state warnings;
  synchronize mutable diagnostics fixtures; make account-expiry assertions
  accept cancellation when another authenticated request expires the account
  first; allow executor scheduling time in an explicitly clock-driven monitor
  test without changing its simulated sampling interval.

## Apple and repository guidance

This is a source and simulator assessment, not App Review approval.

| Principle | Evidence |
| --- | --- |
| Separate observable model data from views; one source of truth | Feature models use Observation, shared ownership is explicit, and view composition uses existing detail/settings components. Checked against Apple's [Managing model data](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app). |
| Background URLSession lifecycle | One stable background session; preserve the temporary file before returning; persist before acknowledging events on the main queue. Checked against Apple's [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background). |
| Native interaction and accessibility | Native controls and focus, semantic text, explicit image labels, hidden decorative content, Reduce Motion handling, and large-text simulator journeys. Compared with Apple's [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility). Physical VoiceOver and remote acceptance remain separate. |
| Clean ownership and reuse | Feature directories, shared detail scaffolding, pure ranking/session policies, a small cancellable request queue, and a separately testable file-completion boundary. No new dependency or alternative playback engine. |
| Privacy packaging and transport settings | Both simulator bundles pass `scripts/validate-release-privacy.py`, including required-reason resources, local-network purpose text, no broad ATS exception, and tvOS extension/version consistency. This does not settle publisher/privacy/legal declarations. |

The repository's [standards](../standards.md) document how these principles
map to Lagoon. Apple does not mandate this exact folder tree or a view model
for every view.

## Verification

Both required generic simulator builds passed on the final app source:

```sh
xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/lagoon-build100-review-ios build
xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' -derivedDataPath /private/tmp/lagoon-build100-review-tv build
```

Final build logs are `/private/tmp/lagoon-build100-final-{ios,tv}-build.log`.
There are no Swift compiler warnings in these builds or the final unit
compiles. Xcode emits its tooling warning, "Metadata extraction skipped.
No AppIntents.framework dependency found." No blanket warning suppression
was added.

| Check | Final result | Result bundle under `/private/tmp/` |
| --- | --- | --- |
| iOS full unit suite | 945 passed, 2 explicitly skipped, 0 failures; 122 suites | `lagoon-build100-final-ios-unit.xcresult` |
| tvOS full unit suite | 966 passed, 2 explicitly skipped, 0 failures; 123 suites | `lagoon-build100-final-tv-unit.xcresult` |
| Final changelog copy | 6 passed | `lagoon-build100-final-changelog.xcresult` |
| iPhone settings and touch player | 6 passed | `lagoon-build100-review-ios-ui.xcresult` |
| iPad settings and touch player | 5 passed initially; remaining detail-to-player test passed after fixing adaptive tab discovery | `lagoon-build100-review-ipad-ui.xcresult`, `lagoon-build100-final-ipad-ui.xcresult` |
| tvOS functional UI | 18 passed initially, 9 skipped; the corrected developer-gallery and Baby Pink journeys then passed (2/2) | `lagoon-build100-review-tv-ui.xcresult`, `lagoon-build100-final-tv-ui-rerun3.xcresult` |
| Final bundle privacy/resource checks | Both passed | `lagoon-build100-final-{ios,tv}-privacy.json` |

Unit counts above use xcresult's top-level test definitions. Parameterized
executions are 1,004 passed on iOS and 1,030 on tvOS, plus the two explicit
skips on each. The skipped unit checks are the opt-in TLS certificate matrix
and failed-open native-allocation soak. Several other preexisting optional
media tests return early without their environment fixture; their reported
passes do **not** establish AV1/VP9/VC-1/MPEG-4/ASS/full Dolby Vision file
coverage. Embedded Dolby Vision RPU conversion cases do execute.

Full unit commands used scheme `Lagoon`, `-only-testing:LagoonTests`,
`-parallel-testing-enabled NO`, the dedicated device IDs above, and the
platform's derived-data path. Both injected:

```sh
TEST_RUNNER_LAGOON_TS_SEEK_FIXTURE_URL=/private/tmp/lagoon-build100-seek-fixture.ts
TEST_RUNNER_LAGOON_INTERLACED_H264_FIXTURE_URL=/private/tmp/lagoon-build100-interlaced-h264.mkv
TEST_RUNNER_LAGOON_PROGRESSIVE_H264_FIXTURE_URL=/private/tmp/lagoon-build100-progressive-h264.mkv
```

Generated fixtures exercise H.264/AAC transport-stream seeks at 24.8 and
96.5 seconds, and 1080i H.264 software decoding/deinterlacing with a 1080p
control. The interlaced test actually decoded frames on both platforms
(about eight seconds per run); it was not its fixture-free early return.
The full iOS unit run preceded the final release-copy edit; the six
changelog checks reran after that edit. All other app/test logic in that
full run matches the final tree.

UI commands used `LagoonHardwareRegression` and disabled parallel test
execution. The iPhone and iPad selection was `SettingsUITests` plus
`TouchPlayerUITests`. The tvOS selection was `PlayerRegressionUITests`,
excluding its four performance/benchmark tests while functional lanes ran
concurrently. This pass makes no new performance comparison.

The nine tvOS skips were: intro skip with server segments; direct-stream
fixture; synthetic subtitle-provider download/switch; external subtitles;
combined scrub/multi-track/subtitle journey; real multi-audio switch; a real
subtitle cue; the simulator-incompatible software-decoded audio fixture;
and the VC-1 series fixture. Logs retain each skip reason. These do not
count as functional passes.

A test-only tvOS menu helper initially depended on target rows remaining in
the accessibility tree. The final helper resets and selects by stable native
menu order, and the two affected journeys passed in
`lagoon-build100-final-tv-ui-rerun3.xcresult`. Attachments were exported into
`/private/tmp/lagoon-build100-{ios,ipad,tv}-ui-attachments/`. Inspected the
settled pink Appearance and Settings screens, categorized/scrolled changelog,
largest-accessibility-size Settings and controls, iPhone/iPad player
presentation, and tvOS genre focus. The initial pink Appearance attachment
caught its intentional bloom; the return attachment verifies the settled
palette. Final TV theme sweep results follow after completion.

tvOS navigation also emitted a UIKit runtime diagnostic about adding an
`_UIReplicantView` to a hosting view. App source contains no replicant,
snapshot-view, or child-view insertion calls. tvOS uses native
`fullScreenCover`; its remote gate only attaches gesture recognizers.
Framework transition behavior is the likely origin, but a runtime backtrace
has not established the exact callsite. Keep this diagnostic visible rather
than treating a source scan as proof it cannot affect a device.

The first real iOS compile failed because `accountGeneration` was private in
a different file. Both generic builds passed after that correction. Their
compiler warnings were then corrected rather than hidden.

The first full unit runs failed once each: iOS account-expiry request ordering
(942 tests / 122 suites) and tvOS monitor scheduling (963 tests / 123 suites).
Both failures and their corrections are retained here; these initial runs
are not counted as passing evidence.

The initial tvOS UI failure selected Watch Together's preview instead of
Player Panel after new menu options shifted a fixed remote-press count.
The test now follows native focused descendants. The new theme test also
needed to inspect the focused descendant of SwiftUI's semantic wrapper.
The initial iPad failure occurred before playback because its test searched
inside an iPhone-style TabBar; adaptive tab-button discovery corrected it.
These failing runs are retained rather than relabeled as passes.

## Remaining acceptance

- Physical iPhone/iPad background audio, PiP, lock-screen controls,
  interruptions, AirPlay, and background download suspension/relaunch,
  connection changes and offline playback.
- Physical tvOS focus/remote behavior, captions/HDR, and sustained film-length
  performance; two physical members for Watch Together drift/reconnect.
- Full accessibility acceptance: VoiceOver, Switch Control/keyboard access,
  Increase Contrast and [Dim Flashing Lights](https://developer.apple.com/documentation/mediaaccessibility/flashing-lights).
  No explicit `MADimFlashingLightsEnabled`/processor integration exists in
  the custom sample-buffer path; system mitigation has not been demonstrated.
  Investigate and verify that behavior before claiming support for it.
- Public demo lacks download permission and several specialized playback
  fixtures. Unit/mock checks do not establish a live Seerr Top 10 population
  against the intended household library.
- `TMDBConfiguration.apiKey` is empty, so discovery logos fall back to text.
  Published legal/support destinations, licensing/privacy/encryption decisions,
  signed archives and Apple's distribution validation remain the concrete
  gates in [Release](../release.md#public-release).

No upload, release, or universal compatibility claim follows from this record.
