# Validation run, September 12, 2026

Archived validation record. Dates, ticket states, and results below apply to
the recorded work. Use the [current guides](../README.md) and the
[regression lane reference](../reference/regression-lane.md) for ongoing work.

The public-demo UI lane run twice on clean state on each platform, without a
fixture environment, as the repeatability evidence audit A18 asks for
(HEL-144). Everything ran on simulators while Jaagop was away; no physical
device is claimed.

## Environment

- Xcode 26; tvOS 26.5 for the regression device (`7399D9F5`), tvOS 26.2 for
  the unit suite (`E3DF3575`), iOS 26.0 for the iPhone 17 Pro (`A79FF3D9`).
- Public demo `demo.jellyfin.org/stable` (Jellyfin 12), user `demo`. No
  `LAGOON_REGRESSION_*` in the environment, so every fixture-tier journey
  skipped with its named reason.
- Lane launches pass `-debug.regressionResetState YES`; each pass started
  from the state the previous pass left, which the reset then removed.
- Revision `a97357a` for the lane passes (the resolver flag and the two
  pinned journeys included); the engine fix below was built on top of it.

## Results

| Lane | Pass 1 | Pass 2 |
| --- | --- | --- |
| tvOS UI lane (`LagoonHardwareRegression`, 45 journeys) | 28 passed, 16 skipped, 1 failed | 29 passed, 16 skipped, 0 failed |
| iOS UI lane (`LagoonHardwareRegression`, 11 journeys) | 5 passed, 6 skipped, 0 failed | 5 passed, 6 skipped, 0 failed |
| tvOS unit suite (`Lagoon`, with the engine fix) | 762 tests in 97 suites passed | |

The two tvOS passes differ in exactly one outcome:
`testRepeatedBufferedScrubbingRecoversAndPreservesPlaybackState` failed in
pass 1 and passed in pass 2. Every skip on both platforms names a fixture
(loopback synthetic, subtitle, multi-audio, direct-stream, skippable series,
VC-1, the decade-filter catalogue option, tvOS having no local-network
permission). The refresh-alignment journey passed both times, as it has
since its expectation was corrected on September 8.

One unit test, `anOptedOutAttemptCanEnableSamplingAndAnEndedAttemptCannotRestartIt`,
timed out its two-second poll once while the unit build shared the machine
with a lane pass; it passed twice in isolation in under a tenth of a second
and the full suite passed on the rerun. Load, not code.

## The scrubbing failure: a dropped backward seek

Pass 1 timed out on the third cycle's backward seek. The committed target
was 197 s; the last probe read `time=272.5 buffering=0 rate=1 videoQueued=90
aDry=1`. The recording XCTest keeps of a failed journey, read with the HUD
on, showed the sequence: after the commit the clock kept running from about
241 s, the audio queue emptied with `lead -36.81 s` (post-seek audio from
197 s had been enqueued behind a clock at 243 s), the video queue sat full
with 503 packets parked in intake, and five seconds later playback settled
at 247 s with `7 playhead fills`. The demuxer had seeked; the clock had not
been re-anchored to the target.

`seek(to:)` records the pending seek, then flushes the renderers and queues
synchronously on the pump queue. The demux thread only notices the pending
seek at the top of its loop, so a thread blocked in a network read at that
moment finishes the read afterwards, enqueues one more pre-seek packet into
the emptied queue, and the emptied renderer takes it at once. Its PTS
becomes `firstEnqueuedVideoPTS`, and `PlaybackClockAnchor` prefers that over
the target whenever it lies beyond it, which a pre-seek PTS always does on a
backward scrub. The clock restarted at the old position and the demuxer
raced the picture forward to it. Forward scrubs are immune (the stale PTS
lies before the target) and the race needs a read in flight at the moment
of the commit, which repeated scrubbing across cache holes produces.

Fix: the seek's flush is now `flushRenderersAndQueues`, and the demux loop
calls it once more, on the pump queue, when it performs the seek, before
the prime. Nothing legitimate can be in the renderer at that point.

| Check with the fix | Result |
| --- | --- |
| `testRepeatedBufferedScrubbingRecoversAndPreservesPlaybackState`, three consecutive runs on the regression device | 3 of 3 passed, 29.8 s, 29.4 s and 30.9 s (the failing run had timed out at 59 s) |
| tvOS unit suite | 762 passed |
| Both simulator builds | green |

## Not covered

No physical device; no fixture-server pass tonight (the September 11 record
holds the last one). The fix changes the seek path of the engine and wants a
hardware scrub session before a release: repeated forward and backward
scrubs across a long direct-play title, watching that every landing shows
the asked-for time.
