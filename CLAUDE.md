# Lagoon — session notes

Jellyfin client for tvOS 26 + iOS 26 (one multiplatform target, SwiftUI, no
test target). Design language adapted from a 2026 streaming-app redesign
. **The only dependency is the
local `Packages/LagoonFFmpeg` package** (HEL-48 M6): it pins exactly the
FFmpeg static xcframeworks the Lagoon sample-buffer engine links —
artifacts from MPVKit's 1.0.0 release (FFmpeg 8.1.2) plus their
transitive static libs (gnutls stack, dav1d, uavs3d, lcms2) — with
MPVKit/libmpv/MoltenVK/libplacebo out of the project entirely since
2026-08-17. Don't add other dependencies without serious deliberation.

**Full technical docs are in `docs/` — read the relevant file before working on an area:**

- `docs/architecture.md` — layout, SessionStore phases, navigation, **tvOS focus invariants**
- `docs/jellyfin-api.md` — endpoints, auth header, PascalCase/ticks quirks, image fallbacks
- `docs/playback.md` — device profile, stream resolution, progress reporting; player gotchas
- `docs/design-system.md` — tokens, focus strategy, hero/glow, image cache rules
- `docs/roadmap.md` — MVP scope and planned features (seerr, subtitles, Top Shelf, …)
- `docs/release.md` — TestFlight flow (Xcode GUI, build numbers auto-managed at upload)

Quick rules that prevent regressions:

- Commits that implement a Jira ticket carry its key as a suffix so Jira's
  development panel links them: `feat: add app icon and top shelf artwork (HEL-31)`.
  Lagoon work lives under the Labs epic (HEL-15) on helop-ou.atlassian.net;
  meta/chore commits without a ticket stay keyless.

- Build: `xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build`
  (and the iOS Simulator destination — both must stay green).
- Tests: `xcodebuild test -scheme Lagoon -destination 'platform=tvOS
  Simulator,name=Apple TV 4K (3rd generation)'` — LagoonTests covers the
  engine's pure logic (audio timeline, NAL filter, bench). Keep it green;
  add tests there when engine logic is pure enough to pin down.
- Never trust a casual frame-loss comparison: same scene, same media-time
  window, simulator untouched, 3+ runs (HEL-64 retracted two fixes that
  ignored this). Use Settings → Debug → Frame-Loss Bench and
  `scripts/framedrop-bench.sh`; see docs/playback.md.
- Use design tokens (`Metrics`/`Motion`), not literals; brand colors
  (`.lagoonTeal`/`.lagoonDeep`) only for branding — system semantics elsewhere.
- `@Observable` + `@MainActor` default isolation; model types are
  `nonisolated struct`s with defensive decoding (`decodeIfPresent` + defaults).
- Jellyfin JSON is PascalCase; the client's global key strategies handle it —
  never add CodingKeys for casing. Don't decode `Date` (7-digit .NET
  fractions break ISO8601DateFormatter). Positions are ticks → `Ticks` helpers.
- Every screen needs a focusable element (Menu quits the app otherwise);
  keep `.scrollClipDisabled()` + rail focus-lift padding intact.
- Images go through `CachedAsyncImage` with an explicit `maxPixelSize` —
  never `AsyncImage`.
- All playback goes through the Lagoon sample-buffer engine behind the
  `PlayerEngine` protocol — never add AVPlayer/AVKit playback paths; the
  player UI must only talk to the protocol.
- **Verify UI changes visually in the simulator** before considering them
  done: build → `simctl install/launch` → drive focus with
  `osascript -e 'tell application "System Events" to key code …'`
  (125/126/123/124 arrows, 36 select, 53 menu; `keystroke "…"` types into the
  tvOS keyboard) → `simctl io <udid> screenshot`. Exercise focus paths and
  deep scrolls, not just the landing state.
- End-to-end testing: the public demo server (`demo.jellyfin.org/stable`,
  user `demo`, empty password) supports the full flow including playback.
