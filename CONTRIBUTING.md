# Contributing to Lagoon

Lagoon is one multiplatform SwiftUI app target for tvOS 26 and iOS 26, plus a
Top Shelf extension and test targets. Its only dependency is the
`LagoonEngine` package, which carries the native media libraries.

- Lagoon's own code is **MPL-2.0** ([LICENSE](LICENSE)), with the name and
  brand assets carved out by [TRADEMARKS.md](TRADEMARKS.md). Contributions are
  made under those terms.
- Bugs go through the issue form. Anything with security or privacy impact
  follows [SECURITY.md](SECURITY.md) instead.
- Everyone keeps to the [Code of Conduct](CODE_OF_CONDUCT.md); report
  breaches to support@helop.dev.

## Prerequisites

macOS 26 and Xcode 26.6 (17F113) or newer, with an Apple TV 4K (3rd
generation) and an iPhone simulator. Older Xcode versions are untested.
Nothing else is needed; rebuilding native libraries is covered under [Native
artifacts](#native-artifacts).

## Clone, open, build

Open `Lagoon.xcodeproj` and run the `Lagoon` scheme on an Apple TV or iOS
destination. The first build resolves `LagoonEngine` at the version pinned in
`Package.resolved`. Both destinations must stay green:

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

UI journeys live in the `LagoonHardwareRegression` scheme. They run against
the public demo by default, or a private library via
`LAGOON_REGRESSION_SERVER`, `LAGOON_REGRESSION_USER` and
`LAGOON_REGRESSION_PASS`. `xcodebuild` forwards only `TEST_RUNNER_`-prefixed
variables (and strips the prefix), so use that form:

```sh
TEST_RUNNER_LAGOON_REGRESSION_SERVER='https://example.test' \
TEST_RUNNER_LAGOON_REGRESSION_USER='Regression' \
TEST_RUNNER_LAGOON_REGRESSION_PASS='…' \
xcodebuild test -scheme LagoonHardwareRegression \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Fixture-backed tests skip when the server has no matching media. The
[regression lane reference](docs/reference/regression-lane.md) lists the
fixture tiers, resolver flags and state-reset rules. Run the lane only on a
simulator kept for it: the reset wipes stored accounts.

## Pointing the app at a server

Use the public Jellyfin demo: `demo.jellyfin.org/stable`, user `demo`, empty
password. It covers sign-in, browsing, detail pages and playback, but has no
4K, HDR, multi-audio, subtitle or chapter fixtures, so format work needs your
own server.

## Documentation and standards

[`docs/README.md`](docs/README.md) is the index and
[`docs/standards.md`](docs/standards.md) holds the rules. Read the guide for
the area you are changing first. Update the guide that owns a contract you
change; do not add session history to it.

Verify UI changes in the simulator on each affected platform, including tvOS
focus paths, not just the landing state.

## Commits

- Work goes straight to `main`.
- Subjects are conventional, lowercase imperative, with no scope:
  `feat: add app icon and top shelf artwork`, `fix:`, `chore:`, `docs:`.
- Many small thematic commits, usually one file each, ordered so every
  intermediate state builds.
- A substantial `fix:` gets a body explaining the mechanism; a mechanical one
  is subject-only.
- Keep structural moves separate from behaviour changes.

## Dependencies

`LagoonEngine` is deliberately the only dependency; a new one needs a real
argument. If you add one, add its entry to
[`Acknowledgements.swift`](Lagoon/Features/Settings/Acknowledgements.swift)
and its licence text under `Lagoon/Resources/Licenses`, or
`AcknowledgementsTests` fails. The test also checks that every binary target
the engine declares has an entry.

## Native artifacts

The native media libraries live in the
[`lagoon-engine`](https://github.com/helop-ou/lagoon-engine) package, with
their rebuild recipes, provenance and `--verify-only` checks; its
`CONTRIBUTING.md` is the guide. Resolving the package fetches everything the
app needs.

To change a native library, change it there, tag a new engine version, then
move the pin here. After the pin moves, regenerate
`docs/reference/native-dependency-inventory.json` with
`scripts/inventory-native-dependencies.py`, pointed at the resolved engine
checkout (see the script's header).

## Signing and assets

Simulator builds need no signing setup. `project.pbxproj` hardcodes the
maintainer's team with automatic signing, bundle identifiers
`ee.helop.lagoon`, `.topshelf`, `.tests` and `.uitests`, and the app group
`group.ee.helop.lagoon`. To build on a device, change the team, bundle
identifiers and app group to your own, and keep those changes out of what you
submit.

Brand asset sources in `art/` are gitignored. The tracked PNG and PDF assets
are Lagoon's branding and sit outside the source licence; see
[TRADEMARKS.md](TRADEMARKS.md).
