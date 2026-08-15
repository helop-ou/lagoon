# Lagoon — session notes

Jellyfin client for tvOS 26 + iOS 26 (one multiplatform target, SwiftUI, no
external dependencies, no test target). Design language adapted from the
2026 streaming-app redesign.

**Full technical docs are in `docs/` — read the relevant file before working on an area:**

- `docs/architecture.md` — layout, SessionStore phases, navigation, **tvOS focus invariants**
- `docs/jellyfin-api.md` — endpoints, auth header, PascalCase/ticks quirks, image fallbacks
- `docs/playback.md` — device profile, stream resolution, progress reporting; player gotchas
- `docs/design-system.md` — tokens, focus strategy, hero/glow, image cache rules
- `docs/roadmap.md` — MVP scope and planned features (seerr, subtitles, Top Shelf, …)

Quick rules that prevent regressions:

- Commits that implement a Jira ticket carry its key as a suffix so Jira's
  development panel links them: `feat: add app icon and top shelf artwork (HEL-31)`.
  Lagoon work lives under the Labs epic (HEL-15) on helop-ou.atlassian.net;
  meta/chore commits without a ticket stay keyless.

- Build: `xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build`
  (and the iOS Simulator destination — both must stay green).
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
- **Verify UI changes visually in the simulator** before considering them
  done: build → `simctl install/launch` → drive focus with
  `osascript -e 'tell application "System Events" to key code …'`
  (125/126/123/124 arrows, 36 select, 53 menu; `keystroke "…"` types into the
  tvOS keyboard) → `simctl io <udid> screenshot`. Exercise focus paths and
  deep scrolls, not just the landing state.
- End-to-end testing: the public demo server (`demo.jellyfin.org/stable`,
  user `demo`, empty password) supports the full flow including playback.
