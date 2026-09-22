# Contributing to Lagoon

Lagoon is one multiplatform SwiftUI app target for tvOS 26 and iOS 26, plus a
Top Shelf extension, test targets, and a single local Swift package that pins
the native media libraries.

The licence is **MPL-2.0** for Lagoon's own code, in [LICENSE](LICENSE), with
the Lagoon name and brand assets carved out of the grant by
[TRADEMARKS.md](TRADEMARKS.md). Contributions are made under those terms.
Bugs go through the issue form; anything with security or privacy impact
follows [SECURITY.md](SECURITY.md) instead of an issue. Everyone taking part
keeps to the [Code of Conduct](CODE_OF_CONDUCT.md), which is reported to
support@helop.dev.

## Prerequisites

macOS 26 and Xcode 26.6 (17F113) or newer, with an Apple TV 4K (3rd
generation) and an iPhone simulator. Xcode 26.6 built the vendored native
artifacts and older versions are untested. Nothing else is needed for a normal
build; rebuilding the native artifacts needs more, see [Native
artifacts](#native-artifacts).

## Clone, open, build

Clone the repository, open `Lagoon.xcodeproj`, and run the `Lagoon` scheme on
an Apple TV or iOS destination. The first build resolves
`Packages/LagoonFFmpeg`, which downloads the checksum-pinned MPVKit binary
targets and uses the vendored xcframeworks for the rest. Both destinations
must stay green:

```sh
xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' build
```

## Tests

The unit suite covers the engine's pure logic, the bundled notices, the
changelog and the shared models:

```sh
xcodebuild test -scheme Lagoon \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

UI journeys live in the `LagoonHardwareRegression` scheme. It runs against the
public demo by default and against a private library when you export
`LAGOON_REGRESSION_SERVER`, `LAGOON_REGRESSION_USER` and
`LAGOON_REGRESSION_PASS`. `xcodebuild` forwards only variables carrying the
`TEST_RUNNER_` prefix to the test runner, stripping the prefix on the way in,
so use that form:

```sh
TEST_RUNNER_LAGOON_REGRESSION_SERVER='https://example.test' \
TEST_RUNNER_LAGOON_REGRESSION_USER='Regression' \
TEST_RUNNER_LAGOON_REGRESSION_PASS='…' \
xcodebuild test -scheme LagoonHardwareRegression \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Fixture-backed tests skip explicitly when the server has no matching media.
The [regression lane reference](docs/reference/regression-lane.md) lists the
three fixture tiers, the resolver flags, and the state-reset rules; run the
lane only on a simulator kept for it, because the reset wipes stored accounts.

## Pointing the app at a server

Start with the public Jellyfin demo: address `demo.jellyfin.org/stable`, user
`demo`, empty password. It covers sign-in, browsing, detail pages and
playback. It has no 4K or HDR media and no multi-audio, subtitle or chapter
fixtures, so format work needs your own server.

## Documentation and standards

[`docs/README.md`](docs/README.md) is the index and
[`docs/standards.md`](docs/standards.md) holds the rules. Read the guide for
the area you are changing before changing it: architecture, design system,
Jellyfin API, playback, release, roadmap. Longer engineering notes live in
`docs/reference/`. Update the guide that owns a contract you change rather
than adding session history to it.

Verify UI changes visually in the simulator on the platforms they affect,
including tvOS focus paths, not just the landing state.

## Commits

Work goes straight to `main`. Subjects are conventional and lowercase
imperative — `feat: add app icon and top shelf artwork`, `fix:`, `chore:`,
`docs:` — with no scope parentheses. The house style is many small thematic
commits, usually one file each, ordered so every intermediate state builds. A
substantial `fix:` earns a body explaining the mechanism; a mechanical one
stays subject-only. Keep structural moves separate from behaviour changes.

## Dependencies

The `LagoonEngine` package is the only dependency, and that is deliberate. A
new one needs a real argument. If you add one, add its entry to
[`Acknowledgements.swift`](Lagoon/Features/Settings/Acknowledgements.swift)
and its licence text under `Lagoon/Resources/Licenses`, or
`AcknowledgementsTests` fails the unit suite. That test also checks every
binary target the engine package declares is covered by an entry.

## Native artifacts

The native media libraries are not in this repository. They belong to the
[`lagoon-engine`](https://github.com/helop-ou/lagoon-engine) package, which
carries them with it and which this app resolves at a tagged version pinned in
`Package.resolved`. Rebuild recipes, provenance and the `--verify-only` checks
all live there, beside the artifacts, and its `CONTRIBUTING.md` is the guide to
them.

Nothing here needs to be built to build the app: resolving the package fetches
what it needs. Changing a native library means a change in that repository and
a new version tagged there, then moving the pin here — not editing anything
under this checkout.

`docs/reference/native-dependency-inventory.json` and
`scripts/inventory-native-dependencies.py` are the exception that has not been
sorted out yet: the script still expects the libraries to be in this
repository, so it cannot run as written. Where the inventory should live is an
open question tracked on HEL-195.

## Signing and assets

Simulator builds need no signing setup. `project.pbxproj` hardcodes the
maintainer's development team with automatic signing, bundle identifiers
`ee.helop.lagoon`, `.topshelf`, `.tests` and `.uitests`, and the app group
`group.ee.helop.lagoon`. To build on a device, change the team, the bundle
identifiers and the app group to your own, and keep those local changes out of
what you submit.

The brand asset sources in `art/` are gitignored and not published. The PNG
and PDF assets tracked in the repository are Lagoon's branding. They sit
outside the source licence, and [TRADEMARKS.md](TRADEMARKS.md) describes what
that means for a fork.
