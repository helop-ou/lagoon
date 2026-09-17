# Contributing to Lagoon

Lagoon is one multiplatform SwiftUI app target for tvOS 26 and iOS 26, plus a
Top Shelf extension, test targets, and a single local Swift package that pins
the native media libraries.

The repository has no licence file yet. That decision is still open, so ask
before redistributing the source or a build. Bugs go through the issue form;
anything with security or privacy impact follows [SECURITY.md](SECURITY.md)
instead of an issue.

## Prerequisites

macOS 26 and Xcode 26.6 (17F113) or newer, with an Apple TV 4K (3rd
generation) and an iPhone simulator. Xcode 26.6 built the vendored native
artifacts and older versions are untested. Nothing else is needed for a normal
build; rebuilding the native artifacts needs more, see
[Native artifacts](#native-artifacts).

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

`Packages/LagoonFFmpeg` is the only dependency, and that is deliberate. A new
one needs a real argument. If you add one, add its entry to
[`Acknowledgements.swift`](Lagoon/Features/Settings/Acknowledgements.swift) and
its licence text under `Lagoon/Resources/Licenses`, or `AcknowledgementsTests`
fails the unit suite. That test also checks every binary target declared in
`Packages/LagoonFFmpeg/Package.swift` is covered by an entry.

## Native artifacts

Three xcframeworks are vendored rather than fetched, and two are built here.
Each rebuild recipe sits beside its artifact, and both scripts have a
`--verify-only` mode that checks a packaged framework.

- libavformat, built without its network stack:
  [`Libavformat.README.md`](Packages/LagoonFFmpeg/Artifacts/Libavformat.README.md).
  Needs Python 3.12+ and pkg-config.
- dav1d, built with its arm64 assembly kept: see the header comment of
  [`scripts/build-dav1d.sh`](scripts/build-dav1d.sh), which needs meson and
  ninja. Always run `scripts/build-dav1d.sh --verify-only
  Packages/LagoonFFmpeg/Artifacts/Libdav1d.xcframework` after touching it:
  without the assembly it still decodes everything correctly, about ten times
  slower, and nothing fails.
- libdovi cannot be rebuilt in this repository. It is vendored prebuilt, and a
  from-source build needs a Rust toolchain and `cargo-c`. Provenance and
  per-slice hashes are in
  [`Libdovi.README.md`](Packages/LagoonFFmpeg/Artifacts/Libdovi.README.md).

Regenerate `docs/reference/native-dependency-inventory.json` with
`scripts/inventory-native-dependencies.py` when a linked artifact changes.

## Signing and assets

Simulator builds need no signing setup. `project.pbxproj` hardcodes the owner's
development team `9GLTW5844P` with automatic signing, bundle identifiers
`ee.helop.lagoon`, `.topshelf`, `.tests` and `.uitests`, and the app group
`group.ee.helop.lagoon`. To build on a device, change the team, the bundle
identifiers and the app group to your own, and keep those local changes out of
what you submit.

The brand asset sources in `art/` are gitignored and not published. The PNG and
PDF assets tracked in the repository are Lagoon's branding, not covered by
whatever source licence is eventually chosen, and not for reuse elsewhere.
