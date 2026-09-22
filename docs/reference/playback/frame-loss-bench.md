# Frame-loss bench

Playback engineering notes retained during the September 10, 2026
documentation cleanup. Start with the
[current playback guide](../../playback.md) and the
[notes index](README.md).

## Frame-loss bench

Measuring frame loss casually produces false positives. Two "fixes" were
retracted after being measured across different scenes, positions and
sampling rates, before landing on the rule: **compare only the same scene
over the same media-time window, untouched**. Content alone varies loss 3×
within one file. Taking a simulator screenshot forces a render capture and
drops frames, so never screenshot inside a measurement window.

Settings → Debug → Frame-Loss Bench encodes that rule in the app. After
every playback start or seek it warms up 10 s of *media time*, then
measures a 60 s window. The result freezes into the HUD's `Bench:` line and
a `Bench Result` signpost, which carries dropped/frames/percent, stalls,
`aGaps`, minimum queue depth, window start, and two fields from Apple's own
metrics that settle arguments: `optimized` (frames shown through the
direct-display path that bypasses UI compositing, read against `frames`)
and `delayMs` (Apple's accumulated display-lateness metric). Touching the
transport re-arms it from the new position, so "seek to the scene, hands
off, read the number" is the whole protocol, identical in the simulator and
on hardware. Windows are keyed on position rather than wall time, so a
stall stretches the run without diluting the denominator. Stalls are
reported in the result, not discarded.

`scripts/framedrop-bench.sh` automates repeated simulator runs. It
deliberately avoids the `lagoon://` deep link, because `DeepLinkRouter` now
accepts only links carrying an `?owner=&generation=` pair that matches the
current Top Shelf publication, so `lagoon://play/{id}` is silently dropped.
Instead it drives `MainTabView`'s launch-time bench hook
(`launchBenchItemIfRequested()`). Each run force-quits the app, writes
`debug.frameLossBench`, `debug.playbackHUD`, `debug.benchAutoExit`,
`debug.benchSearchTerm` (the movie title), `debug.benchStartSeconds` (the
pinned start position) and optionally `debug.benchProductionYear` through
`simctl spawn … defaults write`, then relaunches. The app's own startup
task resolves the title against the MOVIES library and enters playback at
that position. `debug.benchAutoExit` leaves the player through the clean
teardown path once the window completes. The title must **exactly** match a
movie's name (case- and diacritic-insensitive). The hook only searches
`includeTypes: [.movie]`, so TV episodes cannot be benched this way, and
`--year` disambiguates remakes that share a title. Afterwards every default
it wrote (including `--set` keys) is deleted, leaving the simulator as it
was found. Results are read back from the simulator's own log store, `xcrun
simctl spawn <udid> log show`; the host's `log show` sees nothing. `--set
key=bool` flips app defaults between A/B configs, and the app must already
be installed and signed in on the target simulator:

    scripts/framedrop-bench.sh --title "Deadgirl" --position 600 --runs 3 \
        --set debug.simulatorTranscode=true

The same defaults work as launch arguments for a scripted device A/B:
`-debug.frameLossBench YES -debug.benchStartSeconds <seconds>`, plus
`-debug.benchSearchTerm <exact title>` and `-debug.benchProductionYear
<year>` when the harness does not already know the item ID. Lagoon resolves
the item through its signed-in Jellyfin client and enters the normal player
path. Pinning the start locally is the point: otherwise the previous run's
Jellyfin progress report advances the next run into a different scene.
These overrides are ignored unless the bench is enabled, and they have no
Settings UI. They are diagnostic launch state, not a playback preference.
On hardware, read the same number off the HUD's Bench line.

The bench, the passthrough timeline and the EL NAL filter are covered by
the `LagoonTests` unit target, the first tests in the project. They were
added because these regressions (timestamp jitter, bitstream mangling,
measurement discipline) are pure logic a simulator pass cannot pin down.

Memory is sampled alongside them. The HUD carries a `Memory:` line
(footprint plus remaining headroom from `os_proc_available_memory()`, which
reads 0 in the simulator and reports real headroom on device), and the
progress loop emits a `Playback Memory` signpost every 10 s with both
figures and the playback position. Watch the footprint's *slope*, not its
absolute value. A leak is a straight line that never plateaus, and it is
the one playback failure that leaves no crash trace, because jetsam writes
a `JetsamEvent` report instead of one. Anything above roughly 0.2 MB/s
sustained over a few minutes needs explaining; the one that shipped is
under the renderer feed below.

The decoded-frame memory ceilings this bench measures against — the byte
budget, the P010 surface arithmetic and the leak that produced them — belong
to the engine, and are in its [frame-loss
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/frame-loss-bench.md).
