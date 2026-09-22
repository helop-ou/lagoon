# Watch Together (SyncPlay)

How the contract in the [playback
guide](../../playback.md#watch-together-syncplay) is met. Server behavior
measured on Jellyfin 12.0.0 is in [system
integration](system-integration.md#watch-together-the-group-as-a-transport-authority).

## Opening

- A `PlayQueue` update whose playing item changed resolves to a `MediaItem`
  and reaches `MainTabView` as `pendingPlayRequest`, which presents the player
  with `startPosition` and `startPaused: true`. The member primes at the
  group's position and waits.
- `SyncPlay/Buffering` goes out as soon as the queue update lands, before the
  item is fetched, so the group waits from then.
- `SyncPlay/Ready` goes out when `onEngineReady` fires.
- Both carry `When` from `ServerClock`, `PositionTicks` from `clockPosition`,
  and the queue entry's `PlaylistItemId`. A Ready naming the wrong entry gets
  a `SetCurrentItem` queue update back.
- Readiness is a _state_: the driver reports only changes, so a seek's pair
  collapses to one Buffering and one Ready.

**A report says where the engine is.** `clockPosition` reads the
synchronizer, which sits at the old anchor (zero on a first open) until
`beginPlayback` sets the new one. So `beginPlayback` anchors the clock
_before_ announcing the end of buffering, and keeps `bufferingTargetSeconds`
until then, so the whole window gives one answer. A Ready more than 0.5 s off
earns a corrective `Seek` and holds the room.

## Commands

- `Unpause`: seek first, only if more than 0.5 s from the named position, then
  call `playGroup(atHostTime:)` at once. The engine remembers the instant
  through priming, and a seek _after_ the start call would drop it, so the
  order matters.
- `Pause`: wait for the named instant on the local clock, pause, and re-seek
  only if more than 0.1 s out (a seek re-primes the pipeline).
- `Seek`: seek, report Buffering, then Ready.
- `Stop`: close the player and keep the membership.

`SyncPlayGroupSession` refuses:

- another group's command
- one emitted before this member joined
- one naming an item that is not current (`Stop` excepted)
- the all-zero `Stop` a new group receives
- a re-send of the command already taken, **except `Seek`**: the server's
  corrective seek is built from the group's state and arrives identical apart
  from `EmittedAt`. Refusing it leaves the group waiting forever.

## Drift

While the last command is an `Unpause`, 1.5 s past its instant and not
buffering, the driver compares `clockPosition` with where the group should be
and applies `SyncCorrectionPolicy`:

- under 60 ms: nothing
- up to 1.5 s: a rate nudge of `1 + diff / 1.5`, clamped to 0.75…1.5, held
  for 1.5 s, through `setCorrectionRate` (never the viewer's `rate`)
- beyond: a seek

`syncplay.correction` (default on, Settings › Playback › *Correct Sync
Drift*) turns correction off but keeps measuring. `driftMilliseconds` feeds
the HUD's `Sync:` line.

## Transport and leaving

**The viewer's transport is a request.** Play, pause, seek, double-tap skips,
scrub commit, intro skip, "play next" and the lock screen go through
`PlaybackController`'s `user…` methods, which send them to `groupTransport`
instead of the engine when a group owns the session. The player chrome and
`NowPlaying` both express intent through `PlayerTransportActions`, so there is
one interception point. Audio track, subtitles, audio delay and speed stay
local.

**Leaving the player is not leaving the group.**

- `onClosed` detaches the driver and posts `SetIgnoreWait(true)`, so the group
  is not held up.
- `rejoinPlayback()` clears that flag and reopens from the stored queue where
  the group is now: `positionSeconds(atServerSeconds:)` carries the last
  `Unpause` forward by the server time elapsed. Opening at that command's
  position would be minutes behind and stall everyone.
- `leave()` posts `SyncPlay/Leave` and closes socket and clock. An account
  switch does the same silently. Foreground forces a clock re-sample.

## What the viewer sees

- **Entry point:** a *Watch Together* control in the detail page's secondary
  row, icon `person.2.fill` (never SharePlay's glyph). It draws only once
  `SyncPlayStore.availability` allows joining; the detail page asks, since a
  view that renders nothing never runs its task.
- **`WatchTogetherSheet`** (a sheet on iOS, a `TVSettingsPage` in a sheet on
  tvOS) lists the server's groups, polled every 5 s since the socket only
  carries this client's group. It offers *Start a Group*
  (`CreateAndJoinGroups`), and once joined shows the room, its people, *Play
  This Here* and *Leave*. Group names are visible to every account on the
  server, and the copy says so. `startGroup` sets the queue only after
  `GroupJoined`, because `SyncPlay/New` returns no id.
- **Together tab:** while a group owns the session, the player panel gains a
  fifth tab with the room, state, people, *Ignore Waiting* and *Leave*.
  Everything that walks tabs (the strip, tvOS left/right) reads
  `PlayerPanelTab.offered(inGroup:)`, not `allCases`, or an arrow lands on an
  undrawn tab. When the group ends the selection returns to Info. The group
  reaches `CustomPlayerView` as a `PlayerTogetherState` value, never the
  store, and joins `PlayerControlPanelHost`'s `Equatable` boundary.
- **Notices:** `SyncPlayNoticeToast`, an overlay leaf shaped like
  `PlayerSkipOverlay` so the player root never subscribes. Two seconds,
  respects Reduce Motion, never hit-tested. No toast for states the picture
  already shows ("Playing", "Nothing playing", "Waiting").
- **Waiting is not buffering.** A member primed and paused at the group's
  position shows the spinner labelled *Waiting for the group*, driven by
  `SyncPlayStore.isWaitingForGroup`, placed clear of the touch centre play
  button (which stays on screen while waiting).
- **Home banner** with the group name, *Rejoin* and *Leave*, while this device
  is a member and nothing of the group is on screen.

## Robustness

- The socket must carry its first message (`ForceKeepAlive`) before the join
  is sent. A handshake timeout or failed membership request keeps the sheet
  open with an error and retry.
- The store snapshots its account's client, so queued requests and the final
  Leave never use a replacement account's credentials.
- Leaving cancels queued commands and item loads. Late results must match the
  active membership before they present or restart playback.
- A delivery fallback in a group primes paused and reports Ready before the
  server restarts it.
- Readiness reports retry once after a second, with current timestamp and
  position; cancellation or newer readiness supersedes the retry. Viewer
  transport commands are never retried automatically.
- Ignore Waiting changes publish after server acknowledgement.
- An unavailable queued title tries to opt out of waiting and offers Rejoin or
  Leave instead of failing silently.

## Verifying

It takes two members. `-debug.syncPlayJoinGroup <name>` joins the named group
after the regression bootstrap signs in, polling up to 30 s so the other
member can create it; the group's queue then drives playback instead of the
bench fixture. Add `-debug.playbackHUD YES` and read the `Sync:` line: group
state, member count, last command, drift.
