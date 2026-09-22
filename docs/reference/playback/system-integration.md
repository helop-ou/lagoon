# System media, display mode and debug HUD

The reasoning behind system integration in the [playback
guide](../../playback.md). See also the [notes index](README.md).

## System media integration

Lagoon supplies the system behavior AVPlayer would, without a second player.
The engine owns its half (audio session and spatialization, never reviving a
shut-down engine, audio renderer recovery, the PiP content source) in its
[system integration
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/system-integration.md).
This side:

**Playback speed**, 0.5× to 2×, set on the playback panel's **Video** tab.

- Shaped like the audio delay row (label, value, `-`/`+` steppers), since it
  is one value that almost always stays at 1×. Stepping clamps at both ends
  (plus at 2× never lands on 0.5×), and the value dims at 1×.
- The options column declares `.focusSection()`. This card's left column is a
  summary line, so without it Down from the tab finds nothing and focus never
  reaches the card. (The Audio tab's left column is focusable rows, so it
  needs none.)
- The control lives in the panel, not the transport; see [putting controls in
  the transport](controls-and-reporting.md#putting-controls-in-the-transport-tvos).
- The transport names the rate beside the title when it is not 1×. Pause,
  seek, buffering, renderer recovery, delivery fallback and next-episode
  handoff all keep it.
- Every audio renderer uses the time-domain pitch algorithm, including after a
  media-services reset.
- Stall recovery, the delivered-PTS margin, priming and demux watermarks scale
  their media-time cushion by rate; the decoded-frame hard limits stay fixed.
- Now Playing publishes the real rate, and `changePlaybackRateCommand` offers
  the same choices to Control Center, headsets and system clients.

**Now Playing.** `NowPlayingCoordinator` publishes a stable Jellyfin item id,
title/episode line, poster, duration, elapsed time, rate and state, and
registers play, pause, toggle, ±10 s, absolute position, playback rate and
audio/subtitle language commands. Handlers hop to the main actor because
MediaPlayer promises no callback queue. Every target and the Now Playing
state are removed on teardown. The plist declares
`AVInitialRouteSharingPolicy=LongFormVideo` and the audio background mode.

**Backgrounding on iOS keeps playing.**

- `PlaybackController` observes `UIApplication.didEnterBackgroundNotification`
  and `willEnterForegroundNotification` itself. The player is presented from
  UIKit, where SwiftUI's `scenePhase` never changes.
- Entering the background stops proactive cache fill. Unless PiP is active or
  transitioning (`isPictureInPictureShowing`) or AirPlay owns the route, the
  engine goes audio-only: `setVideoOutputSuspended(true)` flushes the video
  renderer, intake and queue on the pump queue; the demuxer discards the video
  stream (`FFmpegDemuxer.setVideoDiscarded`); the software decode stage
  resets. No decode or GPU work runs.
- Audio, the synchronizer clock, the time observer, subtitles and the finish
  boundary continue. Priming, starvation detection and stall recovery treat a
  suspended picture as a finished video queue, so a background network stall
  recovers on audio alone.
- Foregrounding seeks to the current position: video restarts on a keyframe
  with a fresh VideoToolbox session, which a decoder invalidated in the
  background needs.
- A successor engine started by autoplay in the background inherits the
  suspension.
- tvOS still pauses on background via `scenePhase`; it has no lock screen.
- `-debug.regressionNoAutomaticPiP YES` disables automatic PiP so the
  simulator (which cannot lock) reaches audio-only mode through Home.

**Skip and Up Next timing** lives in `PlaybackAutomation`, owned by the
controller and driven by the engine's `onTimeAdvanced`, so countdowns and the
end-of-file hand-off run with the screen locked or in PiP. Overlays only draw
its state.

**A server as the transport authority.** SyncPlay is the first outside driver
(after Remote Command Center and PiP) that cares _when_ something happens.
The engine has hooks, not a group feature:

- `play(atHostTime:)` reuses `beginPlayback`'s anchor (Apple's custom-playback
  start binds media time to a near-future host time), replacing the default
  `now + 0.1 s` with the group's instant.
- A start request arriving during a seek or the initial open is remembered
  and applied when `beginPlayback` runs, but only if the instant is still
  ahead; a late member needs the default anchor. `pause()` and `seek(to:)`
  drop a remembered instant.
- `setCorrectionRate` stays separate from `setRate`: a drift nudge is not a
  speed the viewer chose. `PlaybackRatePolicy.effectiveRate` clamps the
  product. Demux watermarks, starvation margins and the stall cushion all read
  it, since a corrected clock drains media faster; at correction 1 nothing
  changes. Pitch is unaffected, since every renderer uses `.timeDomain`.
- `clockPosition` exists because `timePosition` is deliberately optimistic.
  While the clock is stopped it answers with the target, since a Buffering
  report is about where the member is going.

**Captions.** Rendering reads Apple's Media Accessibility font, foreground,
opacity, size, background and edge preferences live. Lagoon's per-account
override adds size, edge, background and vertical position.

- System caption languages seed the ordered primary/fallback search list, and
  the system Forced/Automatic/Always On policy seeds a first playback.
- An explicit track choice feeds its language back to the system preference
  stack. Visible text is reported through
  `MACaptionAppearanceDidDisplayCaptions`.
- Bitmap subtitles keep their authored appearance and placement.

**Simulator profile.** The tvOS simulator regression suite uses a Debug-only
profile (H.264 direct play when possible, else a low-bitrate H.264/AAC HLS
rendition), because CoreSimulator has no dependable HEVC / Dolby Vision
decoder. Release builds and Apple TV hardware always use
`DeviceProfile.lagoon`. `PlayerRegressionUITests` covers pause/resume,
scrubbing both ways, subtitle selection across a seek, rendered cues,
automatic intro skip and audio switching with re-prime. The audio test finds a
direct-play H.264 item with several tracks, so HLS cannot collapse the fixture
to one rendition.

## Watch Together: the group as a transport authority

What the server did, measured against Jellyfin 12.0.0 with a scripted second
member. The rules are in the [playback
guide](../../playback.md#watch-together-syncplay) and the mechanics in [Watch
Together](watch-together.md).

**Join before the socket carries messages, and the join is lost.** A join
posted about 50 ms after opening the socket landed on the server, but the app
received neither `GroupJoined` nor the `PlayQueue` update and never heard from
the group again. No HTTP route returns a group's queue, so there is no
recovery. `SyncPlayStore` waits for the first message (`ForceKeepAlive`),
which is also when the server registers the connection. For scripted members:
a token shared across two device ids binds every socket to whichever session
the server resolves first.

**What a join costs the group.** Joining a Playing group produces:
`UserJoined`; a `Pause` for everyone at the live position; the joiner's
`PlayQueue` (`NewPlaylist`) with item and position; the joiner's `Buffering`;
its `Ready`; then the other member's `Unpause`. The server catches a newcomer
up, which is why `onEngineReady` fires on every seek, not only the first open.

**The corrective seek.** `WaitingGroupState` answers a `Ready` more than
`MaxPlaybackOffset` (500 ms) from the group's position by marking that member
buffering again and sending it a `Seek`. An anchored report fixed it: a
rejoin reported 116.603 s against the group's 116.658 s and the room resumed
at once, where the unanchored report said 0.000 s against 127 s.

**How a rejoin waited forever.** Three faults together left the group in
`Waiting` until someone chose Ignore Waiting:

- `rejoinPlayback()` opened at the last command's position, not the group's
  current one.
- `beginPlayback` announced the end of buffering before anchoring the clock,
  so Ready carried the old position.
- The server's corrective `Seek`, built from the group's state, was identical
  to the one already taken except `EmittedAt`, so `SyncPlayGroupSession`
  refused it as a repeat.

A slightly wrong readiness report is one refused command away from a room
that never starts.

**Automation can drag a group.** A recap segment covering position 0 arms
`PlaybackAutomation` from the phantom start position, and an open slower than
the five-second skip countdown (a 4K transcode) lets it fire before the first
real tick. In a group that skip is a group `Seek`, so one rejoining member
dragged everyone from 10:30 back to 0:35. Not a SyncPlay bug, and not fixed.

**A `When` can already be past.** One `Pause` arrived with `EmittedAt` four
seconds after its own `When`. `SyncPlayCommandSchedule` clamps the wait to
zero so the member acts at once.

**Drift at rest** (iPhone simulator, HLS transcode over the internet): −37 ms
after start, −43 ms after a seek, −41 ms a minute later, 0 ms after an anchor.
All inside the 60 ms deadband, so no correction ran, as intended.

**Participants are names.** Two sessions of one user show as one participant,
so the HUD's member count counts names, not devices.

## Display mode matching (tvOS)

The custom player must ask the display to match the content, as
AVPlayerViewController does automatically.

- The engine publishes a `DisplayMatchRequest` (the tagged
  `CMFormatDescription` plus frame rate) once the demuxer knows the stream.
  `VideoPlayerView` applies it to a window's
  `AVDisplayManager.preferredDisplayCriteria` (`DisplayModeMatcher`) and
  clears it on exit.
- Lagoon always submits it. The user's Settings → Video and Audio → Match
  Content options decide; criteria are silently ignored when those are off.
- **Do not require the key window** in the lookup. During a fullScreenCover
  the key flag is not guaranteed, and nil silently disables matching. Any
  window of the scene reaches the screen's manager.
- The HUD's `Display:` line names each layer: the requested rate; `no window`
  / `no manager` (lookup failed); `system on/off` (the user setting); and
  `switched ×N`, counting `AVDisplayManagerModeSwitchStart` notifications, the
  proof a switch happened.

Without a switch the display idles at 60 Hz in the UI's range, and the
compositor cadence-converts and tone-maps every frame. That was the suspect
for hardware drops on full 3840×2160 HDR10 titles, while a 3840×1600 encode of
the same codec, range and bitrate class played clean. Both previously failing
4K HDR10 cases now measure zero loss in normal viewing on hardware. The
simulator has no display modes (`system match off`); criteria are a no-op
there.

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay showing the negotiated
method, container, codecs, range and bitrate plus live engine state, refreshed
every 2 s. It ships in **all** builds, since Apple TV hardware only runs
Release, and defaults off (`debug.playbackHUD`, read at playback start).

- Live lines include renderer queue depths with stall count, and
  AVFoundation's total/dropped/corrupted frame counters.
- `PlaybackPerformance` signposts carry the same information off-device:
  controller startup, cushion readiness, stalls, dismissal-critical main-actor
  work, renderer teardown, demux close, the stopped report, and every increase
  in dropped or corrupted frames (with delta, position, queue depths and stall
  count, so a trace separates decoder pressure from starvation). Capture with
  Instruments' **Points of Interest** template on hardware; the signposts ship
  in Release.
- **The HUD itself costs frames**: on a full-raster 4K stress scene, two
  otherwise clean hardware windows had 4–5 drops with it on and zero in two
  HUD-off repeats. Diagnose with it, but give the final frame-loss verdict
  from console and signposts with `debug.playbackHUD=false`.

**Frame droppability is opt-in metadata.** CMSampleBuffer.h: a frame is
droppable only if `kCMSampleAttachmentKey_IsDependedOnByOthers` is present and
`false`. Marking non-reference frames `false` lets the renderer's pre-decode
dropper take every one of them (67% of the stream on a title that measured
10.7% steady loss with a matched display rate and full queues). So the engine
sets `IsDependedOnByOthers` true on reference frames and leaves it absent
otherwise. The old marking sits behind `debug.markDroppableFrames` for a
hardware A/B. Never trust a simulator A/B here: the pre-decode dropper does
not engage at 60 Hz with software decode.
