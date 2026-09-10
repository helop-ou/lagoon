# Lagoon

A native Jellyfin client for Apple TV (and iPhone/iPad), in the spirit of
Infuse: sign in to your server and your library becomes a fast, focused,
10-foot experience — hero spotlight with artwork-tinted ambient glow,
Continue Watching and Next Up rails, poster grids, and a unified native
sample-buffer player with resume and progress sync.

## Features

- Connect by address (schemeless input works — Lagoon probes https/http and
  Jellyfin's default `:8096`), sign in with password or **Quick Connect**
- Featured banners on Home and Discover: swipe between titles on iPhone/iPad,
  or use Left/Right on Apple TV; tap or select to open the visible title
- Home with Continue Watching, unstarted episodes in Next Up, and Recently
  Added rails that group new episodes under their shows
- Unified Library with Movies/Shows, sorting, library/genre/decade/watch-state filters,
  a 4K movie filter, and selections remembered per account
- Movie and series detail pages — seasons, episode rail, resume points
- Native playback: direct play when the file allows it, server-side HLS
  transcode when it doesn't; watch progress syncs back to the server
- Search your Jellyfin library and Seerr, with recent searches, See All, and
  paginated full results
- Larger iOS posters, roomier rows, adaptive detail actions, and centered
  touch-player controls with a native playback-options sheet
- Settings organised into separate categories on iOS and tvOS
- Multiple accounts and servers with keychain-persisted sessions; Add Account
  starts on the current server, with Use Another Server available when needed
- tvOS 26 Liquid Glass design, dark-locked on both platforms

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

Start with the [documentation index](docs/README.md) and
[coding standards](docs/standards.md). The current guides cover architecture,
design, Jellyfin API, playback, release, and roadmap, with detailed engineering
notes and dated validation evidence linked separately.

## Compatibility

Uses Jellyfin's user-scoped HTTP API, which Jellyfin 10.8 and later expose, so
Lagoon works against 10.8 through current. What has actually been contacted is
narrower than that range: the public **10.11.11** stable demo and the public
**12.0.0** unstable demo. The 12.0 compatibility work is tracked in
[HEL-138](https://helop-ou.atlassian.net/browse/HEL-138) and is not finished —
see [Jellyfin API](docs/jellyfin-api.md) for what has and has not been checked.
