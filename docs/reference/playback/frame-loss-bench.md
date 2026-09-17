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

### Decoded-frame memory ceiling

The bench samples physical footprint at roughly 1 Hz over the same
warmup-delimited window. `BenchResult` and its signpost report
`memoryStartMB`, `memoryPeakMB`, `memoryGrowthMB` and the minimum jetsam
headroom as `minimumAvailableMB`. The HUD freezes peak and growth into the
`Bench:` line. Record it on a physical Apple TV for a 3840×2160 Main 10 HDR
title with the HUD off, so the overlay does not alter the video path. The
console line carries the presentation dimensions and whether the stream
used VideoToolbox or libavcodec, which makes a captured result
self-identifying.

Above roughly 24 MB a frame, the frame *count* stops bounding anything
useful and `DemuxBackpressurePolicy.videoHardLimit` falls back to bytes.
The software path's 42-frame limit was chosen when it carried SD and HD
video, where 42 frames meant 250 MB at 1080p 10-bit. But software AV1
reaching 4K made those same 42 frames 1.05 GB of P010 surfaces, in a
process jetsam has already killed once at 2100 MB. The budget,
`decodedQueueByteBudget`, is deliberately set to the ceiling the
hardware-decoded path was already permitted (30 frames of 4K P010, 746 MB).
Every configuration measured before this change keeps the limit it was
measured with, and only 4K software decode is brought back under it. A
floor of 8 frames survives however large a frame gets, because a queue
still has to hold the codec's reorder depth plus a cushion.

The arithmetic behind those figures: a 4:2:0 P010 surface is `3840 × 2160
× 3 = 24,883,200` bytes (23.73 MiB), luma plus half as many chroma samples
in 16-bit words. That makes the app-visible queue alone roughly 427/712
MiB at 4K Main 10, with the decoded-video soft/hard limits of 18/30
frames. It is an estimate, not a process ceiling. VideoToolbox may retain
6–16 reorder surfaces and the renderer owns another private set, which is
why the bench peak is the authority. Do not lower the 18-frame soft
cushion from arithmetic alone. It is the reserve that removed steady 4K
presentation loss. If a physical peak leaves too little headroom, reduce
the 30-frame hard limit first and repeat the identical window.

The renderer feed is kept cheap under high-bitrate load. Packet wakeups are
coalesced onto a user-interactive serial pump. The app-side sample FIFO is
head-indexed and amortized O(1) rather than shifting its whole Swift array
for every frame. The demuxer blocks on condition-driven video/audio
high-water marks and resumes at lower thresholds instead of polling queue
counts. Compressed payloads retain FFmpeg's existing backing buffer
(`av_buffer_ref` behind a `CMBlockBufferCustomBlockSource`) instead of
being copied per packet. Decoded LPCM coalesces into a reused
`NSMutableData` that swresample fills in place, and then **is copied** into
a CoreMedia-owned block at emit. All of this reduces Lagoon's copying,
allocation, scheduling and ARC overhead. Codec decode remains
AVFoundation's.

**Do not make the LPCM emit zero-copy.** An earlier version handed that
`NSMutableData` to CoreMedia behind a custom block source, and
the free callback never ran. The app leaked the entire decoded audio stream
at ~2.2 MB/s on TrueHD 7.1, and jetsam killed it for `per-process-limit` at
2100 MB partway through a movie, with a `JetsamEvent` report rather than a
crash trace. The copy that bought that back costs 1.5 MB/s on the demux
queue, roughly 0.03% of a core, and cannot reach the render path. A matched
pair of 6.5-minute 4K/TrueHD runs measured 2 dropped frames out of ~9300
either way and 0 stalls, with footprint going 131 → 113 MB fixed versus
225 → 1003 MB leaking. The compressed video handoff uses the same
block-source pattern and is measured leak-free, so the pattern itself is
fine. Only the
LPCM use of it regressed. It was isolated by playing one file twice and
switching only the audio track (TrueHD vs AC-3), which holds the video path
constant. That is the fastest way to attribute a playback leak to audio or
video.
