# System media, display mode and debug HUD

Playback engineering notes kept from the September 10, 2026 documentation
cleanup. Start with the [current playback guide](../../playback.md) and the
[notes index](README.md).

## System media integration

Lagoon owns the system behavior AVPlayer would otherwise supply, without
adding a second player to get it:

- `PlaybackAudioSession` activates `.playback` / `.moviePlayback`, enables
  multichannel content, uses `.longFormVideo` on iOS, and deactivates with
  `notifyOthersOnDeactivation` when playback ends. Interruption callbacks
  are idempotent: they resume only if the item was playing and the system
  sets `shouldResume`. Route changes pause when a personal output — wired,
  Bluetooth, or AirPlay — disappears, but not on tvOS HDMI mode changes. A
  media-services reset re-establishes the category and the active session.
- **Audio spatialization**. Every audio renderer comes from one factory,
  `SampleBufferPlayerEngine.makeAudioRenderer`, so a renderer replaced
  after a failure or a media-services reset sounds exactly like the one it
  replaced. The factory sets the spatialization default, and Apple's two
  players disagree on it: `AVPlayerItem` documents
  `monoStereoAndMultichannel` for video, while `AVSampleBufferAudioRenderer`
  documents — and running it confirms — a default of `multichannel` alone.
  Left alone, a stereo soundtrack that AVPlayer would spatialize on AirPods
  plays flat, which covers a lot of television, anime and older film. The
  property grants permission, not an effect: the viewer's Spatial Audio
  setting still decides, and over HDMI to a receiver it changes nothing. A
  test pins both defaults, so a future SDK that closes the gap will fail
  it, and the override can go.
- **Playback speed**. 0.5× through 2×, set from the playback panel's
  **Video** tab. It is shaped like the audio delay row — a label, the
  value, and `-`/`+` steppers — rather than six selectable options: it is
  one value on a short scale that stays at 1× almost always, and stacked
  or row layouts of six options were both tried and neither earned the
  space. Stepping clamps at both ends instead of wrapping, so a plus at 2×
  cannot land on 0.5×, and the value dims at 1× the way a zero delay does.
  The options column declares `.focusSection()`; the Audio tab does not
  need this, because its left column is already a list of focusable rows,
  while this card's left column is a summary line — without the section,
  Down from the tab finds nothing below it and focus never enters the
  card.

  The transport shows the selected rate beside the title whenever it is
  not 1×. Pausing, seeking, buffering, renderer recovery, delivery
  fallback and next-episode handoff all preserve it. Every audio renderer
  uses the time-domain pitch algorithm, including a replacement after a
  media-services reset. Stall recovery, the delivered-PTS margin, initial
  priming and demux watermarks all scale their media-time cushion by
  rate, keeping the decoded-frame hard limits fixed. Now Playing
  publishes the real rate, and `changePlaybackRateCommand` exposes the
  same choices to Control Center, headset and system clients. The control
  once lived in the transport instead, as a button above the scrubber
  that opened a menu; that was reverted — see
  [putting controls in the transport](controls-and-reporting.md#putting-controls-in-the-transport-tvos).
- **An engine that has shut down must never be revived**.
  `attach(displayLayer:)` guards on `shutdownRequested`, not just on the
  renderer being empty. `finishRendererShutdown` nils `videoRenderer`, so
  emptiness alone let a retired engine through — and SwiftUI *does*
  re-mount the player surface after a failed playback, whose `makeUIView`
  attaches unconditionally. The retired engine then re-registered a
  renderer set that could never be detached, because `shutdown`
  early-returns once requested, and it started a **second demux loop**
  that reopened the stream — for a transcode, a second server-side
  ffmpeg job nobody would ever stop. The stale renderer entry is
  process-global, and `PlaybackController.start` waits on it, so one
  failed title delayed the next by the full 15 s timeout and showed "The
  previous video could not release its player resources." Clearing the
  counters in `deinit` was deliberately not tried: renderer removal is
  asynchronous and outlives the Swift object, so only the real
  AVFoundation completion can balance the counter, or the lifecycle
  benchmark could no longer see a leak at all. Traced with
  `debug.playbackLifecycleLog`, which prints each lifecycle event with
  the engine id; the ids are what made "the same engine attached twice"
  visible.
- **Audio renderer failure**. An audio renderer posts two notifications —
  `WasFlushedAutomatically` and `OutputConfigurationDidChange` — and both
  are *recoverable* events that reseek from the playhead. Hard failure
  posts no notification: Apple exposes it only through the
  KVO-observable `status`, documented as "terminal status from which
  recovery is not always possible." Left unobserved, a failed renderer
  let the film keep playing in silence, with nothing reported anywhere.
  The observation hops to the main actor instead of using
  `MainActor.assumeIsolated`, as the notification blocks do, because KVO
  delivers on whichever thread changed the property, and a
  CoreMedia-owned renderer does not change it on the main one. Recovery
  means replacement — the object cannot be revived — and it shares one
  path with the media-services reset, which needs the same swap. The two
  differ only in what the viewer is owed afterwards, and
  `AudioRendererReplacement` encodes that: a reset stays paused, because
  Apple requires an explicit viewer action before resuming, while a
  renderer that failed on its own resumes, since nothing the viewer did
  caused it. Neither case un-pauses a viewer who paused deliberately: the
  refill goes through `seek`, and `beginPlayback` honours `isPaused`. The
  video renderer stays attached to the synchronizer throughout, so what
  is lost is a few hundred milliseconds of audio, not the film. If the
  swap itself fails, playback has no audio path at all, and the failure
  is reported as `.delivery`, which hands it to the
  [delivery ladder](stream-resolution.md#when-playback-fails-the-delivery-ladder-hel-100).
  `debug.regressionInjectAudioRendererFailure` drives this path, since a
  renderer cannot be made to report `.failed` on demand. The HUD's
  `Recovery:` line counts audio replacements and service resets
  separately; otherwise a replacement would leave no trace at all, which
  defeats the point of it.
- `NowPlayingCoordinator` publishes a stable Jellyfin item identifier, a
  title/episode line, poster, duration, elapsed time, rate and playback
  state. It registers play, pause, toggle, ±10 s, absolute position,
  playback-rate and audio/subtitle language-option commands. Handlers hop
  to the main actor because MediaPlayer promises no callback queue, and
  every target plus the Now Playing state itself are removed on
  teardown.
- PiP uses `AVPictureInPictureController.ContentSource` over the existing
  `AVSampleBufferDisplayLayer` with an
  `AVPictureInPictureSampleBufferPlaybackDelegate` whose play/pause/skip
  callbacks drive the same `SampleBufferPlayerEngine` — there is no
  hidden AVPlayer. iOS exposes the system `AVRoutePickerView` for
  AirPlay. `AVInitialRouteSharingPolicy=LongFormVideo` and the audio
  background mode are declared in the plist.
- Backgrounding on iOS keeps playing. `PlaybackController` observes
  `UIApplication.didEnterBackgroundNotification` and
  `willEnterForegroundNotification` itself, because the player is
  presented from UIKit, where SwiftUI's `scenePhase` never changes. That
  is how the old pause-on-background rule silently never ran on iOS.
  Entering the background stops proactive cache fill. Unless PiP is
  active or transitioning — the view answers through
  `isPictureInPictureShowing` — or AirPlay owns the route, it also puts
  the engine into audio-only mode: `setVideoOutputSuspended(true)`
  flushes the video renderer, intake and queue on the pump queue, and
  the demux loop then discards the video stream inside libavformat
  (`FFmpegDemuxer.setVideoDiscarded`) and resets the software decode
  stage. Nothing decodes and no GPU work is submitted while the app is
  backgrounded. Audio, the synchronizer clock, the periodic time
  observer, subtitles and the finish boundary all carry on. Priming,
  starvation detection and stall recovery all treat a suspended picture
  as a finished video queue, so a network stall in the background
  recovers on audio alone. Returning to the foreground resumes with a
  seek to the current position, which restarts video on a keyframe and,
  through the seek's decoder reset, on a fresh VideoToolbox session — the
  one a hardware decoder invalidated by the background needs. A
  successor engine started by autoplay while backgrounded inherits the
  suspension. tvOS keeps pausing on background through the view's
  `scenePhase`, because it has no lock screen to play under.
  `-debug.regressionNoAutomaticPiP YES` turns automatic PiP off, so the
  simulator, which cannot lock into the background, reaches the
  audio-only path through the Home button.
- Skip and Up Next timing lives in `PlaybackAutomation`, owned by the
  controller and fed by the engine's `onTimeAdvanced` callback, so both
  countdowns and the end-of-file hand-off run with the screen locked or
  the player minimised into PiP. The overlays only draw its state.
- **A server as the transport authority**. SyncPlay is the third outside
  party to drive this transport, after Remote Command Center and PiP,
  and the first to care *when* something happens rather than only what.
  So the engine gained three hooks instead of a group feature.
  `play(atHostTime:)` reuses the anchor `beginPlayback` already had —
  Apple's recommended custom-playback start binds media time to a
  near-future host time — and substitutes the instant the group agreed
  on for the default `now + 0.1 s`. That substitution has to survive
  priming: a start request arriving while a seek or the initial open is
  in flight is remembered and applied by `beginPlayback` when it runs,
  but only while the instant is still ahead of us. A late member needs
  the default anchor to start playing at all, rather than a rate change
  scheduled in the past. `pause()` and `seek(to:)` both drop a
  remembered instant, because both make it wrong. `setCorrectionRate` is
  separate from `setRate` for the same reason Now Playing publishes
  `rate`: a drift nudge is not a speed the viewer chose.
  `PlaybackRatePolicy.effectiveRate` clamps the product into the one
  envelope everything else scales by. The demux watermarks, the
  starvation margins and the stall-recovery cushion all read the
  effective rate, because a corrected clock does drain media faster; at
  a correction of 1 they compute exactly what they did before. Audio
  pitch needed no change: every renderer already uses `.timeDomain`,
  including replacements, so a corrected rate does not change pitch.
  `clockPosition` exists because `timePosition` is deliberately
  optimistic, and reporting it would tell the server a position nothing
  has presented; while the clock is stopped it answers with the target
  instead, since a Buffering report is about where the member is going.
- Caption rendering reads Apple's Media Accessibility font, foreground,
  opacity, size, background and edge preferences live. Lagoon's
  per-account override adds size, edge, background and
  vertical-position controls. System caption languages seed the ordered
  primary/fallback search list, and system Forced/Automatic/Always On
  policy seeds a first playback. Explicit track selection feeds the
  language back to the system preference stack, and visible text is
  reported through `MACaptionAppearanceDidDisplayCaptions`. Authored
  bitmap subtitles keep their original appearance and placement.

The tvOS simulator regression suite uses a Debug-only capability profile:
H.264 direct play when possible, otherwise a low-bitrate H.264/AAC HLS
rendition, because CoreSimulator has no dependable HEVC / Dolby Vision
hardware decoder. Release builds and physical Apple TV runs always use
the full `DeviceProfile.lagoon` profile. The real-media UI regressions in
`PlayerRegressionUITests` cover pause/resume, scrubbing both ways,
subtitle selection across a seek, rendered subtitle cues, automatic
intro skipping and audio switching with re-prime. The audio test
discovers a server-declared direct-play H.264 item with multiple tracks,
so HLS cannot silently collapse the fixture to one rendition.

## Watch Together: the group as a transport authority

Measured against the fixture server (Jellyfin 12.0.0) on 2026-09-14, with
a scripted second member. The
[playback guide](../../playback.md#watch-together-syncplay-hel-172) states
the rules; this records what the server actually did and why the code is
shaped around it.

**The socket has to be carrying messages before the join.** A join sent
over a WebSocket whose handshake is still in flight is lost. The app
posted `SyncPlay/Join` about 50 ms after opening the socket; the server
moved the group to Waiting, so the join landed, but the app got neither
the `GroupJoined` message nor the `PlayQueue` update that follows it, and
sat in a group it never heard from again. There is no HTTP route that
returns a group's queue, so the socket is the only path to it, and there
is nothing to recover with. `SyncPlayStore` now waits for the socket's
first message — the server's own `ForceKeepAlive` — which is also the
moment the session's connection is registered. The same trap catches a
scripted member: a token shared across two device ids binds every socket
to whichever session the server resolves first, so updates go to a
socket nobody is reading.

**What a join costs the group.** With the group already Playing, the
app's join produced this sequence: `UserJoined`; a `Pause` for everyone
at the group's live position; the joiner's own `PlayQueue`
(`NewPlaylist`), naming the item and that position; the app's
`Buffering` (the group shows `Waiting · Buffer`); the app's `Ready` five
seconds later; then, seemingly unprompted, a `Seek` to wherever the
group had got to in the meantime, another `Pause`, and, once everyone
was ready again, the `Unpause` the other member asked for. A newcomer is
caught up by the server rather than by guessing — why `onEngineReady`
has to fire on every seek, not only on the first open.

That seek was not the server being helpful. `WaitingGroupState` answers
a `Ready` whose position is more than `MaxPlaybackOffset` (500 ms) from
the group's position by flagging that member as buffering again and
sending it, and only it, a corrective `Seek` — "session got lost in
time, correcting." The app earned one every time, because its readiness
report carried `clockPosition` while the synchronizer had not been
anchored yet (see below). With that fixed, the sequence is one
`Buffering`, one `Ready` and the group's `Unpause`. Measured 2026-09-14:
a rejoin reported Ready at 116.603 s against a group at 116.658 s, and
the room resumed at once, where the same rejoin had reported 0.000 s
against a group at 127 s the run before.

**How a rejoin could wait for ever.** Closing the player and pressing
*Rejoin* left the group in `Waiting` indefinitely: the HUD read
`waiting · 1 member · seek`, the queue was full, the clock was anchored,
and only *Ignore Waiting* let the others watch on. Three things
compounded. `rejoinPlayback()` opened at the last command's position
rather than where the group had got to. `beginPlayback` announced the
end of buffering — which the driver turns into `Ready` — before
anchoring the clock, so the report carried the position being left
behind: zero on a first open, or the pre-seek anchor after a seek. And
the corrective `Seek` that earned, built from the group's own state,
arrived identical to the seek already taken, apart from `EmittedAt`, so
`SyncPlayGroupSession.isRepeat` refused it. The member then had nothing
left to seek to and nothing left to report, and the server went on
waiting for it. A readiness report that is even slightly dishonest is
therefore not a cosmetic matter: it is one refused command away from a
room that never starts.

**What the automation can do to a group.** A recap segment that covers
position 0 arms `PlaybackAutomation` from the phantom position
`beginItem` starts at. An open slower than the five-second skip
countdown — a 4K transcode is — lets it fire before the first real tick
corrects it. In a group, that skip is a group `Seek`, so a member
rejoining a room at 10:30 dragged everyone back to the recap's end at
0:35. Reproduced 2026-09-14 on the fixture server. This is not a
SyncPlay bug and is not fixed here, but it is how the hang above was
first provoked.

**A `When` can already be in the past.** One `Pause` arrived with
`EmittedAt` four seconds *after* its own `When` — the server re-issuing
the instant the group had agreed on. `SyncPlayCommandSchedule` clamps
the wait to zero, so the member acts at once, which keeps a late arrival
aligned instead of scheduling into the past.

**Drift, measured.** iPhone 17 Pro simulator against the fixture server
over the internet, HLS transcode, one scripted member: drift settled at
−37 ms after the group start, −43 ms after a seek to 120 s and a resume,
−41 ms a minute later, and 0 ms immediately after an anchor. All inside
the 60 ms deadband, so no correction ran — the intended resting state;
the rate nudge exists for a member that falls behind, not for the
steady case.

**Participants are sessions, but the list is names.** Two sessions of
the same user show as one participant, so the HUD's member count is a
count of names, not of devices.

## Display mode matching (tvOS)

The custom player must do by hand what AVPlayerViewController does
automatically: ask the display to match the content. The engine
publishes a `DisplayMatchRequest` — the video's tagged
`CMFormatDescription` plus frame rate — once the demuxer knows the
stream. `VideoPlayerView` applies it to a window's
`AVDisplayManager.preferredDisplayCriteria` (`DisplayModeMatcher`) and
clears it on exit. Lagoon always submits the request; the user's tvOS
Settings → Video and Audio → Match Content options remain the
authority, and criteria are silently ignored when those are disabled.
The HUD's `Display:` line therefore names every observable layer
separately: the requested rate, `no window` / `no manager` (lookup
failed, nothing was applied), `system on/off` (the user setting), and
`switched ×N`, which counts the system's actual
`AVDisplayManagerModeSwitchStart` notifications — the hard proof a
request moved the display. The first hardware run taught why this
separation matters: a collapsed "off" could not say whether matching
was disabled or never reached. Do not require the key window in the
lookup: during a fullScreenCover the key flag is not guaranteed, and a
nil there silently disables the feature; any window of the scene
reaches the screen's manager.

This matters because, without a mode switch, the display idles at 60 Hz
in whatever range the UI runs, and the compositor cadence-converts and
tone-maps every video frame. That per-pixel cost is the standing
suspect for the hardware drops that hit full 3840×2160 HDR10 titles
(Resident Evil 2002, Snowden), while a 3840×1600 letterbox encode with
the same codec, range and bitrate class (Tomorrow War) played clean —
the comparison that also exonerated decode throughput, Dolby Vision,
bitrate and the audio path for those titles. Both the original 4K HDR10
failure and Snowden's 610 s stress scene have since measured zero loss
in normal viewer mode on hardware. The simulator has no display modes
at all: `system match off` there, and criteria are a no-op.

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player,
showing the negotiated method/container/codecs/range/bitrate plus live
engine state, refreshed every 2 s. It ships in **all** builds,
TestFlight included, because real Apple TV hardware only ever runs
Release. It defaults off (`debug.playbackHUD`, read once at playback
start).

Two live diagnostic lines were added to that HUD — renderer queue
depths plus stall count, and AVFoundation's total/dropped/corrupted
frame counters — along with the `PlaybackPerformance` signposts that
carry the same information off-device: controller startup, playback
cushion readiness, stalls, dismissal-critical main-actor work, renderer
teardown, demux close, the stopped-report request, and every increase
in the dropped/corrupted-frame counters. Frame-loss events include the
delta, playback position, queue depths and stall count, so a hardware
trace can distinguish decoder pressure from starvation without a screen
recording. Capture them with the Instruments **Points of Interest**
template on real Apple TV hardware; the signposts intentionally ship in
Release/TestFlight.

The HUD is itself a SwiftUI layer composited over video. On Snowden's
full-raster 4K stress scene, two otherwise clean hardware windows
measured 4–5 presentation drops with the HUD on and zero in two HUD-off
repeats. Use its live values for diagnosis, but use console/signpost
output with `debug.playbackHUD=false` for the final viewer-mode
frame-loss verdict.

**Frame droppability is opt-in metadata** (the end of the 4e2ad5f
saga): CMSampleBuffer.h says, "A frame is considered droppable if and
only if kCMSampleAttachmentKey_IsDependedOnByOthers is present and set
to kCFBooleanFalse." Absent means not droppable. Marking disposable
frames `false` licenses the renderer's *pre-decode* dropper for every
non-reference frame — 67% of the stream on the title that measured
10.7% steady loss at a matched display rate with full queues. The
engine therefore volunteers nothing by default: `IsDependedOnByOthers`
is true on reference frames only, and absent otherwise. The old marking
sits behind `debug.markDroppableFrames` for the hardware A/B. Never
trust a simulator A/B of this: the pre-decode dropper does not engage
at 60 Hz with software decode.
