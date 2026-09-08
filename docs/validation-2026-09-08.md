# Validation run, September 8, 2026

A full simulator validation of `main` at `bd4fedf` after the day's batches:
the HEL-146 subtitle cleanup, the URLSession transport spike, HEL-145 Dolby
Vision profile 7 conversion, HEL-143 header-only credentials and
acknowledgements, HEL-144 warnings, base-path routing and regression-lane
hygiene, and HEL-147's hero fallback. Every lane ran on freshly created
simulators except the bench, which ran last and alone on the signed-in
Apple TV simulator with the same build installed over the existing app.
Logs live under the session scratchpad's `validation/` directory; nothing in
this run touched a physical device.

## Environment

- Xcode with tvOS 26.5 and iOS 26.5 simulator runtimes; Apple TV 4K (3rd
  generation) and iPhone device types.
- Public demo `demo.jellyfin.org/stable`, Jellyfin 12.0.0 behind the
  `/stable` base path. That evening its catalogue was between resets: one
  series and eleven films, every library's recently-added list empty. The
  skips below say so where it mattered.
- Private fixture server `fixture.example.eu` with real 4K HEVC, HDR10,
  Dolby Vision and Atmos media, no base path.
- The synthetic local Jellyfin fixture (`scripts/jellyfin-regression-fixture.py`)
  for the recovery lanes.

## Lanes

| Lane | What ran | Result |
| --- | --- | --- |
| A | Release builds, tvOS and iOS simulator | pass, 0 first-party warnings each |
| A | Unit suites | tvOS 613 tests / 71 suites, iOS 589 / 69, all pass |
| B | Real profile 7 remux through the demuxer, converter and NAL rewriter suites | 23 tests pass |
| C | tvOS UI journeys on the public demo: library, server sync, the 29-case player suite | 26 pass, 7 skip (fixture required), 3 fail — all three dispositioned below |
| D | The same journeys on fixture | 31 pass, 3 skip (fixture shape), 2 fail — the same two library cases, dispositioned below |
| E | Recovery lanes on the synthetic fixture: session expiry (2 cases × 2 platforms), account privacy, server address with proxy base paths, subtitle downloads, iOS local network | all pass |
| F | TLS certificate matrix through the transport, 32 cases × 2 platforms | pass, no request reached an invalid peer |
| G | Frame-loss bench, Deadgirl at 600 s, 3 runs direct and 3 runs with the simulator transcode profile | 0 dropped, 0 stalls on all six; frames 1475/1450/1450 and 1450/1450/1450 |

The bench numbers equal the transport spike's baseline from the same
morning (0 dropped, 0 stalls, 1450–1475 frames, peak memory 103–151 MB).

## Failures and what they were

None was a product regression.

- **Episode handoff on the demo** (`testEpisodeHandoffKeepsSurfaceMountedAndStartsSuccessor`):
  the player surface disappeared during the handoff. The same case passed on
  fixture in lane D. The demo held a single series that evening, so the
  resolver had no real episode-with-successor to hand off between; it is
  recorded as an environment failure and stays on the list to rerun on the
  demo once its catalogue is back.
- **Library sort persistence** (`testLibraryFiltersSortingAndReturnNavigation`),
  both servers: the case relaunches the app to check that the chosen sort
  survives, and the new clean-slate switch wiped it on that relaunch. Fixed
  in the test: the relaunch now passes `-debug.regressionResetState NO`.
  Rerun after the fix: passes on both servers.
- **Decade filters** (`testDecadeFiltersCombinePersistAndClear`), both
  servers: the case hard-coded "2000–2009" and "2010–2019", which neither
  catalogue offered that evening (fixture has no shows from the 2000s either).
  Fixed in the test: a catalogue-derived option that is missing is now a skip
  with a stated reason rather than a failure, while the fixed menu entries
  still fail when absent. Rerun after the fix: skips on both servers with
  "the catalogue offers no 2000–2009 option under Decade"; it runs in full
  again whenever the demo's catalogue is back. Reading the decades off the
  submenu instead was tried and dropped: its rows expose no titles to a
  descendant query, only to the `containing` lookup the suite already uses.

## Skips and why

- Public demo, lane C: intro skip, direct-stream item, scrub with tracks and
  subtitles, real audio track switch, real subtitle cue, software-decoded
  playback, VC-1 direct play — all "fixture server required"; every one of
  them ran on fixture in lane D.
- fixture, lane D: the direct-stream item and the exact playback-speed media
  fixture do not exist there; the software-decoded fixture's audio never
  started within its window, which that case treats as a fixture problem
  and skips.

## Not covered by this run

- Anything on a physical Apple TV or iPhone: the DoVi profile 7 display
  check (MEL and FEL), the transport on real network paths, the frame-loss
  bench on hardware, and the device acceptance matrix in the audit's
  section 10.
- The Privacy Policy and Support rows, whose URLs are still nil by design.
- iOS UI journeys beyond the local-network lane; iOS coverage here is the
  unit suite, the Release build and the screenshots taken while the
  acknowledgements screens were built.

## Reproducing

```sh
# A
xcodebuild -scheme Lagoon -configuration Release -destination 'generic/platform=tvOS Simulator' build
xcodebuild test -scheme Lagoon -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -only-testing:LagoonTests
# C / D (D with LAGOON_REGRESSION_SERVER/USER/PASS exported, also as TEST_RUNNER_*)
xcodebuild test -scheme LagoonHardwareRegression -destination 'platform=tvOS Simulator,id=<fresh>' \
  -only-testing:LagoonUITests/LibraryBrowseUITests -only-testing:LagoonUITests/ServerSyncUITests \
  -only-testing:LagoonUITests/PlayerRegressionUITests
# E
python3 scripts/test-session-recovery.py            # session expiry
python3 scripts/test-session-recovery.py --account-privacy
python3 scripts/test-session-recovery.py --server-address
python3 scripts/test-session-recovery.py --subtitle-downloads
python3 scripts/test-session-recovery.py --local-network
# F
python3 scripts/test-ffmpeg-tls.py
# G
scripts/framedrop-bench.sh --title "Deadgirl" --position 600 --runs 3
scripts/framedrop-bench.sh --title "Deadgirl" --position 600 --runs 3 --set debug.simulatorTranscode=true
```
