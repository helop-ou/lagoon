# Lagoon — session notes

Jellyfin client for tvOS 26 and iOS 26: one multiplatform SwiftUI app target,
with unit and multiplatform UI test targets. Playback runs on the
`LagoonEngine` package — Lagoon's own sample-buffer engine over vendored
FFmpeg, now maintained in its own repository. There is no AVPlayer path and no
third-party Swift dependency.

## Where the rules live

`AGENTS.md` is a symlink to this file, so Codex and other agents read the same
instructions. Edit CLAUDE.md, never the link.

**Start at [docs/README.md](docs/README.md), follow the [coding
standards](docs/standards.md), and read the guide for the area you are
changing before you work on it.** This file is a map and a session checklist,
not a second copy of the guides. If a line here disagrees with a guide, the
guide is right and this file needs fixing.

| Guide | Owns |
| --- | --- |
| [Coding standards](docs/standards.md) | Folder structure, Observation and `MainActor` rules, boundaries, review and verification |
| [Architecture](docs/architecture.md) | Ownership, navigation, refresh and invalidation, the tvOS focus invariants |
| [Design system](docs/design-system.md) | Tokens, brand colors, native controls, focus, image loading |
| [Jellyfin API](docs/jellyfin-api.md) | Authentication, endpoints, wire formats, decoding rules, server compatibility |
| [Playback](docs/playback.md) | Negotiation, the delivery ladder, controls, reporting, regression checks. Engine internals live with the engine. |
| [Release](docs/release.md) | Build numbers, changelog, acknowledgements, licence, TestFlight, release gates |
| [Roadmap](docs/roadmap.md) | Remaining product work and device acceptance |

`docs/reference/` holds the engineering notes and measurements behind the
guides. Keep routine session history out of the guides — see "Keeping this
clean" in docs/README.md.

## Session workflow

- Build, and keep both destinations green:

  ```
  xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build
  xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' build
  ```

- Test. `LagoonTests` pins the engine's pure logic. Keep it green, and add
  tests there when new logic is pure enough to pin down:

  ```
  xcodebuild test -scheme Lagoon -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
  ```

- Build numbers belong to the repo. Never let Xcode manage them at upload; see
  [Release](docs/release.md). A change a viewer would notice gets a line in
  `Lagoon/Features/Settings/Changelog.swift`. An invisible one does not.
- The only dependency is the `LagoonEngine` package, which carries the native
  libraries with it. Do not add another without serious deliberation. When you
  do, add its acknowledgement and licence text as [Release](docs/release.md)
  describes, or `AcknowledgementsTests` fails the unit suite.
- Verify UI changes in the simulator before calling them done. Build, then
  `simctl install/launch`, then drive focus with `osascript -e 'tell
  application "System Events" to key code …'` — 125/126/123/124 are the
  arrows, 36 select, 53 menu, and `keystroke "…"` types into the tvOS keyboard
  — then `simctl io <udid> screenshot`. Exercise focus paths and deep scrolls,
  not just the landing state.
- For end-to-end work, the public demo server supports the full flow including
  playback: `demo.jellyfin.org/stable`, user `demo`, empty password.
- Report only what was verified. Before saying a change is done, run the
  builds and the relevant tests, and say what ran. If a step was skipped or a
  check failed, say so and show the output. Never describe an unrun check as
  passed.

## Working with subagents

Use subagents where they make sense, and do the small things yourself.

Delegate a broad search across many files, independent pieces that can run in
parallel, a sweep of several guides, a set of mechanical edits with a precise
spec, or a review that benefits from fresh eyes on a diff. Give each agent a
precise spec and check what comes back. The main session plans, reviews and
verifies.

Do the work yourself when it is a single-file edit, a lookup in a file or
symbol you already know, or anything where explaining the task would take
longer than doing it. Never claim an agent's result before it has come back.

## Invariants that have regressed before

Each one is explained, with its evidence, in the guide named. This list exists
so you know to read that guide before touching the area.

- **Playback** — [Playback](docs/playback.md). All playback goes through the
  engine package behind the `PlayerEngine` protocol, and the player UI only
  talks to the protocol. Player views hold the engine through
  `@PlayerEngineRef`, never a strong reference, and closures handed to SwiftUI
  never capture an engine — that one the engine cannot enforce for us, and it
  has regressed most often. A light Siri Remote touch-surface tap and a Select
  press are different inputs and never share a path. The delivery ladder
  descends only on the engine's verdict about the samples, and a `.delivery`
  verdict is never a reason to re-encode.
- **The engine package** — its own repository, and its own
  [guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md)
  and [standards](https://github.com/helop-ou/lagoon-engine/blob/main/docs/standards.md).
  Demux, decode, render, queues, the byte-source cache and the vendored FFmpeg
  build all live there, along with the rules that keep them working. Change
  them there, not by reaching around the package.
- **Measurement** — [Playback](docs/playback.md), "Regression checks", and
  `docs/reference/playback/frame-loss-bench.md` for the harness. Never trust a
  casual frame-loss comparison. Same scene, same media-time window, simulator
  untouched, three or more runs, using the Frame-Loss Bench and
  `scripts/framedrop-bench.sh`. Two fixes that skipped this were later
  retracted.
- **Models and API** — [Jellyfin API](docs/jellyfin-api.md) and
  [Architecture](docs/architecture.md). `@Observable` with `@MainActor`
  default isolation; DTOs are `nonisolated struct`s with defensive decoding.
  Jellyfin JSON is PascalCase and the client's key strategy handles it, so
  never add `CodingKeys` for casing. Never decode `Date`. Positions are ticks.
  `MediaItem` compares by value and no DTO gets an id-only `==`, because
  SwiftUI drops a state write whose new value compares equal. API calls bypass
  the URL cache for the same reason.
- **tvOS and refresh** — [Architecture](docs/architecture.md), "tvOS
  invariants". Every screen needs a focusable element. Keep
  `.scrollClipDisabled()` and rail focus-lift padding intact, and keep the
  Refresh chrome rules. Foreground invalidation happens only from `RootView`
  advancing `ServerSyncState`, with `ServerRefreshModifier` gated to the
  visible root destination. Seerr's detail-only live refresh stays separate
  from browse invalidation.
- **Design** — [Design system](docs/design-system.md). Design tokens
  (`Metrics`/`Motion`), never literals. Brand colors only for branding, system
  semantics everywhere else. Native controls over hand-rolled focus visuals.
  Images through `CachedAsyncImage` with an explicit `maxPixelSize`, never
  `AsyncImage`.
