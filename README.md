# Lagoon

A native Jellyfin client for Apple TV (and iPhone/iPad), with the goal of being as simple to
use as possible and following Apple's SwiftUI guidelines.

## Features

- Connect by address (schemeless input works — Lagoon probes https/http and
  Jellyfin's default `:8096`), sign in with password or **Quick Connect**
- Featured banners on Home and Discover: swipe between titles on iPhone/iPad,
  or use Left/Right on Apple TV
- Native home rows, so Home wouldn't feel empty without Home Screen Sections plugin
- Unified Library with Movies/Shows, sorting, library/genre/decade/watch-state
  filters, a 4K movie filter, and selections remembered per account
- Movie and series detail pages - seasons, episode rail, resume points
- Native playback: direct play when the file allows it, server-side HLS
  transcode when it doesn't
- Search your Jellyfin library and Seerr, with recent searches, See All, and
  paginated full results
- Multiple accounts and servers with keychain-persisted sessions
- tvOS 26 Liquid Glass design, dark-locked on both platforms
- Jellyfin Syncplay support
- Subtitle fetching from your server
- Offline playback (via Downloads)

## Building

Open `Lagoon.xcodeproj` in Xcode 26 and run the `Lagoon` scheme on an Apple TV
or iOS destination, or:

```sh
xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' build
```

The app is one multiplatform target with tvOS/iOS 26.0 deployment targets,
plus tvOS Top Shelf and test targets. The
[`LagoonEngine`](https://github.com/helop-ou/lagoon-engine) package is the
single dependency, resolved at a tagged version and carrying the FFmpeg
libraries the custom sample-buffer player decodes with.

To try it without a home server, connect to the public Jellyfin demo:
`demo.jellyfin.org/stable`, user `demo`, empty password.

## Licence

Lagoon's own code is under the **Mozilla Public License 2.0**
([LICENSE](LICENSE)). Fork it, change it, ship it, publish your changes to the
files it covers, and say where they came from.

The Lagoon name and brand artwork are not part of that grant. Give a fork its
own name and icon - [TRADEMARKS.md](TRADEMARKS.md) explains what is carved out
and why.

### Third-party notices

The native libraries Lagoon links carry their own licences. The bundled texts
are in [`Lagoon/Resources/Licenses`](Lagoon/Resources/Licenses), and the app
shows the same list under Settings → About → Acknowledgements with the version
and source each binary was built from. The artifacts themselves belong to the
[`LagoonEngine`](https://github.com/helop-ou/lagoon-engine) package, which
keeps each one's provenance and rebuild instructions beside it.

## Documentation

Start with the [documentation index](docs/README.md) and [coding
standards](docs/standards.md). The current guides cover architecture, design,
Jellyfin API, playback, release, and roadmap, with detailed engineering notes
and dated validation evidence linked separately.

[Contributing](CONTRIBUTING.md) has the prerequisites, build and test
commands, and repository conventions; [security reports](SECURITY.md) go
privately by email rather than into an issue. Taking part here means keeping
to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Compatibility

Uses Jellyfin's user-scoped HTTP API, which Jellyfin 10.8 and later expose, so
Lagoon works against 10.8 through current. Jellyfin 10.11.11 and 12.0.0, 12.1 have been tested thorougly.

## AI Disclaimer

Even though this info is also in the FAQ, but just in case, AI has been used in the development and documentation process of this project.
I am a full-time SWE and I do review and test the changes made by Claude, or Codex.

## FAQ

### Why another client?

Fair question, and I understand. It is also why I am not advertising Lagoon
anywhere (also because I'm quite bad at marketing).

I built it for myself and for the people using my own Jellyfin server, who
kept telling me there was nothing that just worked unless they paid for
Infuse. The second reason is the engine: the sample-buffer player underneath
Lagoon took most of the effort here, and I would rather it existed as
something others can build on than not exist at all.

### Was AI used in this project?

Yes. I review and test everything it writes, and every change goes through me
and through an internal TestFlight build before it reaches anyone else. I am a
full-time senior SWE and my time outside work is limited and without AI this project
would've taken me quite a while longer to get it ready for a release.

### How is this better than other clients?

For a specific need you already have covered, probably it is not. Lagoon aims
to be simple enough that you can point a non-techy friend at it, have them
sign in, and have it play, ideally without the server re-encoding anything.

There are genuinely some very good clients out there and I won't be here,
trying to advertise that my client is better than the other ones.

### What formats are supported?

[**Codec support**](docs/codec-support.md) has the full table: containers,
video and audio codecs, subtitle formats, and the conditions attached to each.

It is generated from the capability profile the app sends the server, so it is
accurate by construction rather than by me remembering to update it.

### Does it work offline?

On iPhone and iPad, yes. Films and episodes can be downloaded and played back.
Whether your account may download is decided by your Jellyfin
server, not by Lagoon.

### Does it work with Jellyseerr?

Yes, optionally. Connect it and requests and discovery appear alongside your
library. Without it, Lagoon works exactly as before.

### Why target tvOS and iOS 26?

Because most iOS devices are kept up to date and since I made the project mostly for me,
I don't know anyone who uses OS versions older than those.

This is not set in stone.
