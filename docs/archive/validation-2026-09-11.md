# Validation run, September 11, 2026

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

A full simulator validation of `main` after the day's batches, run while
Jaagop was away: the HEL-162 iOS presentation fix, orientation and swipe
grammar, the HEL-161 width-fitted grids, and the HEL-160 fill scheduler with
its review fixes. Everything ran on simulators; the Apple TV was not
connected and Jaagop's iPhone was left alone. No physical-device evidence is
claimed here.

## Environment

- Xcode 26 with iOS 26.0/26.x and tvOS 26.x simulator runtimes.
- iPhone 17 Pro (`A79FF3D9`), iPhone 17 Pro Max (`B4DCB564`), iPad Pro
  11-inch M5 (`6C28EE02`), Apple TV 4K 3rd generation (`7399D9F5`, the
  regression device).
- Public demo `demo.jellyfin.org/stable` (Jellyfin 12) for the demo
  journeys; `fixture.example.eu` (10.11.11) as the fixture server through
  `LAGOON_REGRESSION_*`.

## Results

| Lane | Result |
| --- | --- |
| tvOS unit suite (`Lagoon` scheme, Apple TV simulator) | 730 tests in 94 suites passed |
| iOS unit suite (`Lagoon` scheme, iPhone 17 Pro Max) | 709 tests in 93 suites passed |
| iOS UI lane (`LagoonHardwareRegression`, iPhone 17 Pro, fixture env) | 12 passed, 8 skipped (fixture-dependent), 0 failed |
| tvOS UI lane (`LagoonHardwareRegression`, Apple TV simulator, fixture env) | 38 passed, 11 skipped, 3 failed; see below |
| Touch player journeys (demo, iPhone 17 Pro) | 3 of 3 passed, repeated after each batch |
| HEL-160 fill bench | see [its record](hel-160-background-fill-validation.md) |

### The three tvOS UI failures

All three ran while three `xcodebuild` lanes shared the machine. Rerun alone
on an idle machine, still with the fixture environment:

- `testExternalSubtitleTrackLoadsSwitchesAndClears` passed. Load flake.
- `testBoundedDeliveryOutageRecoversThroughStallWithoutReprime` and
  `testLivePlayerPanelSweepPerformance` failed again, both timing out on the
  same fixture title `8de9364e…`, served as a transcode. The same two fail
  identically on this morning's `2cff789` from a worktree, and both pass
  against the public demo without the fixture environment. They are not a
  regression: both use `-debug.regressionFindPlayable`, the library's first
  playable title, which on fixture is a transcode these journeys were not
  written for (the delivery-outage journey waits for the compressed path's
  120-frame coast, the sweep for a direct-play position advance). The lane's
  shared launcher forwards `LAGOON_REGRESSION_*` to every journey, so setting
  it for the fixture suites also redirects the demo journeys. Run the demo
  journeys without the environment, or teach the two journeys to pin a title.

## HEL-157 visual acceptance

"King Lear" (a Primary image but no Backdrop, Thumb or Logo on the demo)
shows its poster on the Recently Added in Movies rail on the iPhone 17 Pro
Max and the Apple TV simulator, and on the iPad's Continue Watching rail
(the same landscape-card fallback); the card is focusable on tvOS. Scratch
XCUITest journeys drove the rails and captured the screenshots; they were not
kept.

## Not covered

- Physical iPhone and Apple TV acceptance (HEL-144, HEL-153, HEL-159, HEL-160).
- The Requests grid under HEL-161 (no Seerr on the lane).
- Anything the demo journeys skip when their fixture is absent.
