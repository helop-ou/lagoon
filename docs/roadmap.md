# Roadmap

## MVP (done)

- Connect to a Jellyfin server (schemeless input, https/http/:8096 probing)
- Sign in with password or Quick Connect; keychain-persisted session
- Home: hero carousel with ambient glow, Continue Watching, Next Up,
  Recently Added per library
- Dynamic library tabs (Movies / Shows), paged 6-column poster grids
- Movie/episode and series detail pages (seasons, episode rail)
- Playback: direct play or server-decided HLS transcode, resume, and progress
  reporting round-trip (originally AVPlayer; now superseded by the single
  Lagoon sample-buffer engine documented below)
- Debounced search, settings (sign out / change server)
- Seerr/Jellyseerr discovery, per-user Quick Connect, title and season
  requests, request history, and permission-gated moderation
- iOS builds from the same target with scaled-down metrics

## Next

- **Subtitle & audio track selection** — the device profile already requests
  vtt; surface `MediaStreams` in a picker and pass `SubtitleStreamIndex` /
  `AudioStreamIndex` through PlaybackInfo.
- **Top Shelf extension** — Continue Watching in the tvOS top shelf
  (TVServices; a reference implementation exists).
- **User switching / multiple servers** — the keychain layout already keys by
  account string; needs a profile picker at the root.
- **Trickplay scrubbing thumbnails** (`Trickplay` images, 10.9+).
- **Chapter markers** in the transport UI (`Chapters` field →
  `AVNavigationMarkersGroup`).
- **iOS polish pass** — the screens work but were designed 10-foot-first;
  compact-width layouts deserve their own detail composition.
- **Mark played/unplayed & favorites** — `UserPlayedItems` / `UserFavoriteItems`
  endpoints, long-press context menus on cards.
- **Live TV** if the server has it (guide, channels — big lift).
- **Unified custom player — sample-buffer engine for everything** (HEL-48) —
  decided 2026-08-16 and made total the same day: the Lagoon engine
  (libavformat demux → codec-specific decode stages → the AVSampleBuffer*
  presentation APIs) is the app's **only** player; the AVPlayer and mpv
  (HEL-45) paths were removed rather than maintained in parallel. M2 Atmos,
  M3 HDR/DoVi color tagging, M4 DTS/TrueHD decode, M5 subtitles, and M6
  hardening + dependency slimming are delivered; MPVKit is kept only as the
  source of the pinned FFmpeg xcframeworks.

## Deliberate non-goals for now

- Offline downloads. HEL-86's bounded playback range cache is transient,
  discardable on player exit, and deliberately cannot become saved media.
