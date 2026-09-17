# System media, display mode and debug HUD

Playback engineering notes kept from the September 10, 2026 documentation
cleanup. Start with the [current playback guide](../../playback.md) and the
[notes index](README.md).

## System media integration

Lagoon owns the system behavior AVPlayer would otherwise supply, without
adding a second player to get it:

- `PlaybackAudioSession` activates `.playback` / `.moviePlayback`, enables
  multichannel content, uses `.longFormVideo` on iOS, and deactivates with
  `notifyOthersOnDeactivation` when playback ends. Interruption callbacks are
  idempotent: they resume only if the item was playing and the system sets
  `shouldResume`. Route changes pause when a personal output — wired,
  Bluetooth, or AirPlay — disappears, but not on tvOS HDMI mode changes. A
  media-services reset re-establishes the category and active session.
- **Audio spatialization**. One factory,
  `SampleBufferPlayerEngine.makeAudioRenderer`, builds every audio renderer,
  so a replacement after a failure or a reset sounds identical to what it
  replaced. Apple's two players disagree on the spatialization default:
  `AVPlayerItem` documents `monoStereoAndMultichannel` for video, but
  `AVSampleBufferAudioRenderer` documents — and runtime confirms —
  `multichannel` alone. Left alone, a stereo soundtrack that AVPlayer would
  spatialize on AirPods plays flat, true of a lot of television, anime and
  older film. The property only grants permission: the viewer's Spatial Audio
  setting still decides, and it changes nothing over HDMI to a receiver. A
  test pins both defaults, so a future SDK that closes the gap fails it, and
  the override can go.
- **Playback speed**. 0.5× to 2×, set from the **Video** tab of the playback
  panel, shaped like the audio delay row — a label, the value, `-`/`+`
  steppers — rather than six selectable options: it is one value on a short
  scale that stays at 1× almost always, and both a stacked and a row layout of
  six options were tried and dropped. Stepping clamps at both ends instead of
  wrapping, so a plus at 2× cannot land on 0.5×, and the value dims at 1× the
  way a zero delay does. The options column declares `.focusSection()`; the
  Audio tab does not need it, because its left column is already a list of
  focusable rows, but this card's left column is a summary line, so without
  the section, Down from the tab would find nothing below it and focus would
  never reach the card.

  The transport names the rate beside the title whenever it is not 1×.
  Pausing, seeking, buffering, renderer recovery, delivery fallback and
  next-episode handoff all preserve it. Every audio renderer uses the
  time-domain pitch algorithm, including after a media-services reset. Stall
  recovery, the delivered-PTS margin, initial priming and demux watermarks
  scale their media-time cushion by rate but keep the decoded-frame hard
  limits fixed. Now Playing publishes the real rate, and
  `changePlaybackRateCommand` exposes the same choices to Control Center,
  headset and system clients. The control once lived in the transport as a
  button above the scrubber that opened a menu; that was reverted — see
  [putting controls in the transport](controls-and-reporting.md#putting-controls-in-the-transport-tvos).
- **An engine that has shut down must never be revived**.
  `attach(displayLayer:)` guards on `shutdownRequested`, not just on an empty
  renderer. `finishRendererShutdown` nils `videoRenderer`, so emptiness alone
  let a retired engine through — and SwiftUI *does* re-mount the player
  surface after a failed playback, whose `makeUIView` attaches
  unconditionally. The retired engine then re-registered a renderer set it
  could never detach, because `shutdown` early-returns once requested, and
  started a **second demux loop** that reopened the stream — for a transcode,
  a second server-side ffmpeg job nobody would ever stop. The stale renderer
  entry is process-global, and `PlaybackController.start` waits on it, so one
  failed title delayed the next by the full 15 s timeout, showing "The
  previous video could not release its player resources." Clearing the
  counters in `deinit` was deliberately not tried: renderer removal is
  asynchronous and outlives the Swift object, so only the real AVFoundation
  completion can balance it, or the lifecycle benchmark could no longer see a
  leak. Traced with `debug.playbackLifecycleLog`, printing each lifecycle
  event with the engine id — the ids are what made "the same engine attached
  twice" visible.
- **Audio renderer failure**. An audio renderer posts two *recoverable*
  notifications — `WasFlushedAutomatically` and `OutputConfigurationDidChange`
  — and both reseek from the playhead. Hard failure posts none: Apple exposes
  it only through the KVO-observable `status`, documented as "terminal status
  from which recovery is not always possible." Unobserved, a failed renderer
  kept the film playing in silence, with nothing reported anywhere. The
  observation hops to the main actor instead of `MainActor.assumeIsolated`,
  unlike the notification blocks, because KVO delivers on whichever thread
  changed the property, and a CoreMedia-owned renderer does not change it on
  the main one. Recovery means replacement — the object cannot be revived —
  sharing one path with the media-services reset, which needs the same swap.
  The two differ only in what the viewer is owed after, which
  `AudioRendererReplacement` encodes: a reset stays paused, since Apple
  requires an explicit viewer action before resuming, while a self-failed
  renderer resumes, since nothing the viewer did caused it. Neither un-pauses
  a viewer who paused on purpose: the refill goes through `seek`, and
  `beginPlayback` honours `isPaused`. The video renderer stays attached to the
  synchronizer throughout, so only a few hundred milliseconds of audio are
  lost, not the film. If the swap itself fails, playback has no audio path,
  and the failure is reported as `.delivery`, handed to the
  [delivery ladder](stream-resolution.md#when-playback-fails-the-delivery-ladder-hel-100).
  `debug.regressionInjectAudioRendererFailure` drives this path, since a
  renderer cannot be made to report `.failed` on demand. The HUD's `Recovery:`
  line counts audio replacements and service resets separately, since
  otherwise a replacement would leave no trace — which is the point of
  counting it.
- `NowPlayingCoordinator` publishes a stable Jellyfin item identifier, a
  title/episode line, poster, duration, elapsed time, rate and playback state,
  and registers play, pause, toggle, ±10 s, absolute position, playback-rate
  and audio/subtitle language-option commands. Handlers hop to the main actor
  because MediaPlayer promises no callback queue, and every target plus the
  Now Playing state are removed on teardown.
- PiP uses `AVPictureInPictureController.ContentSource` over the existing
  `AVSampleBufferDisplayLayer` with an
  `AVPictureInPictureSampleBufferPlaybackDelegate` whose play/pause/skip
  callbacks drive the same `SampleBufferPlayerEngine` — there is no hidden
  AVPlayer. iOS exposes the system `AVRoutePickerView` for AirPlay.
  `AVInitialRouteSharingPolicy=LongFormVideo` and the audio background mode
  are declared in the plist.
- Backgrounding on iOS keeps playing. `PlaybackController` observes
  `UIApplication.didEnterBackgroundNotification` and
  `willEnterForegroundNotification` itself, because the player is presented
  from UIKit, where SwiftUI's `scenePhase` never changes — how the old
  pause-on-background rule silently never ran on iOS. Entering the background
  stops proactive cache fill and, unless PiP is active or transitioning
  (`isPictureInPictureShowing`) or AirPlay owns the route, puts the engine
  into audio-only mode: `setVideoOutputSuspended(true)` flushes the video
  renderer, intake and queue on the pump queue, the demux loop discards the
  video stream inside libavformat (`FFmpegDemuxer.setVideoDiscarded`), and the
  software decode stage resets, so nothing decodes and no GPU work runs while
  backgrounded. Audio, the synchronizer clock, the time observer, subtitles
  and the finish boundary carry on. Priming, starvation detection and stall
  recovery treat a suspended picture as a finished video queue, so a
  background network stall recovers on audio alone. Foregrounding resumes with
  a seek to the current position, restarting video on a keyframe and, through
  the seek's decoder reset, a fresh VideoToolbox session — what a hardware
  decoder invalidated by the background needs. A successor engine started by
  autoplay while backgrounded inherits the suspension. tvOS still pauses on
  background via `scenePhase`, since it has no lock screen to play under.
  `-debug.regressionNoAutomaticPiP YES` disables automatic PiP so the
  simulator, which cannot lock into the background, reaches audio-only mode
  through the Home button.
- Skip and Up Next timing lives in `PlaybackAutomation`, owned by the
  controller and fed by the engine's `onTimeAdvanced` callback, so both
  countdowns and the end-of-file hand-off run with the screen locked or the
  player minimised into PiP. The overlays only draw its state.
- **A server as the transport authority**. SyncPlay is the third outside party
  to drive this transport, after Remote Command Center and PiP, and the first
  to care *when* something happens, not just what. The engine gained three
  hooks rather than a group feature. `play(atHostTime:)` reuses the anchor
  `beginPlayback` already had — Apple's recommended custom-playback start
  binds media time to a near-future host time — substituting the group's
  agreed instant for the default `now + 0.1 s`. That substitution must survive
  priming: a start request arriving during a seek or the initial open is
  remembered and applied when `beginPlayback` runs, but only while the instant
  is still ahead of us, since a late member needs the default anchor to start
  playing at all, not a rate change scheduled in the past. `pause()` and
  `seek(to:)` both drop a remembered instant, since both make it wrong.
  `setCorrectionRate` stays separate from `setRate` for the same reason Now
  Playing publishes `rate`: a drift nudge is not a speed the viewer chose.
  `PlaybackRatePolicy.effectiveRate` clamps the product into the one envelope
  everything else scales by. The demux watermarks, the starvation margins and
  the stall-recovery cushion all read that rate, because a corrected clock
  really does drain media faster; at a correction of 1 they compute exactly
  what they did before. Audio pitch needed no change: every renderer already
  uses `.timeDomain`, including replacements, so a corrected rate does not
  change pitch. `clockPosition` exists because `timePosition` is deliberately
  optimistic, and reporting it would tell the server a position nothing has
  presented; while the clock is stopped it answers with the target instead,
  since a Buffering report is about where the member is going.
- Caption rendering reads Apple's Media Accessibility font, foreground,
  opacity, size, background and edge preferences live, and Lagoon's
  per-account override adds size, edge, background and vertical-position
  controls. System caption languages seed the ordered primary/fallback search
  list, and system Forced/Automatic/Always On policy seeds a first playback;
  explicit track selection then feeds the language back to the system
  preference stack, and visible text is reported through
  `MACaptionAppearanceDidDisplayCaptions`. Authored bitmap subtitles keep
  their original appearance and placement.

The tvOS simulator regression suite uses a Debug-only capability profile —
H.264 direct play when possible, otherwise a low-bitrate H.264/AAC HLS
rendition — because CoreSimulator has no dependable HEVC / Dolby Vision
hardware decoder; Release builds and physical Apple TV runs always use the
full `DeviceProfile.lagoon` profile. The real-media UI regressions in
`PlayerRegressionUITests` cover pause/resume, scrubbing both ways, subtitle
selection across a seek, rendered subtitle cues, automatic intro skipping and
audio switching with re-prime. The audio test discovers a server-declared
direct-play H.264 item with multiple tracks, so HLS cannot silently collapse
the fixture to one rendition.

## Watch Together: the group as a transport authority

Measured against the fixture server (Jellyfin 12.0.0) on 2026-09-14 with a
scripted second member. The
[playback guide](../../playback.md#watch-together-syncplay) states the
rules; this records what the server did and why the code is shaped around it.

**The socket has to be carrying messages before the join.** A join sent while
a WebSocket's handshake is still in flight is lost: the app posted
`SyncPlay/Join` about 50 ms after opening the socket, the server moved the
group to Waiting so the join landed, but the app got neither the `GroupJoined`
message nor the `PlayQueue` update that follows — then sat in a group it never
heard from again. There is no HTTP route that returns a group's queue, so the
socket is the only path to it and there is nothing to recover with.
`SyncPlayStore` now waits for the socket's first message, the server's own
`ForceKeepAlive`, which is also the moment the session's connection is
registered. The same trap catches a scripted member: a token shared across two
device ids binds every socket to whichever session the server resolves first,
so updates go to a socket nobody is reading.

**What a join costs the group.** With the group already Playing, the app's
join produced this sequence: `UserJoined`; a `Pause` for everyone at the
group's live position; the joiner's own `PlayQueue` (`NewPlaylist`), naming
the item and position; the app's `Buffering` (the group shows `Waiting ·
Buffer`); the app's `Ready` five seconds later; then, seemingly unprompted, a
`Seek` to wherever the group had got to meanwhile, another `Pause`, and, once
everyone was ready again, the `Unpause` the other member asked for. A newcomer
is caught up by the server, not by guessing — why `onEngineReady` fires on
every seek, not only the first open.

That seek was not the server being helpful. `WaitingGroupState` answers a
`Ready` more than `MaxPlaybackOffset` (500 ms) from the group's position by
flagging that member as buffering again and sending it, alone, a corrective
`Seek` — "session got lost in time, correcting." The app earned one every
time: its readiness report carried `clockPosition` while the synchronizer had
not yet been anchored (see below). Fixed, the sequence is one `Buffering`, one
`Ready` and the group's `Unpause`. Measured 2026-09-14: a rejoin reported
Ready at 116.603 s against a group at 116.658 s, and the room resumed at once,
where the same rejoin had reported 0.000 s against a group at 127 s the run
before.

**How a rejoin could wait for ever.** Closing the player and pressing *Rejoin*
left the group in `Waiting` indefinitely: the HUD read `waiting · 1 member ·
seek`, the queue was full, the clock was anchored, and only *Ignore Waiting*
let the others watch on. Three things compounded. `rejoinPlayback()` opened at
the last command's position, not where the group had got to. `beginPlayback`
announced the end of buffering — which the driver turns into `Ready` — before
anchoring the clock, so the report carried the position being left behind:
zero on a first open, or the pre-seek anchor after a seek. And the corrective
`Seek` that earned, built from the group's own state, arrived identical to the
seek already taken, apart from `EmittedAt`, so `SyncPlayGroupSession.isRepeat`
refused it. The member then had nothing left to seek to or report, and the
server went on waiting. A readiness report that is even slightly dishonest is
not a cosmetic matter: it is one refused command away from a room that never
starts.

**What the automation can do to a group.** A recap segment covering position 0
arms `PlaybackAutomation` from the phantom position `beginItem` starts at, and
an open slower than the five-second skip countdown — a 4K transcode is — lets
it fire before the first real tick corrects it. In a group that skip is a
group `Seek`, so a member rejoining a room at 10:30 dragged everyone back to
the recap's end at 0:35. Reproduced 2026-09-14 on the fixture server; not a
SyncPlay bug and not fixed here, but it is how the hang above was first
provoked.

**A `When` can already be in the past.** One `Pause` arrived with `EmittedAt`
four seconds *after* its own `When` — the server re-issuing the instant the
group had agreed on. `SyncPlayCommandSchedule` clamps the wait to zero, so the
member acts at once, keeping a late arrival aligned instead of scheduling into
the past.

**Drift, measured.** iPhone 17 Pro simulator against the fixture server over
the internet, HLS transcode, one scripted member: drift settled at −37 ms
after the group start, −43 ms after a seek to 120 s and a resume, −41 ms a
minute later, and 0 ms right after an anchor — all inside the 60 ms deadband,
so no correction ran. That is the intended resting state: the rate nudge is
for a member that falls behind, not the steady case.

**Participants are sessions, but the list is names.** Two sessions of the same
user show as one participant, so the HUD's member count is a count of names,
not of devices.

## Display mode matching (tvOS)

The custom player must do by hand what AVPlayerViewController does
automatically: ask the display to match the content. The engine publishes a
`DisplayMatchRequest` — the video's tagged `CMFormatDescription` plus frame
rate — once the demuxer knows the stream, and `VideoPlayerView` applies it to
a window's `AVDisplayManager.preferredDisplayCriteria` (`DisplayModeMatcher`),
clearing it on exit. Lagoon always submits the request; the user's tvOS
Settings → Video and Audio → Match Content options remain the authority, and
criteria are silently ignored when those are disabled. The HUD's `Display:`
line therefore names every observable layer separately: the requested rate,
`no window` / `no manager` (lookup failed, nothing applied), `system on/off`
(the user setting), and `switched ×N`, counting the system's actual
`AVDisplayManagerModeSwitchStart` notifications — the hard proof a request
moved the display. The first hardware run taught why: a collapsed "off" could
not say whether matching was disabled or never reached. Do not require the key
window in the lookup: during a fullScreenCover the key flag is not guaranteed,
and a nil there silently disables the feature; any window of the scene reaches
the screen's manager.

This matters because, without a mode switch, the display idles at 60 Hz in
whatever range the UI runs, and the compositor cadence-converts and tone-maps
every video frame. That per-pixel cost is the standing suspect for the
hardware drops hitting full 3840×2160 HDR10 titles (Resident Evil 2002,
Snowden), while a 3840×1600 letterbox encode with the same codec, range and
bitrate class (Tomorrow War) played clean — the comparison that also cleared
decode throughput, Dolby Vision, bitrate and the audio path for those titles.
Both the original 4K HDR10 failure and Snowden's 610 s stress scene have since
measured zero loss in normal viewer mode on hardware. The simulator has no
display modes at all: `system match off` there, and criteria are a no-op.

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player showing the
negotiated method/container/codecs/range/bitrate plus live engine state,
refreshed every 2 s. It ships in **all** builds, TestFlight included, since
real Apple TV hardware only ever runs Release, and defaults off
(`debug.playbackHUD`, read once at playback start).

Two live diagnostic lines were added to that HUD — renderer queue depths plus
stall count, and AVFoundation's total/dropped/corrupted frame counters — along
with `PlaybackPerformance` signposts carrying the same information off-device:
controller startup, playback cushion readiness, stalls, dismissal-critical
main-actor work, renderer teardown, demux close, the stopped-report request,
and every increase in the dropped/corrupted-frame counters. Frame-loss events
include the delta, playback position, queue depths and stall count, so a
hardware trace can tell decoder pressure from starvation without a screen
recording. Capture them with the Instruments **Points of Interest** template
on real Apple TV hardware; the signposts intentionally ship in
Release/TestFlight.

The HUD is itself a SwiftUI layer composited over video: on Snowden's
full-raster 4K stress scene, two otherwise clean hardware windows measured 4–5
presentation drops with it on and zero in two HUD-off repeats. Use its live
values for diagnosis, but use console/signpost output with
`debug.playbackHUD=false` for the final viewer-mode frame-loss verdict.

**Frame droppability is opt-in metadata** (the end of the 4e2ad5f saga):
CMSampleBuffer.h says, "A frame is considered droppable if and only if
kCMSampleAttachmentKey_IsDependedOnByOthers is present and set to
kCFBooleanFalse." Absent means not droppable. Marking disposable frames
`false` licenses the renderer's *pre-decode* dropper for every non-reference
frame — 67% of the stream on the title that measured 10.7% steady loss at a
matched display rate with full queues. The engine therefore volunteers nothing
by default: `IsDependedOnByOthers` is true only on reference frames, absent
otherwise. The old marking sits behind `debug.markDroppableFrames` for the
hardware A/B. Never trust a simulator A/B here: the pre-decode dropper does
not engage at 60 Hz with software decode.
