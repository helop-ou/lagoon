# Watch Together (SyncPlay)

Engineering detail behind the [playback guide](../../playback.md#watch-together-syncplay).
The guide states the contract; this is how it is met and what went wrong on
the way.

**Opening.** A `PlayQueue` update whose playing item changed resolves to a
`MediaItem` and reaches `MainTabView` as `pendingPlayRequest`, which presents
the player with `startPosition` and `startPaused: true`. The member therefore
primes at the group's position and waits there. `SyncPlay/Buffering` goes out
the moment the queue update lands, before the item is even fetched. That way
the group waits from then, not from whenever this device finishes negotiating
a stream. `SyncPlay/Ready` goes out when `onEngineReady` fires. Both messages
carry `When` from `ServerClock`, `PositionTicks` from `clockPosition`, and the
queue entry's `PlaylistItemId`. A Ready naming the wrong entry makes the
server answer with a `SetCurrentItem` queue update. Readiness is a *state*:
the driver reports only on a change, so the pair a seek produces collapses to
one Buffering and one Ready.

**A report says where the engine is, not where it was.** `clockPosition`
answers from the synchronizer, and the synchronizer sits at the anchor being
left behind until `beginPlayback` sets the new one. That anchor is zero on a
first open. `beginPlayback` anchors the clock *before* it announces the end of
buffering, and leaves `bufferingTargetSeconds` in place until it does, so the
whole window has one answer. A Ready that is more than half a second from the
group's position is not ignored: the server flags that member as buffering
again and sends it a corrective `Seek` ("got lost in time, correcting"). A
report that lies stalls the room it was meant to release.

**Commands.** `Unpause` seeks first, only if the member is more than 0.5 s
from the named position, then calls `playGroup(atHostTime:)` straight away.
The engine remembers the instant through priming, and a seek issued *after*
the start call would drop it, so that order is load-bearing. `Pause` waits
until the named instant arrives on the local clock, then pauses, and re-seeks
only if more than 0.1 s out, because a seek re-primes the pipeline. `Seek`
seeks and reports Buffering, then Ready. `Stop` closes the player and keeps
the membership.

`SyncPlayGroupSession` decides what is worth acting on at all. It refuses
another group's command, one emitted before this member joined, one naming an
item that is not the current one (`Stop` excepted), the all-zero `Stop` a new
group is greeted with, and a re-send of the command already taken. A `Seek` is
excepted from that last refusal too: the server builds its corrective seek out
of the group's own state, so it arrives identical to the seek already taken,
apart from `EmittedAt`. Refusing it would leave the member with nothing left
to report and the group waiting on it forever.

**Drift.** While the last command is an `Unpause`, 1.5 s past its instant and
not buffering, the driver compares `clockPosition` against where the group
should be and applies `SyncCorrectionPolicy`: under 60 ms nothing, up to 1.5 s
a rate nudge of `1 + diff / 1.5` clamped to 0.75…1.5 held for 1.5 s, beyond
that a seek. The nudge rides `setCorrectionRate`, never the viewer's `rate`.
`syncplay.correction` (default on) turns correction off while still measuring.
`driftMilliseconds` feeds the HUD's `Sync:` line.

**The viewer's transport is a request.** Play, pause, seek, the double-tap
skips, the scrub commit, the intro skip, "play next" and the lock screen all
go through `PlaybackController`'s `user…` methods, which hand them to
`groupTransport` instead of the engine when a group owns the session. Nothing
moves locally. The server's echo moves every member together. The player
chrome states the intention through `PlayerTransportActions`, and `NowPlaying`
states it through the same struct, so there is one interception point rather
than one per control. Audio track, subtitles, audio delay and playback speed
stay local: they are this viewer's, not the group's.

**Leaving the player is not leaving the group.** `onClosed` detaches the
driver and posts `SetIgnoreWait(true)`, so the group is no longer held up by a
member that is not watching. `rejoinPlayback()` clears that flag and reopens
from the stored queue, at wherever the group has got to.
`positionSeconds(atServerSeconds:)` carries the last `Unpause` forward by the
server time elapsed since its instant. Opening at the position that command
named would be minutes behind a group that has been watching, and the server
would hold everyone up correcting it. `leave()` posts `SyncPlay/Leave` and
closes the socket and clock. An account switch does the same silently.
Foreground forces a clock re-sample.

**What the viewer sees.** A *Watch Together* control in a detail page's
secondary row, icon `person.2.fill` and never SharePlay's glyph. It is drawn
only once `SyncPlayStore.availability` says the account may join, and the
detail page asks — the control renders nothing until the answer arrives, and a
task on a view that renders nothing never runs.

It opens `WatchTogetherSheet`: a sheet on iOS, a `TVSettingsPage` in a sheet
on tvOS. That lists the server's groups, polled every 5 s since the socket
only carries the group this client is in, offers *Start a Group*
(`CreateAndJoinGroups`), and once joined shows the room, its people, *Play
This Here* and *Leave*. Group names are visible to every account on the
server, and the copy says so. `startGroup` is two calls: `SyncPlay/New`
answers 204 and the id arrives over the socket, so the queue can only be set
after `GroupJoined`.

While a group owns the session, the player's panel grows a fifth **Together**
tab: the room, its state, the people in it, an *Ignore Waiting* switch and
*Leave*. Everywhere the tabs are walked, the strip and the tvOS left/right
grammar, reads `PlayerPanelTab.offered(inGroup:)` rather than `allCases`.
Otherwise an arrow press lands on a tab that is not drawn. A group that ends
moves the selection back to Info. The group reaches `CustomPlayerView` as a
`PlayerTogetherState` value, never as the store, and joins
`PlayerControlPanelHost`'s `Equatable` boundary so an arrival still reaches
the tab.

Notices are a toast at the top of the screen: `SyncPlayNoticeToast`. It is an
overlay leaf in `PlayerSkipOverlay`'s shape, so the player root never
subscribes to one. It shows for two seconds, respects Reduce Motion, and is
never hit-tested. A state the picture already reports ("Playing", "Nothing
playing") gets no toast, and neither does "Waiting," which the transport says
for as long as it is true.

**Waiting is not buffering.** A member primed and paused at the group's
position is not stalled. The existing spinner carries the label *Waiting for
the group* underneath it. `SyncPlayStore.isWaitingForGroup` drives that label,
positioned clear of the touch grammar's centre play button. Waiting keeps that
button on screen, and the two elements would otherwise share the middle of the
frame.

Settings › Playback owns `syncplay.correction` as *Correct Sync Drift*. Home
carries a banner above its rails, with the group name, *Rejoin* and *Leave*,
while a group has this device as a member and nothing of its is on screen.

**The socket must be open before the join.** The server announces a join over
the socket at the instant it happens. Joining while the handshake is still
in flight loses both the `GroupJoined` and the `PlayQueue` update on
the fixture server running Jellyfin 12.0.0, and the member then sits in a
group it never hears another word from. The store waits for the socket to
carry its first message, the server's own `ForceKeepAlive`, before asking to
join. A handshake timeout or failed membership request keeps the sheet open
with an error and a retry path.

The store snapshots its account's client, so queued requests and the final
Leave never adopt a replacement account's credentials. Leaving cancels queued
commands and item loads, and late results must match the active membership
before they can present or restart playback. A delivery fallback in a group
primes paused and reports Ready before the server starts it again. Readiness
reports retry once after a second, with the current timestamp and position,
and cancellation or newer readiness supersedes that retry. Viewer transport
commands are never retried automatically. Ignore Waiting changes publish after
server acknowledgement. An unavailable queued title attempts to opt out of
waiting and offers Rejoin or Leave instead of failing silently.

**Verifying it** takes two members. `-debug.syncPlayJoinGroup <name>` joins
the named group after the regression bootstrap signs in, polling for up to 30
s so the other member can create it. The group's queue then drives playback in
place of the bench fixture. Pair it with `-debug.playbackHUD YES` and read the
`Sync:` line: group state, member count, last command, drift.
