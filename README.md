# Lagoon

A native Jellyfin client for Apple TV (and iPhone/iPad), in the spirit of
Infuse: sign in to your server and your library becomes a fast, focused,
10-foot experience — hero spotlight with artwork-tinted ambient glow,
Continue Watching and Next Up rails, poster grids, and a unified native
sample-buffer player with resume and progress sync.

## Features

- Connect by address (schemeless input works — Lagoon probes https/http and
  Jellyfin's default `:8096`), sign in with password or **Quick Connect**
- Home with a self-advancing hero carousel, Continue Watching, Next Up, and
  Recently Added rails per library
- Dynamic tabs per movie/show library with paged poster grids
- Movie and series detail pages — seasons, episode rail, resume points
- Native playback: direct play when the file allows it, server-side HLS
  transcode when it doesn't; watch progress syncs back to the server
- Library-wide search
- Session persists in the keychain; tvOS 26 Liquid Glass design, dark-locked

## Building

Open `Lagoon.xcodeproj` in Xcode 26 and run the `Lagoon` scheme on an
Apple TV or iOS destination, or:

```sh
xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' build
```

The app is one multiplatform target with tvOS/iOS 26.0 deployment targets,
plus tvOS Top Shelf and test targets. `Packages/LagoonFFmpeg` is the single
local package dependency and pins the FFmpeg libraries used by the custom
sample-buffer player.

To try it without a home server, connect to the public Jellyfin demo:
`demo.jellyfin.org/stable`, user `demo`, empty password.

## Documentation

Technical docs live in [`docs/`](docs/):

- [Architecture](docs/architecture.md) — layout, session lifecycle, navigation, tvOS invariants
- [Jellyfin API](docs/jellyfin-api.md) — endpoints, auth, wire-format quirks, image fallbacks
- [Playback](docs/playback.md) — device profile, stream resolution, progress reporting
- [Design system](docs/design-system.md) — tokens, focus strategy, components, image cache
- [Roadmap](docs/roadmap.md) — what the MVP covers and what's next

## Compatibility

Speaks the user-scoped legacy API routes — works against Jellyfin 10.8
through current (verified against 10.11).
