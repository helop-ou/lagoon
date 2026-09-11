# HEL-160 background fill during healthy playback — 2026-09-11

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

## What changed

The direct-file cache's proactive fill slept `min(max(requestSeconds, 0.125)
× 4, 8)` after every 1 MiB chunk while playing, a fixed ~20% duty cycle that
capped read-ahead near 2 MiB/s on any link. A failed chunk was indistinguishable
from "nothing left" and ended fill for the rest of the title, with the
finished task handle also blocking `resumeBufferFill`. A foreground read that
caught up with an in-flight prefetch of the same bytes started a second
request for them.

- `PlaybackFillPolicy` (new, pure): below 120 s of cached media ahead of the
  playhead the next chunk follows after a yield of half its own request time
  (uncapped, so a slow link keeps a third of itself for foreground reads); at
  or above the target the old pacing returns; a failed
  chunk backs off 1, 2, 4 … 30 s and is retried; `.exhausted` ends a whole-file
  fill and idle-polls a windowed one; a stall or buffering renderer still gets
  the 20 s cooldown; pause still fills at full speed.
- `PlaybackPrefetchOutcome` replaces the Boolean and carries the prefetch's
  own request time, so pacing no longer measures the cache's aggregate that
  foreground traffic also feeds.
- The fill task clears its handle when its loop ends (generation-guarded), so
  a later `resumeBufferFill` can start again.
- A foreground read whose bytes an in-flight prefetch covers promotes that
  request to foreground priority and waits up to 2 s for it; past the bound it
  fetches for itself. `PlaybackCacheMetrics` gained `cachedBytesAheadOfPlayhead`,
  `duplicateNetworkBytes` and `sharedFetchCount`; the HUD's "Ahead" line and
  the decode trace's `cacheMB`/`aheadMB`/`netMB`/`dupMB`/`shared` fields
  expose them.
- `scripts/fill-bench.sh` plays a title hands-off on a simulator and reports
  the fill from the decode trace so two builds can be compared.

## Simulator A/B — fixture, "Grand Theft Aircraft" (H.264 High 1080p, E-AC-3, 2.06 GB, 6.6 Mbps, direct play)

Baseline: main at `9e75ce1` plus the decode-trace cache fields only, on the
iPhone 17 Pro Max simulator. New: the working tree on the iPhone 17 Pro
simulator. Same Mac, same link, runs sequential, three 120 s runs each from
the start of the title, `-debug.decodeTrace YES`, HUD off, Debug builds.

| Build | 30 s | 60 s | 90 s | 118 s | average | stalls / dropped |
| --- | --- | --- | --- | --- | --- | --- |
| Baseline run 1 | 58 MB | 112 MB | 166 MB | 216 MB | 1.79 MiB/s | 0 / 0 |
| Baseline run 2 | 59 MB | 112 MB | 166 MB | 216 MB | 1.79 MiB/s | 0 / 0 |
| Baseline run 3 | 59 MB | 112 MB | 166 MB | 216 MB | 1.79 MiB/s | 0 / 0 |
| New run 1 | 145 MB | 198 MB | 253 MB | 304 MB | 2.53 MiB/s | 0 / 0 |
| New run 2 | 145 MB | 200 MB | 255 MB | 306 MB | 2.54 MiB/s | 0 / 0 |
| New run 3 | 145 MB | 200 MB | 255 MB | 306 MB | 2.54 MiB/s | 0 / 0 |

Reading: the baseline is pinned at the scheduler's ceiling from the first
sample. The new build fills at the link's pace (about 5 MiB/s on this Mac)
until roughly 100 MB is cached ahead, which is this title's 120 s cushion,
then drops to the relaxed pace, which is why its 60–118 s slope matches the
baseline's. Playback was unaffected in every run. Duplicate traffic over a
run: baseline 2 MB (network minus cached); new 1 MB with one shared fetch,
both at start-up when the demuxer's first reads overlap the initial prefetch.

The public demo's Dracula (4.4 Mbps) behaves the same way but reaches its
cushion within the first half minute, so it is a poor A/B title.

Not measured: the paused fill rate (unchanged code path), the windowed cache
(needs `debug.playbackCacheCapMB` below the title size), and expensive or
constrained networks (the low-priority request flags are unchanged).

## Note on the simulator and HEVC titles

"Grand Theft Auto VI: An Extended Look" (HEVC Main 10 4K) is served as an HLS
transcode to the simulator, so it never has a direct cache and the fill
scheduler does not apply to it there; the first bench attempt on it produced
no cache fields at all. Direct-play verification needs a title the simulator
profile direct-plays.

## Review fixes, same day

A read of the diff found two things the bench could not show. The post-fetch
snapshot advanced the stall counter without anything acting on it, so a stall
landing while a chunk was in flight lost its 20 s cooldown; only the pre-fetch
snapshot consumes a stall now. The hurried yield had an absolute 0.5 s cap,
which let fill take ~95% of a link where a chunk takes 10 s, the opposite of
the intent; the yield is now a plain fraction. A foreground read that outwaits
a promoted prefetch also re-checks cancellation before starting its own
request. The A/B above was run before these fixes; the fast-link numbers are
unaffected (a 0.2 s chunk yields 0.1 s either way).

## Cushion-growth guard, same evening

Jaagop asked whether forward buffering could ever stall playback. The honest
answer was "not on a link with headroom, possibly on one without": the eager
branch persisted while the cushion stayed below two minutes, which on a link
that can barely carry the title means indefinitely, with only the stall
cooldown to interrupt it. The policy now allows the eager yield only while
the cushion grew by at least 0.25 s since the previous chunk; otherwise, and
whenever the cushion cannot be measured, the gentle pace applies. On the
1080p bench the cushion grows every chunk, so the fast-link numbers stand.
`eagerPacingLastsOnlyWhileTheCushionGrows` and
`aSeekThatDropsTheCushionReEvaluatesOnTheNextChunk` pin it.

## Unit coverage

`PlaybackFillPolicyTests` walks the policy through completion, stall, paused,
hurried and relaxed pacing, failure backoff and reset, and the cushion
conversion. `PlaybackCacheTests` gained the failed-then-recovered prefetch, the
outcome's request time, the promoted shared fetch, the bounded fall-through
with its duplicate accounting, `contiguousUpperBound(from:)` and the cushion
metric. Existing cache and transport suites were adapted to the outcome type.

## Still open

- Physical Apple TV validation with the same asset, media-time window and
  network, three runs per configuration, recording delivery method, cache
  capacity, playing/paused fill rates, unique versus transferred bytes,
  stalls, startup/seek latency and resource use (acceptance criterion; the TV
  was not connected on 2026-09-11).
- Whether a 120 s target cushion is the right size for Apple TV's storage
  and links; it is a constant on `PlaybackFillPolicy`.
