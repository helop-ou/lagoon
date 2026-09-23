# Roadmap

Product priorities and remaining acceptance as of September 17, 2026. Shipped
history is in [`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift);
the feature overview is the [repository README](../README.md).

## Toward 1.0

1. **Finish touch-player acceptance.** Centred controls, clear glass,
   double-tap seeking, scrubbing, landscape and repeated auto-hide pass the
   iPhone/iPad simulator journeys. Owed: physical PiP, VoiceOver, thumbnails,
   and Skip/Up Next touch journeys.
2. **Complete physical-device acceptance.** iPhone/iPad touch, rotation,
   keyboards, large text, VoiceOver, interruptions, lock screen, AirPlay and
   PiP captions, then a full captioned film on Apple TV from the intended
   TestFlight build. Also Increase Contrast and Dim Flashing Lights on the
   sample-buffer player: there is no evidence yet of app-level flashing-light
   integration or system mitigation.
3. **Publish the source, then open external testing.** Lagoon goes open
   source under MPL-2.0, excluding the name and brand assets. Publishing first
   satisfies FFmpeg's licence for builds distributed outside the team without
   a per-release burden. Supporting work: rotate the diagnostics key, remove
   personal infrastructure, scrub the history, trim the documentation and
   normalise native licences.
4. **Prepare the public candidate.** Privacy, native licensing, encryption,
   website, review metadata and signed-archive requirements are listed once,
   in [Release](release.md#public-release).
5. **Verify the remaining playback fixes on hardware.** The outgoing-engine
   retention fix needs device confirmation. Subtitle-over-HDR frame loss is
   lower but still nonzero in recorded runs; it stays open, with full-film
   acceptance owed.

## Awaiting device or deployment verification

Acceptance carried forward from engineering work:

- Audio refill, transcode cache selection, interlaced MPEG-2 and the iOS
  cellular cap.
- Dolby Vision profile 7 to 8.1 conversion: the television reporting Dolby
  Vision for a MEL and a FEL title. Frame loss on Apple TV is measured.
- Remote touch reveal and finish-time display, browse refresh, recent
  searches and post-playback resume state.
- Account and privacy cleanup, local-network permission recovery and native
  transport device checks.
- Watch Together on hardware. Simulator-verified end to end against Jellyfin
  12.0.0 with a scripted second member. Owed: an Apple TV and an iPhone in
  one group, checking the start instant, drift correction over a full film, a
  phone locking mid-group, and the Together tab and toast on a television.
- Jellyfin 12 deployment acceptance, once the fixture server moves off
  10.11.11. On the public demo (12.0.0), browsing, direct play and HLS on the
  remux rung pass in the app. A sustained video transcode on 12 is untested.
- A stalling episode that no longer drops to a transcode, on Apple TV over a
  link slow enough to starve the picture. The gate that stops a flushed
  renderer starting on a stale sample is unit-tested, but the race only
  appears when the demux thread sits in a long read. Watch `startPointDrops`
  climb while delivery stays `negotiated`, and check a held skip fires when
  the picture moves.
- Player dismissal racing a suspended startup request, on Apple TV.
  Dismissal/replay and episode handoff showed no change after the source
  migration; this case is untested.

## Next

1. **Later downloads phases.** Season and series batches, subtitle sidecars,
   chapters and trickplay offline, auto-delete after watching, then smart
   next-episode downloads with their own storage budget. The MVP (single
   films and episodes, quality choice, offline playback with resume) has
   shipped.
2. **Finish 1080i H.264 direct play.** Add a measured pixel-buffer
   deinterlacing stage for the hardware path.
3. **Live TV.** Guide and channels for servers that provide them. Substantial
   and unscoped.
4. **Route-loss responsiveness.** Investigate the recorded 862 ms main-actor
   block when removing AirPods while paused, separately from the
   already-measured connection and re-prime behavior.
5. **iPhone mini player.** Revisit once PiP-on-exit has been used on physical
   devices.

Possible later work: a server plugin for fetch-only subtitle search without
granting library writes, and a server-wide watch-count ranking (needs an
upstream statistics endpoint; Top 10 rows approximate it through Seerr today).

Code organization work follows [Architecture](architecture.md#refactoring-priorities);
it is not a viewer-facing feature.

## Deliberate non-goals

- Offline downloads on Apple TV. tvOS gives no persistent storage guarantee.
  iPhone and iPad downloads have their own owner, separate from the playback
  cache, which is transient and discarded on exit.
- A second playback engine. All playback stays behind `PlayerEngine`.
- A direct subtitle-provider integration. Search stays with the Jellyfin
  server and its administrator-configured providers.
