# Roadmap

Product priorities and remaining acceptance as recorded on September 10, 2026.
Jira is authoritative for live ticket status; this page does not claim a
TestFlight upload or a public release. Shipped feature history belongs in
[`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift), with the current feature
overview in the [repository README](../README.md).

## Toward 1.0

1. **Finish touch-player acceptance (HEL-153).** Centered controls, clear
   glass, double-tap seeking, scrubbing, landscape handling, and repeated
   auto-hide/reveal pass the iPhone/iPad simulator journeys. Physical PiP,
   VoiceOver, thumbnails, and Skip/Up Next touch journeys remain. See the
   [validation record](archive/hel-153-touch-validation.md).
2. **Complete physical-device acceptance (HEL-144, HEL-41).** Exercise
   iPhone/iPad touch, rotation, keyboards, large text, VoiceOver, interruptions,
   lock screen, AirPlay, and PiP captions. Watch a full captioned film on Apple
   TV from the intended TestFlight build. Simulator coverage does not replace
   those checks.
3. **Prepare the public candidate (HEL-143).** The single list of privacy,
   native licensing, encryption, website, review metadata, and signed-archive
   requirements is in [Release](release.md#public-release).
4. **Verify the remaining playback fixes on hardware.** The outgoing-engine
   retention fix (HEL-152) needs device confirmation. Subtitle-over-HDR frame
   loss (HEL-148) improved but remains nonzero in recorded runs; retain its
   full-film acceptance work rather than claiming the issue resolved.

## Awaiting device or deployment verification

These are acceptance items carried forward from the engineering records,
not new feature requests or a live Jira status report:

- Audio refill (HEL-124), transcode cache selection (HEL-130), interlaced
  MPEG-2 (HEL-127), and the iOS cellular cap (HEL-108).
- Dolby Vision profile 7 to 8.1 conversion (HEL-145), including display mode
  and the same-scene frame-loss comparison on an Apple TV.
- Remote touch reveal and finish-time display (HEL-134), browse refresh
  (HEL-135), recent searches (HEL-129), and post-playback resume state (HEL-132).
- Account/privacy cleanup, local-network permission recovery, and native
  transport device checks (HEL-141/142/143); evidence is in the
  [archive index](archive/README.md).
- Jellyfin 12 deployment acceptance (HEL-138) when the private server upgrades
  from 10.11.11. The public demo's stable channel is already 12.0.0, and on
  2026-09-11 browsing, direct play and HLS on the remux rung passed there
  inside the app; the [API guide](jellyfin-api.md#jellyfin-12-compatibility-hel-138)
  records what that covers and that a sustained video transcode on 12 is
  still unexercised.

## Next

1. **Downloads completeness (HEL-166, later phases).** Season and series
   batch downloads, subtitle sidecars, chapters and trickplay offline,
   auto-delete after watching, then smart next-episode downloads under their
   own storage budget. The MVP (single films and episodes, quality choice,
   offline playback with resume) lands in build 100.
2. **1080i H.264 direct play (HEL-127 remainder).** Add a measured
   pixel-buffer deinterlacing stage for the hardware path.
3. **Live TV.** Guide and channels for servers that provide them; substantial
   product work, with no ticket recorded here yet.
4. **Route-loss responsiveness (HEL-149 follow-up).** Investigate the recorded
   862 ms main-actor block when removing AirPods while paused. Keep it separate
   from the already-measured connection/re-prime behavior.
5. **iPhone mini player.** Revisit after the PiP-on-exit behavior has been used
   on physical devices.

Potential later work: a server plugin for fetch-only subtitle search without
granting library writes. A server-wide Top 10 (HEL-121) remains dependent on an
upstream Streamystats endpoint. A personal most-watched row was declined.

Code organization work (HEL-155) has its own bounded sequence in
[Architecture](architecture.md#refactoring-priorities): controller ownership,
playback infrastructure placement, request/settings composition, and shared
test support. It should not be represented as a viewer-facing feature.

## Deliberate non-goals

- Offline downloads on Apple TV: tvOS gives an app no persistent storage
  guarantee. iPhone and iPad downloads (HEL-166) are a separate owner from
  the playback cache, which stays transient and is discarded on exit.
- A second playback engine: all playback stays behind `PlayerEngine`.
- A direct subtitle-provider integration: search stays with the selected
  Jellyfin server and its administrator-configured providers.
