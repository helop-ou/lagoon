# Roadmap

## MVP (done)

- Connect to a Jellyfin server (schemeless input, https/http/:8096 probing)
- Sign in with password or Quick Connect; keychain-persisted session
- Home: hero carousel with ambient glow, Continue Watching, Next Up,
  Recently Added per library
- Dynamic library tabs (Movies / Shows), paged 6-column poster grids
- Movie/episode and series detail pages (seasons, episode rail)
- Native AVPlayer playback: direct play or server-decided HLS transcode,
  resume, progress reporting round-trip
- Debounced search, settings (sign out / change server)
- iOS builds from the same target with scaled-down metrics

## Next

- **Subtitle & audio track selection** — the device profile already requests
  vtt; surface `MediaStreams` in a picker and pass `SubtitleStreamIndex` /
  `AudioStreamIndex` through PlaybackInfo.
- **Jellyseerr/Overseerr integration** — request missing titles from search
  ("not in your library — request it?"), needs its own API client + auth.
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

## Deliberate non-goals for now

- Custom software video player (VLCKit-style) for formats the server can't
  transcode — the server-side transcode path covers the long tail.
- Offline downloads.
