# Lagoon — session notes

Jellyfin client for tvOS 26 and iOS 26: one multiplatform SwiftUI app target
with unit and multiplatform UI test targets. Playback runs on Lagoon's own
sample-buffer engine over vendored FFmpeg static libraries; there is no
AVPlayer path and no third-party Swift dependency.

## Where the rules live

`AGENTS.md` is a symlink to this file, so Codex and other agents read the
same instructions. Edit CLAUDE.md, never the link.

**Start at [docs/README.md](docs/README.md), follow the
[coding standards](docs/standards.md), and read the guide for the area you
are changing before working on it.** This file is a map and a session
checklist, not a second copy of the guides. If a line here disagrees with a
guide, the guide is current and this file needs fixing.

| Guide | Owns |
| --- | --- |
| [Coding standards](docs/standards.md) | Folder structure, Observation and `MainActor` rules, boundaries, review and verification |
| [Architecture](docs/architecture.md) | Ownership, navigation, refresh and invalidation, the tvOS focus invariants |
| [Design system](docs/design-system.md) | Tokens, brand colors, native controls, focus, image loading |
| [Jellyfin API](docs/jellyfin-api.md) | Authentication, endpoints, wire formats, decoding rules, server compatibility |
| [Playback](docs/playback.md) | Engine boundaries, transport, lifecycle, controls, diagnostics, regression checks |
| [Release](docs/release.md) | Build numbers, changelog, acknowledgements, licence, TestFlight (internal and external), release gates |
| [Roadmap](docs/roadmap.md) | Remaining product work and device acceptance |

`docs/reference/` holds the engineering notes and measurements behind the
guides; dated validation evidence belongs on its ticket. Keep routine session
history out of the guides (see "Keeping this clean" in docs/README.md).

## Session workflow

- Build, and keep both destinations green:

  ```
  xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build
  xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' build
  ```

- Test. `LagoonTests` pins the engine's pure logic; keep it green and add
  tests there when new logic is pure enough to pin down:

  ```
  xcodebuild test -scheme Lagoon -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
  ```

- Commits that implement a Jira ticket carry its key as a suffix so Jira's
  development panel links them: `feat: add app icon and top shelf artwork (HEL-31)`.
  Lagoon work lives under the Labs epic (HEL-15) in the maintainer's Jira;
  meta and chore commits without a ticket stay keyless.
- Build numbers are owned by the repo; never let Xcode manage them at upload
  ([Release](docs/release.md)). A change a viewer would notice gets a line in
  `Lagoon/Features/Settings/Changelog.swift`; an invisible one does not.
- The only dependency is the local `Packages/LagoonFFmpeg` package. Do not
  add another without serious deliberation; when you do, add its
  acknowledgement and licence text as [Release](docs/release.md) describes,
  or `AcknowledgementsTests` fails the unit suite.
- Verify UI changes visually in the simulator before calling them done:
  build → `simctl install/launch` → drive focus with
  `osascript -e 'tell application "System Events" to key code …'`
  (125/126/123/124 arrows, 36 select, 53 menu; `keystroke "…"` types into
  the tvOS keyboard) → `simctl io <udid> screenshot`. Exercise focus paths
  and deep scrolls, not just the landing state.
- End-to-end: the public demo server (`demo.jellyfin.org/stable`, user
  `demo`, empty password) supports the full flow including playback.
- Report only what was verified. Before saying a change is done, run the
  builds and the relevant tests and say what ran. If a step was skipped or
  a check failed, say so with the output; never describe an unrun check as
  passed.

## Working with subagents

Use subagents where they make sense, and do the small things yourself.
Delegate when a task is a broad search across many files, when there are
independent pieces that can run in parallel (the tvOS and iOS builds, a
sweep of several guides, a set of mechanical edits with a precise spec), or
when a review benefits from fresh eyes on a diff. Give each agent a precise
spec and check its result; the main session plans, reviews, and verifies.
Do the work directly when it is a single-file edit, a lookup in a file or
symbol you already know, or anything where explaining the task would take
longer than doing it. Never claim an agent's result before it has come back.

## Invariants that have regressed before

Each is explained, with its ticket and evidence, in the guide named. This
list exists so you know to read it before touching the area.

- **Playback** ([Playback](docs/playback.md), notes in `docs/reference/playback/`):
  all playback goes through the sample-buffer engine behind the `PlayerEngine`
  protocol, and the player UI only talks to the protocol. Player views hold
  the engine through `@PlayerEngineRef`, never a strong reference, and
  closures handed to SwiftUI never capture an engine (HEL-152). A renderer's
  request block is armed only while its queue has something to give
  (HEL-137). A light Siri Remote touch-surface tap and a Select press are
  different inputs and never share a path (HEL-134). Software-decoded 10-bit
  video reaches the renderer through the asynchronous `MetalFrameConverter`.
  The delivery ladder descends only on a verdict about the samples: a lost
  VideoToolbox session is rebuilt, not transcoded, and while video output is
  suspended it is ignored outright (HEL-181).
- **Vendored FFmpeg** ([Playback](docs/playback.md)): libavformat is
  repo-built without its network stack and every HTTP open goes through
  `FFmpegNetworkTransport` over URLSession (HEL-142); keep the build script
  and artifact in sync. dav1d is repo-built and must keep its arm64 assembly;
  run `scripts/build-dav1d.sh --verify-only` after touching it, because
  without the assembly nothing fails and everything decodes ten times slower
  (HEL-137). libdovi is vendored, not built, for the profile 7 → 8.1 Dolby
  Vision conversion (HEL-145).
- **Measurement** ([Playback](docs/playback.md), "Regression checks"): never
  trust a casual frame-loss comparison. Same scene, same media-time window,
  simulator untouched, three or more runs, using the Frame-Loss Bench and
  `scripts/framedrop-bench.sh` (HEL-64 retracted two fixes that skipped this).
- **Models and API** ([Jellyfin API](docs/jellyfin-api.md),
  [Architecture](docs/architecture.md)): `@Observable` with `@MainActor`
  default isolation; DTOs are `nonisolated struct`s with defensive decoding.
  Jellyfin JSON is PascalCase and the client's key strategy handles it, so
  never add `CodingKeys` for casing; never decode `Date`; positions are ticks.
  `MediaItem` compares by value and no DTO gets an id-only `==`, because
  SwiftUI drops a state write whose new value compares equal (HEL-132). API
  calls bypass the URL cache for the same reason.
- **tvOS and refresh** ([Architecture](docs/architecture.md), "tvOS
  invariants"): every screen needs a focusable element; keep
  `.scrollClipDisabled()` and rail focus-lift padding intact; the Refresh
  chrome rules; foreground invalidation only from `RootView` advancing
  `ServerSyncState`, with `ServerRefreshModifier` gated to the visible root
  destination (HEL-135); Seerr's detail-only live refresh stays separate from
  browse invalidation (HEL-136).
- **Design** ([Design system](docs/design-system.md)): design tokens
  (`Metrics`/`Motion`), never literals; brand colors only for branding and
  system semantics elsewhere; native controls over hand-rolled focus visuals;
  images through `CachedAsyncImage` with an explicit `maxPixelSize`, never
  `AsyncImage`.
