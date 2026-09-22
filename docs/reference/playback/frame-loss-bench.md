# Frame-loss bench

The measurement harness behind the playback guide's [regression
checks](../../playback.md#regression-checks). See also the [notes
index](README.md).

## Frame-loss bench

**Compare only the same scene over the same media-time window, with the
simulator untouched, over three or more runs.** Content alone varies loss 3×
within one file, and two "fixes" measured across different scenes, positions
and sampling rates were later retracted. A simulator screenshot forces a
render capture and drops frames, so never take one inside a window.

Settings → Debug → Frame-Loss Bench builds that rule into the app:

- After every playback start or seek it warms up for 10 s of _media time_,
  then measures a 60 s window. Windows follow position, not wall time, so a
  stall lengthens the run without diluting the count. Stalls are reported,
  not discarded.
- The result freezes into the HUD's `Bench:` line and a `Bench Result`
  signpost: dropped/frames/percent, stalls, `aGaps`, minimum queue depth,
  window start, and two of Apple's metrics: `optimized` (frames shown through
  the direct-display path that bypasses UI compositing, read against
  `frames`) and `delayMs` (accumulated display lateness).
- Touching the transport re-arms it from the new position. The protocol is
  "seek to the scene, hands off, read the number", on simulator and hardware
  alike.

`scripts/framedrop-bench.sh` automates repeated simulator runs. The app must
already be installed and signed in on the target simulator:

    scripts/framedrop-bench.sh --title "Deadgirl" --position 600 --runs 3 \
        --set debug.simulatorTranscode=true

- It uses `MainTabView`'s launch-time bench hook
  (`launchBenchItemIfRequested()`), not a `lagoon://` deep link: the router
  drops links without the current Top Shelf `?owner=&generation=` pair.
- Each run force-quits the app, writes `debug.frameLossBench`,
  `debug.playbackHUD`, `debug.benchAutoExit`, `debug.benchSearchTerm` (the
  movie title), `debug.benchStartSeconds` (the pinned start) and optionally
  `debug.benchProductionYear` with `simctl spawn … defaults write`, then
  relaunches. The app resolves the title in the Movies library and starts at
  that position; `debug.benchAutoExit` leaves through the clean teardown once
  the window completes.
- The title must **exactly** match a movie's name (case- and
  diacritic-insensitive). Only movies are searched, so episodes cannot be
  benched this way. `--year` separates remakes.
- `--set key=bool` flips app defaults between A/B configurations.
- Every default it wrote, including `--set` keys, is deleted afterwards.
- Results come from the simulator's own log store
  (`xcrun simctl spawn <udid> log show`); the host's `log show` sees nothing.

For a scripted device A/B the same defaults work as launch arguments:
`-debug.frameLossBench YES -debug.benchStartSeconds <seconds>`, plus
`-debug.benchSearchTerm <exact title>` and
`-debug.benchProductionYear <year>` when the harness does not know the item
ID. Pinning the start matters: otherwise the previous run's progress report
moves the next run into a different scene. These overrides only apply with the
bench enabled and have no Settings UI. On hardware, read the HUD's Bench line.

The bench, the passthrough timeline and the EL NAL filter are covered by
`LagoonTests`, because timestamp jitter, bitstream mangling and measurement
discipline are pure logic a simulator pass cannot pin down.

**Memory.** The HUD's `Memory:` line shows footprint and headroom from
`os_proc_available_memory()` (0 in the simulator, real on device), and the
progress loop emits a `Playback Memory` signpost every 10 s with both figures
and the position. Watch the footprint's _slope_: a leak is a straight line
that never plateaus, and jetsam leaves a `JetsamEvent` report rather than a
crash. Anything above about 0.2 MB/s sustained over a few minutes needs
explaining.

The decoded-frame memory ceilings (byte budget, P010 surface arithmetic) are
the engine's, in its [frame-loss
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/frame-loss-bench.md).
