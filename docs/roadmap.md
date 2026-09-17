# Roadmap

Product priorities and remaining acceptance, as of September 17, 2026 — not a
TestFlight upload or a public release. Shipped feature history is in
[`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift); the current
feature overview is the [repository README](../README.md).

## Toward 1.0

1. **Finish touch-player acceptance.** Centered controls, clear glass,
   double-tap seeking, scrubbing, landscape handling, and repeated
   auto-hide/reveal pass the iPhone/iPad simulator journeys. Physical PiP,
   VoiceOver, thumbnails, and Skip/Up Next touch journeys remain.
2. **Complete physical-device acceptance.** Exercise iPhone/iPad touch,
   rotation, keyboards, large text, VoiceOver, interruptions, lock screen,
   AirPlay, and PiP captions, then watch a full captioned film on Apple TV
   from the intended TestFlight build; simulator coverage does not replace
   these. Also cover Increase Contrast and Dim Flashing Lights on the custom
   sample-buffer player: evidence so far does not show app-level
   flashing-light integration or system mitigation.
3. **Publish the source, then open external testing.** Lagoon is going open
   source under MPL-2.0, excluding the name and brand assets. Publishing first
   satisfies FFmpeg's licence for builds distributed outside the team and
   avoids a per-release burden. Supporting work: rotate the diagnostics key
   and remove personal infrastructure, scrub the history, trim the
   documentation, and normalise native licences. Engine extraction is not a
   prerequisite and stays after 1.0.
4. **Prepare the public candidate.** The single list of privacy, native
   licensing, encryption, website, review metadata, and signed-archive
   requirements is in [Release](release.md#public-release).
5. **Verify the remaining playback fixes on hardware.** The outgoing-engine
   retention fix needs device confirmation. Subtitle-over-HDR frame loss
   improved but is still nonzero in recorded runs; its full-film acceptance
   work stays open, and the issue is not resolved.

## Awaiting device or deployment verification

Acceptance items carried forward from the engineering records, not new feature
requests or a live status report:

- Audio refill, transcode cache selection, interlaced MPEG-2, and the iOS
  cellular cap.
- Dolby Vision profile 7 to 8.1 conversion, including display mode and the
  same-scene frame-loss comparison on an Apple TV.
- Remote touch reveal and finish-time display, browse refresh, recent
  searches, and post-playback resume state.
- Account/privacy cleanup, local-network permission recovery, and native
  transport device checks.
- Watch Together on hardware. Simulator-verified end to end against the
  fixture server on Jellyfin 12.0.0 with a scripted second member. Owed: two
  real devices in one group — an Apple TV and an iPhone — for the start
  instant, drift correction over a full film, a phone that locks mid-group,
  and the look of the Together tab and toast on a television.
- Jellyfin 12 deployment acceptance, once the fixture server upgrades from
  10.11.11. The public demo's stable channel is already 12.0.0, and browsing,
  direct play and HLS on the remux rung have passed there inside the app. The
  [API guide](jellyfin-api.md) records what that covers. A sustained video
  transcode on 12 is still unexercised.
- Player dismissal that races a suspended startup request, on an Apple TV.
  The source migration's other lifecycle checks, dismissal/replay and
  episode handoff, showed no change against the pre-migration build; this
  one stays unexercised.

## Next

1. **Downloads completeness for later phases.** Season and series batch
   downloads, subtitle sidecars, chapters and trickplay offline, auto-delete
   after watching, then smart next-episode downloads under their own storage
   budget. The MVP — single films and episodes, quality choice, offline
   playback with resume — lands in build 100.
2. **Finish 1080i H.264 direct play.** Add a measured pixel-buffer
   deinterlacing stage for the hardware path.
3. **Live TV.** Guide and channels for servers that provide them: substantial,
   unscoped product work.
4. **Route-loss responsiveness follow-up.** Investigate the recorded 862 ms
   main-actor block when removing AirPods while paused. Keep it separate from
   the already-measured connection/re-prime behavior.
5. **iPhone mini player.** Revisit after the PiP-on-exit behavior has been
   used on physical devices.

Potential later work: a server plugin for fetch-only subtitle search without
granting library writes. There is already an approximation: when Seerr is
connected, Home intersects trending and popular movie/show catalogues with the
signed-in Jellyfin library for Top 10 rows. A server-wide watch-count ranking
still needs an upstream statistics endpoint.

Code organization work has its own bounded sequence in
[Architecture](architecture.md#refactoring-priorities): controller ownership,
playback infrastructure placement, request/settings composition, and shared
test support — not a viewer-facing feature.

## Deliberate non-goals

- Offline downloads on Apple TV: tvOS gives no persistent storage guarantee,
  so iPhone and iPad downloads are a separate owner from the playback cache,
  which stays transient and is discarded on exit.
- A second playback engine: all playback stays behind `PlayerEngine`.
- A direct subtitle-provider integration: search stays with the selected
  Jellyfin server and its administrator-configured providers.
