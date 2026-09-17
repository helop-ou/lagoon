# UI regression lane: fixtures and state

What each UI journey may assume about the server and the simulator it runs
on, so a run on a clean machine and a run on a developer's machine mean the
same thing (audit A18). Unit tests run under the `Lagoon` scheme. UI
journeys run under `LagoonHardwareRegression`. `-only-testing:` fails with
the `Lagoon` scheme because the UI target is not in that plan.

## Three fixture tiers

Every journey declares which tier it needs by what it launches with and what
it skips on. Nothing in the lane may depend on a fourth thing: an account
somebody happens to be signed into on the simulator.

| Tier | How it is selected | What it guarantees | What it does not have |
| --- | --- | --- | --- |
| Public demo (default) | `-debug.playerRegression YES -debug.regressionBootstrapPublicDemo YES` and no `LAGOON_REGRESSION_*` in the environment | `demo.jellyfin.org/stable`, user `demo`, Jellyfin 12 behind a `/stable` base path. Sign-in, browsing, detail pages, direct-play H.264 films and episodes, `Pioneer One` with successive episodes | Subtitles, multiple audio tracks, chapters, intro segments, 4K, HDR, VC-1. Everything direct-plays, so HLS only through `-debug.regressionInitialDelivery remux`. The Home hero can be empty between the demo's periodic resets |
| Private fixture server | `LAGOON_REGRESSION_SERVER`, `_USER`, `_PASS` in the test runner's environment (`TEST_RUNNER_` prefix under `xcodebuild`) | Whatever that library holds; the journeys that need a specialised item resolve it by property, never by a private title | Nothing is assumed absent. A missing hero or fixture on a supplied server is a failure, not a skip |
| Loopback synthetic fixture | `LAGOON_SESSION_FIXTURE` pointing at `127.0.0.1`, started by `scripts/test-session-recovery.py` (which runs `scripts/jellyfin-regression-fixture.py`) | Deterministic direct and HLS delivery, session revocation, subtitle failure and size modes, proxy base paths, account privacy pairs, denied local network | Real media and a real Jellyfin; the fixture is a small HTTP server with ffmpeg-generated clips |

Journeys in the third tier skip with "Requires the synthetic … fixture"
whenever the variable is absent. Journeys in the first two tiers share one
launcher, `PlayerUITestCase.launchSignedIn`, which forwards
`LAGOON_REGRESSION_*` to every launch. That is deliberate, but it has a
consequence: setting the environment for the fixture suites redirects the
demo journeys to the same server too. A journey written against the demo's
direct-play catalogue has to say what it needs through a resolver flag
instead of assuming it. Otherwise it times out on a fixture server whose
first playable title transcodes. One run lost two journeys this way.

## Resolver flags

The bench hook, `-debug.benchSearchTerm <title>`, opens a named title.
`-debug.benchProductionYear` and `-debug.regressionSeriesName` disambiguate
it. The resolver flags below open a title by property instead, so the
journey holds on any server that has one:

| Flag | Picks | Fails with |
| --- | --- | --- |
| `-debug.regressionFindPlayable` | First film or episode with a video stream | `missing:playable item` |
| … plus `-debug.regressionRequireAudio` | … that also has an audio stream | same |
| … plus `-debug.regressionRequireDirectPlay` | … whose first source the server offers for direct play under the simulator profile | `missing:direct-play playable item` |
| `-debug.regressionFindDirectStream` | A direct-stream (remux) source | `missing:direct-stream item` |
| `-debug.regressionFindEpisodeWithSuccessor` | Earliest of at least two episodes in one series; `-debug.regressionRequireDirectH264Successor` narrows it to direct-play H.264 | `missing:requested handoff series` or the H.264 variant |
| `-debug.regressionFindMultiAudioH264` | Direct-play H.264 with more than one audio track | `missing:direct-play H.264 multi-audio item` |
| `-debug.regressionFindSkippableEpisode` | Episode of the named series with a skippable segment | `missing:requested skippable series` |
| `-debug.regressionFindVC1InSeries` | VC-1 episode of the named series | `missing:VC-1 episode` |

The app publishes the outcome on the `player.regression.resolution` probe.
`requireRegressionFixture` turns a `missing:` value into an `XCTSkip` that
names the fixture. An `error:` value means a failed library scan, and that
becomes a test failure instead. If neither probe appears because the cold
sign-in handshake failed, it retries the launch once. A journey that needs
a Home hero calls `requireHomeHero`, which skips on the public demo and
fails on a supplied fixture server.

Delivery hooks sit beside the resolvers. `-debug.regressionInitialDelivery
remux|transcode` starts on that rung instead of negotiating.
`-debug.regressionFailFirstDelivery delivery|undecodable` injects the first
failure so the fallback ladder runs. `-debug.simulatorTranscode` only
withdraws HEVC and Dolby Vision from the profile; it never forces a
transcode on its own.

## State on the simulator

`-debug.regressionResetState YES` is honoured only next to the demo
bootstrap flag. It runs before the session restores anything, and it
removes what a previous run left behind: stored accounts and the active
one, the mid-connect server, every per-account preference, the Seerr
server keyed by Jellyfin URL, and every keychain item of the app's service
except the device id. Per-account preference means libraries, home rows,
subtitle and track preferences, and recent searches. App-wide settings
such as skip mode, autoplay and caption style stay. A journey that cares
sets them through launch arguments and restores what it flips afterward.
The bootstrap then always signs into the lane's server, whatever account
the simulator last used, and persists nothing.

Which launches pass the reset, and why:

- Every public-demo and fixture-server launch through `launchSignedIn`,
  `SettingsUITests`, `ServerSyncUITests` and `LibraryBrowseUITests` passes it
  on the first launch.
- A journey that relaunches to prove persistence drops the flag for the
  relaunch only (`LibraryBrowseUITests` does this by rewriting its argument
  list).
- Loopback journeys that must start without an identity override the launch
  domain instead: `-accounts () -session.activeAccountId ""` (and
  `-server.url ""` where the address is the subject). The argument domain
  never reaches disk, so nothing on the simulator is touched.
- `AccountPrivacyUITests` signs two fixture viewers in for real
  (`-debug.accountPrivacyRegression` on a loopback address) and then relaunches
  without the bootstrap to drive the ordinary picker.

The reset erases real sign-ins. Run the lane only on simulators kept for
it. Never run it on a simulator a person keeps signed into their own
library, and never on a physical device. A `devicectl` bench launch omits
the flag for this reason.

## Running the lane

```sh
# Public demo, clean state, tvOS regression device by id (two simulators
# share the "Apple TV 4K (3rd generation)" name)
xcodebuild test -scheme LagoonHardwareRegression \
  -destination 'platform=tvOS Simulator,id=<udid>' \
  -derivedDataPath /tmp/lagoon-lane-tvos -resultBundlePath /tmp/lane-tvos.xcresult

# Fixture server for the specialised journeys
TEST_RUNNER_LAGOON_REGRESSION_SERVER='https://example.test' \
TEST_RUNNER_LAGOON_REGRESSION_USER='Regression' \
TEST_RUNNER_LAGOON_REGRESSION_PASS='…' \
xcodebuild test -scheme LagoonHardwareRegression -destination …

# Loopback journeys (starts the fixture, runs the named journey on fresh
# simulators, tears them down)
scripts/test-session-recovery.py --subtitle-downloads --platforms iOS tvOS
```

A UI run and an `xcodebuild build` share one build database unless the run
has its own `-derivedDataPath`; without it the test dies with "database is
locked". Running three lanes at once on one machine produced load flakes;
two lanes at once are fine. Read a passed lane as: every test
either passed or skipped with a named fixture reason. A skip on a supplied
fixture server is a missing-fixture finding to record, not a pass.

Evidence for a given revision is recorded on its ticket; the lane's own
contracts live here.
