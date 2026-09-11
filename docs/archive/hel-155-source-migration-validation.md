# Source migration and diagnostics opt-out (HEL-155)

September 11, 2026. Starting revision:
`2722d3ab08b2743fcd727be1b8f428cda1867611`, plus the existing uncommitted
diagnostics changes. Validation covered the working tree before the requested
per-file commits. [The plan](../reference/source-migration-plan.md) records scope and
acceptance requirements; Jira owns ticket status.

## Implementation

- Moved 154 existing app files into `App`, feature-owned folders, and `Shared`;
  grouped 75 unit-test files by subject, including the two new owner suites.
  Every mapped source exists
  exactly once. Assets, licenses, privacy resources, native artifacts and the
  Top Shelf extension remain in their existing targets.
- Extracted `PlaybackController`, `PlayerItem`, `PlaybackReportingSession`,
  `PlaybackSuccessorPreparation`, and `PlaybackDiagnosticsSampler`. The view
  retains its original `@State` controller and narrow Observation scope.
  Decoder/render queues and cache limits were not changed.
- Reporting retains start/progress/stop payloads, a ten-second progress cadence,
  exactly-once stop, and the existing report ledger. Stop work copies values
  without retaining the outgoing controller or engine. Successor preparation
  has explicit cancellation/generation ownership; a completed prepared result
  can now be reused at handoff after its negotiation task has finished.
- Reporting opt-out cancels the incident sampler rather than only suppressing
  reports. An event-driven preference observer restarts it during an active
  attempt after opt-in. Interrupted sampling resets freeze/stall windows and
  omits the session degradation summary, because partial observed playing time
  cannot be compared fairly with whole-session engine counters.
- Split Settings categories and Seerr request list/detail ownership. Shared
  player UI-test support retains platform launch defaults and fixture semantics.
  Fixed the existing UI-test target's tvOS-only platform settings so its iOS
  tests can run through `LagoonHardwareRegression`.
- Updated documentation/source links and release-script paths. No build number,
  package dependency, signing identity, release upload or Jira state changed.

Independent agent reviews checked Settings bindings/task identity, Seerr refresh
scope, reporting ownership, successor cancellation and staged-cache transfer.
No actionable extraction regressions remained after review.

## Environment and evidence

Xcode 26.6 (17F113), macOS 26.6.2; tvOS/iOS 26.5 simulators. Destinations:
Apple TV 4K (3rd generation), iPhone 17 Pro, and iPad Pro 11-inch (M5).
Release builds use generic iOS/tvOS device destinations with signing disabled.

The starting source and patch are saved under `/tmp/lagoon-hel155-start`.
Its `Packages` directory links to the unchanged working package; this is not
an independent native-artifact snapshot. Local `.xcresult` bundles and logs
below are temporary evidence, not checked-in reproducible build artifacts.

| Check | Result | Artifact under `/tmp/` |
| --- | --- | --- |
| Baseline tvOS units | 681 passed, 1 failed, 2 skipped | `lagoon-hel155-baseline-tv.xcresult` |
| Baseline iOS units | 660 passed, 1 failed, 2 skipped | `lagoon-hel155-baseline-ios.xcresult` |
| Current tvOS units after folder migration | 702 passed, 0 failed, 2 skipped | `lagoon-hel155-final-unit-tv.xcresult` |
| Current iOS units after folder migration | 681 passed, 0 failed, 2 skipped | `lagoon-hel155-current-ios.xcresult` |
| Baseline tvOS Settings/handoff/startup dismissal | 3 passed | `lagoon-hel155-baseline-ui-tv.xcresult` |
| Current full tvOS player suite | 23 passed, 0 failed, 9 skipped | `lagoon-hel155-ui-tv.xcresult` |
| Current iPhone touch-player journey after fixture-helper correction | 1 passed; combined bundle also contains the superseded Settings failure described below | `lagoon-hel155-verified-ui-iphone.xcresult` |
| Current iPad touch-player journey after centered-tap and fixture-helper corrections | 1 passed; combined bundle also contains the superseded Settings failure described below | `lagoon-hel155-verified-ui-ipad.xcresult` |
| Final iPhone Settings bindings/persistence and largest accessibility text | 2 passed, 0 failed, 0 skipped | `lagoon-hel155-settings-final-iphone.xcresult` |
| Final iPad Settings bindings/persistence and largest accessibility text | 2 passed, 0 failed, 0 skipped | `lagoon-hel155-settings-final-ipad.xcresult` |
| tvOS fixture-helper success and missing-fixture checks | 1 passed, 1 expected fixture skip | `lagoon-hel155-final-fixture-tv.xcresult` |
| Lifetime tests after warning cleanup | 15 passed, 0 skipped | `lagoon-hel155-lifetime-warning-check.xcresult` |
| Release iOS and tvOS device builds | Passed, unsigned | `lagoon-hel155-release-{ios,tv}.log` |
| Release bundle resources | Passed | `lagoon-hel155-packaging-{ios,tv}.json` |

Unit totals count unique tests; parameterized cases add executions. Both
baseline failures were the existing ledger test's two-second wall-clock bound
under suite contention. Its assertion now measures wake-up after the actual
close, separately from scheduling delay, and still requires both waiters to
finish well before their timeout. Production ledger behavior is unchanged.
New coverage exercises report ordering/retention/cancellation, staged successor
ownership and late results, and opt-out/re-enable/attempt-end sampling.
The two ordinary-unit skips are the opt-in native-allocation endurance check
and the controlled TLS fixture matrix; their gates were not enabled here.
The four new weak-reference warnings in lifetime tests were removed without
suppression and those suites passed again. Remaining compiler warnings are
existing diagnostics in moved or unchanged code, not a warning-free build.

The baseline iOS UI invocation could not run because the test target excluded
iOS. No baseline iOS UI pass is claimed. The current iPhone journey verifies
pause, seeks, scrub, auto-hide/reveal, accessibility labels and dismissal;
full-screen attachments were inspected for visible and hidden controls.

The first iPad touch run failed on the initial pause. Its recording and
synthesized-event attachments show all three XCTest activation points outside
the circular hit region: approximately `(373.8, 551.8)` against a center near
`(417, 594)` and a 54-point radius. Each tap hit the video and hid transport.
Player geometry and the test body matched the starting snapshot. The test now
taps the geometric center of circular pause/skip controls, retaining every
assertion and retry policy. Evidence: `/tmp/lagoon-hel155-ui-ipad.xcresult` and
`/tmp/lagoon-hel155-ipad-pause-hit-crop.png`. The complete touch journey passed
after this correction and again with the final shared fixture helper.

The combined iOS validation runs also exposed test-driver assumptions: SwiftUI
exposes a full-row switch separately from its native toggle, iPad navigation
does not always expose Settings inside an XCTest tab bar, and the fixture
resolution probe can disappear between an existence check and a value read.
The shared fixture helper now reads both startup probes from one snapshot.
Settings automation targets the platform's actual controls; production UI
behavior and all test assertions are preserved.

The next combined runs (`lagoon-hel155-verified-ui-{iphone,ipad}.xcresult`)
each passed touch playback and the largest accessibility text-size journey,
but failed the new Settings persistence journey. The existing
`debug.settingsRegression` launch flag resets subtitle appearance whenever
the Settings root's task restarts, including return navigation. The new iOS
test removes that flag and establishes its starting appearance through the
actual Reset to System button. This corrects the fixture setup without
changing production behavior or weakening the persistence assertions.
Both final Settings suites passed after this correction, including returning
to changed playback/subtitle/reporting preferences and restoring their values.
Screenshots from normal and largest accessibility text sizes were inspected
on iPhone and iPad; controls remain reachable in the native scrolling layout.
The final screenshots are exported under
`/tmp/lagoon-hel155-settings-final-images-{iphone,ipad}`.

The tvOS controlled frame-loss test passed all three untouched runs on the
854×480 direct-play fixture. Each recorded zero dropped/corrupted frames,
stalls and audio gaps. Frame totals were 1,450 / 1,426 / 1,425 over approximately
60-second windows, with footprint growth 5.6 / 2.9 / 1.1 MiB. The test uses the
HUD and Debug configuration; this is a regression ceiling check, not a
baseline-versus-current comparison or a diagnostics on/off cost measurement.

The full tvOS suite also passed handoff, suspended-startup dismissal, repeated
dismissal/Settings/replay with memory and cleanup bounds, buffered scrubbing,
HLS/remux playback, audio/delivery recovery, panel stress and Settings focus.
The nine skips cover unavailable intro-segment, direct-stream, subtitle/provider,
multi-audio and VC-1 fixtures, plus the existing simulator exclusion for the
software-decoded fixture whose audio clock does not start. These skips do not
establish acceptance for those formats/features. Inspected Settings attachments
cover native audio menus, subtitle appearance and diagnostics toggles.

Packaging checks verified `default.metallib`, all five license files, matching
privacy manifests and bundle versions, and the tvOS-only Top Shelf extension
with its original entry point. These are packaging checks, not signed-archive
or App Store acceptance. Native binaries were not modified.

## Remaining acceptance

The automated checks for available fixtures are complete. The final path audit
found all 229 mapped destinations, no old source copies, and no obsolete source
references in scripts/current documentation. Markdown links, release-script
syntax, tracked diffs and untracked-file whitespace checks passed. Specialized
fixture skips listed above remain coverage gaps.

Physical dismissal/replay, episode handoff and supported PiP/background flows
remain required. No physical Apple TV was attached, so simulator checks cannot
establish device performance parity or close the ticket's hardware gate.

For the device comparison, use the same fixture, scene, media-time window,
Release configuration and display path on both builds, with at least three
untouched runs each. Compare frame loss, stalls, memory after teardown and CPU.
For sampler cost, separately compare reporting on/off with HUD and decode trace
disabled. The frame-loss bench also loads renderer metrics, so a bench-enabled
comparison measures incremental sampler overhead; it does not measure the full
cost of enabling metric reads in otherwise uninstrumented playback. Retain a
bench-disabled CPU/energy observation for that distinction. An opt-out no
longer leaves the two-second incident sampler running.
