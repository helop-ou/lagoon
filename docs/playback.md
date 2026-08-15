# Playback

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.native` — a
   capability profile describing what AVPlayer handles natively: direct play
   for mp4/m4v/mov with HEVC/H.264 + AAC/AC3/EAC3/FLAC/ALAC audio, and an
   HLS (ts, h264/hevc + aac/ac3) transcoding profile for everything else
   (MKV, unsupported codecs). The server does the deciding.
2. Pick the first `MediaSource` and resolve a URL via
   `JellyfinClient.streamURL`:
   - `SupportsDirectPlay` → `Videos/{id}/stream?static=true&mediaSourceId=…`
     (+ `api_key`, `deviceId`, `Tag`), PlayMethod `DirectPlay`.
   - else the server-provided `TranscodingUrl` (arrives server-relative with
     its own query string — resolve against the server URL, don't rebuild
     it), PlayMethod `Transcode`.
3. AVPlayer plays it; Jellyfin's HLS playlists cover the full duration, so
   **resume is a client-side seek** rather than a `StartTimeTicks` offset —
   this keeps position reporting absolute in both play methods.

## Progress reporting

Positions are ticks (see jellyfin-api.md). Three report points, all fire-and-
forget (`try?` — reporting must never interrupt playback):

- `Sessions/Playing` once playback starts.
- `Sessions/Playing/Progress` every 10 s from a detached loop, including
  `IsPaused` derived from `timeControlStatus`.
- `Sessions/Playing/Stopped` exactly once from `stop()` (guarded by
  `didReportStop`), called on dismiss. This is what moves the server-side
  resume point and reorders Continue Watching.

Detail screens re-fetch the item in `fullScreenCover`'s `onDismiss`, and
HomeView re-fetches its Resume/Next Up rails in `onAppear`, so the UI reflects
the new position immediately.

## Player view gotchas (all learned the hard way on tvOS)

- `externalMetadata` (title, subtitle, description, artwork) must be **fully
  built before playback starts** — mutating it while the player is active
  corrupts the info panel layout. Artwork is fetched through `ImageCache`
  and attached as JPEG data with `extendedLanguageTag = "und"`.
- On failure the player is set to **nil** and replaced with a custom error
  overlay carrying a Back button and `.onExitCommand` — a dead player
  swallows the Menu press and traps the user.
- `AVPlayerItem.didPlayToEndTimeNotification` dismisses the cover so a
  finished movie doesn't strand the viewer on a black screen.
- The loading state is `LoadingView` (focusable) for the same Menu-button
  reason as everywhere else.
