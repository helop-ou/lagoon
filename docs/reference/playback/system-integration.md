# System media, display mode and debug HUD

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [current playback guide](../../playback.md) and the
[notes index](README.md).

## System media integration (HEL-41, HEL-80)

Lagoon owns the system behavior AVPlayer would otherwise supply, without
introducing a second player to get it:

- `PlaybackAudioSession` activates `.playback` / `.moviePlayback`, enables
  multichannel content, uses `.longFormVideo` on iOS, and deactivates with
  `notifyOthersOnDeactivation` when playback ends. Interruption callbacks are
  idempotent: resume only when the item was playing and the system sets
  `shouldResume`. Route changes pause when a personal output (wired,
  Bluetooth, or AirPlay) disappears, but not for tvOS HDMI mode changes.
  Media-services reset re-establishes the category and active session.
- **Audio spatialization** (HEL-105). Every audio renderer is built by one
  factory, `SampleBufferPlayerEngine.makeAudioRenderer`, so a replacement
  after a failure or a media-services reset sounds exactly like the renderer
  it replaces. What the factory changes is the spatialization default, which
  differs between Apple's two players and not in this one's favour:
  `AVPlayerItem` documents `monoStereoAndMultichannel` for video content,
  while `AVSampleBufferAudioRenderer` documents — and, verified at runtime,
  really does default to — `multichannel` alone. Left alone, a stereo
  soundtrack that AVPlayer would spatialize on AirPods plays flat, which
  covers a great deal of television, anime and older film. The property
  grants permission rather than forcing an effect: the viewer's Spatial Audio
  setting still decides, and over HDMI to a receiver it changes nothing.
  A test pins both defaults, so if a future SDK closes the gap it says so and
  the override can go.
- **Playback speed** (HEL-106). 0.5× through 2×, from the playback panel's
  **Video** tab, shaped like the audio delay row — a label, the value, a pair
  of `-`/`+` steppers — rather than six selectable options, because it is one
  value from a short ordered scale that is left at 1× almost always; those
  options were tried both stacked and as a row and neither earned the space.
  Stepping clamps at both ends rather than wrapping (a plus at 2× that landed
  on 0.5× reads as a bug) and the value dims at 1× exactly as a zero delay
  does. The options column declares `.focusSection()`, which the Audio tab does
  not need because its left column is a list of focusable rows; this card's
  left column is a summary line, and without the section Down from the tab
  finds nothing below it and focus never enters the card at all.

  The transport shows the selected rate beside the title whenever it is not
  1×. Pausing, seeking, buffering, renderer recovery, delivery fallback and
  next-episode handoff all preserve it. Every audio renderer uses the
  time-domain pitch algorithm, including a replacement after media-services
  reset. Stall recovery, the delivered-PTS margin, initial priming and demux
  watermarks scale their media-time cushion by rate while retaining the
  decoded-frame hard limits. Now Playing publishes the real rate and
  `changePlaybackRateCommand` exposes the same choices to Control Center,
  headset and system clients. The control briefly lived in the transport
  instead, as a button above the scrubber that opened a menu; that was
  reverted — see
  [putting controls in the transport](controls-and-reporting.md#putting-controls-in-the-transport-tvos).
- **An engine that has shut down must never be revived** (HEL-110).
  `attach(displayLayer:)` guards on `shutdownRequested`, not only on the
  renderer being empty. `finishRendererShutdown` nils `videoRenderer`, so the
  emptiness check alone let a retired engine pass — and SwiftUI *does* re-mount
  the player surface after a failed playback, whose `makeUIView` attaches
  unconditionally. The retired engine then re-registered a renderer set that
  could never be detached, because `shutdown` early-returns once requested, and
  started a **second demux loop** that reopened the stream — for a transcode,
  a second server-side ffmpeg job nobody would ever stop. The stale renderer
  entry is process-global and `PlaybackController.start` waits on it, so one
  failed title delayed the next by the full 15 s timeout and showed "The
  previous video could not release its player resources." Deliberately *not*
  fixed by clearing the counters in `deinit`: renderer removal is asynchronous
  and outlives the Swift object, so its real AVFoundation completion has to
  balance the counter or the lifecycle benchmark stops being able to see a leak
  at all. Traced with `debug.playbackLifecycleLog`, which prints each lifecycle
  event with the engine id — the ids are what made "the same engine attached
  twice" visible.
- **Audio renderer failure** (HEL-101). The two notifications an audio
  renderer posts — `WasFlushedAutomatically` and
  `OutputConfigurationDidChange` — are its *recoverable* events, and both
  reseek from the playhead. Hard failure has no notification: Apple exposes it
  only as the KVO-observable `status`, "terminal status from which recovery is
  not always possible". Unobserved, a failed renderer left the film playing on
  in silence with nothing reported anywhere. The observation hops to the main
  actor rather than using `MainActor.assumeIsolated` like the notification
  blocks, because KVO is delivered on whichever thread changed the property and
  a CoreMedia-owned renderer does not change it on the main one.
  Recovery is replacement — the object cannot be revived — and it shares one
  path with the media-services reset, which needs the same swap. The two
  differ only in what the viewer is owed afterwards, which is what
  `AudioRendererReplacement` encodes: a reset stays paused because Apple
  requires an explicit viewer action before resuming, while a renderer that
  failed on its own resumes, since nothing the viewer did caused it. Neither
  un-pauses a viewer who paused deliberately: the refill goes through `seek`,
  and `beginPlayback` honours `isPaused`. The video renderer stays attached
  to the synchronizer throughout, so what is lost is a few hundred
  milliseconds of audio rather than the film. If the swap itself fails,
  playback has no audio path at all and the failure is reported as
  `.delivery`, which hands it to the
  [delivery ladder](stream-resolution.md#when-playback-fails-the-delivery-ladder-hel-100).
  `debug.regressionInjectAudioRendererFailure` drives it, since a renderer
  cannot be made to report `.failed` on demand, and the HUD's `Recovery:` line
  counts audio replacements and service resets separately — otherwise a
  replacement leaves no trace at all, which is the point of it.
- `NowPlayingCoordinator` publishes a stable Jellyfin item identifier,
  title/episode line, poster, duration, elapsed time, rate and playback state,
  and registers play, pause, toggle, ±10 s, absolute position, playback-rate
  and audio/subtitle language-option commands. Handlers hop to the main actor
  because MediaPlayer promises no callback queue; every target and the Now
  Playing state itself are removed on teardown.
- PiP uses `AVPictureInPictureController.ContentSource` over the existing
  `AVSampleBufferDisplayLayer` with an
  `AVPictureInPictureSampleBufferPlaybackDelegate` whose play/pause/skip
  callbacks drive the same `SampleBufferPlayerEngine` — there is no hidden
  AVPlayer. iOS exposes the system `AVRoutePickerView` for AirPlay.
  `AVInitialRouteSharingPolicy=LongFormVideo` and the audio background mode
  are declared in the plist.
- Backgrounding on iOS keeps playing (HEL-176). `PlaybackController`
  observes `UIApplication.didEnterBackgroundNotification` and
  `willEnterForegroundNotification` itself — the player is presented from
  UIKit, where SwiftUI's `scenePhase` never changes, which is how the old
  pause-on-background silently never ran on iOS. Entering the background
  stops proactive cache fill and, unless PiP is active/transitioning (the
  view answers through `isPictureInPictureShowing`) or AirPlay owns the
  route, puts the engine into audio-only mode:
  `setVideoOutputSuspended(true)` flushes the video renderer, intake and
  queue on the pump queue, and the demux loop then discards the video
  stream inside libavformat (`FFmpegDemuxer.setVideoDiscarded`) and resets
  the software decode stage, so nothing decodes and no GPU work is
  submitted while the app is in the background. Audio, the synchronizer
  clock, the periodic time observer, subtitles and the finish boundary
  carry on. Priming, starvation detection and stall recovery all treat a
  suspended picture as a finished video queue, so a network stall in the
  background recovers on audio alone. Returning to the foreground resumes
  with a seek to the current position, which restarts video on a keyframe and,
  through the seek's decoder reset, on a fresh VideoToolbox session — the
  one a hardware decoder invalidated by the background needs. A successor
  engine started by autoplay while backgrounded inherits the suspension.
  tvOS keeps pausing on background through the view's `scenePhase`; it
  has no lock screen to play under. `-debug.regressionNoAutomaticPiP YES`
  turns automatic PiP off so the simulator, which cannot lock into the
  background, reaches the audio-only path through the Home button.
- Skip and Up Next timing lives in `PlaybackAutomation`, owned by the
  controller and fed by the engine's `onTimeAdvanced` callback, so both
  countdowns and the end-of-file hand-off run with the screen locked or
  the player minimised into PiP. The overlays only draw its state.
- **A server as the transport authority** (HEL-172). SyncPlay is the third
  outside party to drive this transport, after Remote Command Center and
  PiP, and the first to care *when* something happens rather than only
  what. So the engine gained three hooks rather than a group feature.
  `play(atHostTime:)` reuses the anchor `beginPlayback` already had — Apple's
  recommended custom-playback start binds media time to a near-future host
  time — and simply substitutes the instant the group agreed on for the
  default `now + 0.1 s`. That substitution has to survive priming: a start
  request arriving while a seek or the initial open is in flight is
  remembered and applied by `beginPlayback` when it runs, but only while the
  instant is still ahead of us, because a late member needs the default
  anchor to get playing at all rather than a rate change scheduled in the
  past. `pause()` and `seek(to:)` drop a remembered instant; both make it
  wrong. `setCorrectionRate` is separate from `setRate` for the same reason
  Now Playing publishes `rate`: a drift nudge is not a speed the viewer
  chose. `PlaybackRatePolicy.effectiveRate` clamps the product into the one
  envelope everything else scales by, and the demux watermarks, the
  starvation margins and the stall-recovery cushion all read the effective
  rate, because a corrected clock really does drain media faster — at a
  correction of 1 they compute exactly what they did before. Audio pitch
  needed nothing: every renderer already uses `.timeDomain`, including
  replacements (HEL-105), so a corrected rate does not change pitch.
  `clockPosition` exists because `timePosition` is deliberately optimistic
  and reporting it would tell the server a position nothing has presented;
  while the clock is stopped it answers with the target instead, since a
  Buffering report is about where the member is going.
- Caption rendering reads Apple's Media Accessibility font, foreground,
  opacity, size, background and edge preferences live; Lagoon's per-account
  override adds size, edge, background and vertical-position controls. System
  caption languages seed the ordered primary/fallback search list, system
  Forced/Automatic/Always On policy seeds a first playback, explicit track
  selection feeds the language back to the system preference stack, and visible
  text is reported through `MACaptionAppearanceDidDisplayCaptions`. Authored
  bitmap subtitles keep their original appearance and placement.

The tvOS simulator regression suite uses a Debug-only capability profile —
H.264 direct play when possible, otherwise a low-bitrate H.264/AAC HLS
rendition — because CoreSimulator has no dependable HEVC / Dolby Vision
hardware decoder; Release builds and physical Apple TV runs always use the full
`DeviceProfile.lagoon` profile. The real-media UI regressions in
`PlayerRegressionUITests` cover pause/resume, scrubbing both ways, subtitle
selection across a seek, rendered subtitle cues, automatic intro skipping and
audio switching/re-prime. The audio test discovers a server-declared
direct-play H.264 item with multiple tracks so HLS cannot silently collapse the
fixture to one rendition.

## Watch Together: the group as a transport authority (HEL-172)

Measured against fixture (Jellyfin 12.0.0) on 2026-09-14 with a scripted
second member. The [playback guide](../../playback.md#watch-together-syncplay-hel-172)
states the rules; this is what the server actually did and why the code is
shaped around it.

**The socket has to be carrying messages before the join.** A join announced
over a WebSocket whose handshake is still in flight is simply lost: the app
posted `SyncPlay/Join` ~50 ms after opening the socket, the server moved the
group to Waiting (so the join landed), and the app received neither the
`GroupJoined` nor the `PlayQueue` update that follows it — then sat in a group
it never heard from again. There is no HTTP route that returns a group's
queue, so the socket is the only path to it and there is nothing to recover
with. `SyncPlayStore` now waits for the socket's first message, the server's
own `ForceKeepAlive`, which is also the moment the session's connection is
registered. The same trap catches a scripted member: a token shared across two
device ids binds every socket to whichever session the server resolves first,
and the updates go to a socket nobody is reading.

**What a join costs the group.** With the group already Playing, the app's
join produced, in order: `UserJoined`; a `Pause` for everyone at the group's
live position; the joiner's own `PlayQueue` (`NewPlaylist`) naming the item and
that position; the app's `Buffering` (the group shows `Waiting · Buffer`); the
app's `Ready` five seconds later; then — unprompted — a `Seek` to where the
group had got to in the meantime, another `Pause`, and, once everyone was
ready again, the `Unpause` the other member asked for. So a newcomer is caught
up by the server rather than by guessing, which is exactly why `onEngineReady`
has to fire on every seek and not only on the first open.

**A `When` can already be in the past.** One `Pause` arrived with
`EmittedAt` four seconds *after* its own `When` — the server re-issuing the
instant the group had agreed on. `SyncPlayCommandSchedule` clamps the wait to
zero and the member acts at once, which is what keeps a late arrival aligned
instead of scheduling into the past.

**Drift, in practice.** iPhone 17 Pro simulator against fixture over the
internet, HLS transcode, one scripted member: drift settled at −37 ms after
the group start, −43 ms after a seek to 120 s and a resume, −41 ms a minute
later, and 0 ms immediately after an anchor. All inside the 60 ms deadband, so
no correction ran — which is the intended resting state; the rate nudge exists
for the member that falls behind, not for the steady case.

**Participants are sessions, but the list is names.** Two sessions of the same
user show as one participant, so the HUD's member count is a count of names,
not of devices.

## Display mode matching (tvOS, HEL-64)

The custom player must do by hand what AVPlayerViewController does
automatically: ask the display to match the content. The engine publishes a
`DisplayMatchRequest` (the video's tagged `CMFormatDescription` plus frame
rate) once the demuxer knows the stream; `VideoPlayerView` applies it to a
window's `AVDisplayManager.preferredDisplayCriteria` (`DisplayModeMatcher`) and
clears it on exit. Lagoon always submits the request; the user's tvOS Settings →
Video and Audio → Match Content options remain the authority, and criteria are
silently ignored when those are disabled. The HUD's `Display:` line therefore
names every observable layer separately — the requested rate, `no window` /
`no manager` (lookup failed, nothing was applied), `system on/off` (the user
setting), and `switched ×N` counting the system's actual
`AVDisplayManagerModeSwitchStart` notifications, the hard proof a request moved
the display. The first hardware run taught why: a collapsed "off" could not say
whether matching was disabled or never reached. Do not require the key window
in the lookup — during a fullScreenCover the key flag isn't guaranteed, and a
nil there silently disables the feature; any window of the scene reaches the
screen's manager.

Why this landed on HEL-64: without a mode switch the display idles at 60 Hz in
whatever range the UI runs, and the compositor cadence-converts and tone-maps
every video frame. That per-pixel cost is the standing suspect for the hardware
drops that hit full 3840×2160 HDR10 titles (Resident Evil 2002, Snowden) while
a 3840×1600 letterbox encode with the same codec, range and bitrate class
(Tomorrow War) played clean — the comparison that also exonerated decode
throughput, Dolby Vision, bitrate and the audio path for those titles. Both the
original 4K HDR10 failure and Snowden's 610 s stress scene have since measured
zero loss in normal viewer mode on hardware. The simulator has no display modes
at all (`system match off` there, criteria are a no-op).

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player showing
the negotiated method/container/codecs/range/bitrate plus live engine state
refreshed every 2 s. Ships in **all** builds, TestFlight included — real
Apple TV hardware only ever runs Release; defaults off
(`debug.playbackHUD`, read once at playback start).

HEL-56 added two live diagnostic lines to that HUD — renderer queue depths plus
stall count, and AVFoundation's total/dropped/corrupted frame counters — and
the `PlaybackPerformance` signposts that carry the same information off-device:
controller startup, playback cushion readiness, stalls, dismissal-critical
main-actor work, renderer teardown, demux close, the stopped-report request,
and every increase in the dropped/corrupted-frame counters. Frame-loss events
include the delta, playback position, queue depths and stall count, so a
hardware trace can distinguish decoder pressure from starvation without a
screen recording. Capture them with the Instruments **Points of Interest**
template on real Apple TV hardware; the signposts intentionally ship in
Release/TestFlight.

The HUD is itself a SwiftUI layer composited over video. On Snowden's
full-raster 4K stress scene, two otherwise clean hardware windows measured
4–5 presentation drops with the HUD on and zero in two HUD-off repeats.
Use its live values for diagnosis, but use console/signpost output with
`debug.playbackHUD=false` for the final viewer-mode frame-loss verdict.

**Frame droppability is opt-in metadata** (HEL-64, the end of the
4e2ad5f saga): CMSampleBuffer.h — "A frame is considered droppable if
and only if kCMSampleAttachmentKey_IsDependedOnByOthers is present and
set to kCFBooleanFalse." Absent = not droppable. Marking disposable
frames `false` licenses the renderer's *pre-decode* dropper for every
non-reference frame — 67% of the stream on the title that measured
10.7% steady loss at a matched display rate with full queues. The
engine therefore volunteers nothing by default (`IsDependedOnByOthers`
true on reference frames only, absent otherwise); the old marking sits
behind `debug.markDroppableFrames` for the hardware A/B. Never trust a
sim A/B of this: the pre-decode dropper doesn't engage at 60 Hz with
software decode.
