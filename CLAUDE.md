# Lagoon — session notes

Jellyfin client for tvOS 26 + iOS 26 (one multiplatform app target, SwiftUI,
with unit and tvOS UI test targets). Design language adapted from a 2026 streaming-app redesign
. **The only dependency is the
local `Packages/LagoonFFmpeg` package** (HEL-48 M6): it pins exactly the
FFmpeg static xcframeworks the Lagoon sample-buffer engine links —
artifacts from MPVKit's 1.0.0 release (FFmpeg 8.1.2) plus their
transitive static libs (uavs3d, lcms2), with **dav1d built
by this repo** (`scripts/build-dav1d.sh`, vendored under
`Packages/LagoonFFmpeg/Artifacts/`) because upstream's is compiled without
its arm64 assembly — see docs/playback.md (HEL-137). **libavformat is also
repo-built**, without its network stack (`scripts/build-ffmpeg-format.py`,
HEL-142); every HTTP open goes through `FFmpegNetworkTransport` over
URLSession; keep the build script and vendored artifact in sync. All
compiler roles use Apple Clang.
MPVKit/libmpv/MoltenVK/libplacebo have been out of the project entirely since
2026-08-17. Don't add other dependencies without serious deliberation.

**Full technical docs are in `docs/` — read the relevant file before working on an area:**

- `docs/architecture.md` — layout, SessionStore phases, navigation, **tvOS focus invariants**
- `docs/jellyfin-api.md` — endpoints, auth header, PascalCase/ticks quirks, image fallbacks
- `docs/playback.md` — device profile, stream resolution, progress reporting; player gotchas
- `docs/design-system.md` — tokens, focus strategy, hero/glow, image cache rules
- `docs/roadmap.md` — MVP scope and planned features (seerr, subtitles, Top Shelf, …)
- `docs/release.md` — TestFlight flow, **build numbers owned by the repo**
  (never let Xcode manage them at upload), and how to write changelog entries

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
- The vendored dav1d must keep its arm64 assembly. `scripts/build-dav1d.sh
  --verify-only Packages/LagoonFFmpeg/Artifacts/Libdav1d.xcframework` after
  ever touching it: without the assembly it still decodes everything
  correctly, roughly ten times slower, and nothing fails (HEL-137).
- Use design tokens (`Metrics`/`Motion`), not literals; brand colors
  (`.lagoonTeal`/`.lagoonDeep`) only for branding — system semantics elsewhere.
- `@Observable` + `@MainActor` default isolation; model types are
  `nonisolated struct`s with defensive decoding (`decodeIfPresent` + defaults).
- Jellyfin JSON is PascalCase; the client's global key strategies handle it —
  never add CodingKeys for casing. Don't decode `Date` (7-digit .NET
  fractions break ISO8601DateFormatter). Positions are ticks → `Ticks` helpers.
- `MediaItem` compares by value (synthesized); navigation identity is
  `ContentNavigationRoute`'s. Never give a DTO an id-only `==`: SwiftUI
  drops a `@State` write whose new value compares equal to the old one and
  skips child views handed an "equal" item, which is how a re-fetched
  resume point never reached the screen (HEL-132). API calls bypass the
  URL cache for the same reason; the ledger in `client.playbackReports`
  makes a post-player re-fetch wait for the stop report.
- Every screen needs a focusable element (Menu quits the app otherwise);
  keep `.scrollClipDisabled()` + rail focus-lift padding intact.
- Images go through `CachedAsyncImage` with an explicit `maxPixelSize` —
  never `AsyncImage`.
- All playback goes through the Lagoon sample-buffer engine behind the
  `PlayerEngine` protocol — never add AVPlayer/AVKit playback paths; the
  player UI must only talk to the protocol.
- A renderer's `requestMediaDataWhenReady` block is armed only while its
  queue has something to give (`armVideoRequests`/`rearmRequestsIfNeeded` in
  the engine). A block that returns empty-handed is called again at once, and
  that loop cost half a core at the highest priority in the process while
  4K AV1 starved (HEL-137). Keep the invariant when touching the pumps.
- A light Siri Remote touch-surface tap and a Select press are different
  inputs: the former is the indirect-touch recognizer in `MenuPressGate` and
  only calls `pokeControls()`; SwiftUI's surface `onTapGesture` is Select and
  keeps its scrub/skip/Up Next/play-pause priority chain (HEL-134). Never
  merge the two paths.
- Foreground content invalidation comes only from `RootView` advancing the
  shared `ServerSyncState`. `ServerRefreshModifier` owns top-level browse
  destinations' five-minute and manual refresh paths, and `MainTabView` gates
  them to the visible root destination (HEL-135). Do not duplicate scene
  observers, poll hidden tabs or pushed details, or replace existing content
  with a loading state during reconciliation. On tvOS, Refresh belongs to the
  top chrome: it must scroll off and return with the native tab bar, remain
  reachable from that bar, route Down directly to Home's hero, and never stay
  hittable over lower content. Keep its measuring control mounted but inert
  across pushed details and retain its chrome offset at `MainTabView` scope;
  conditionally recreating it on return puts it back at the screen origin.
- Seerr's detail-only live refresh is separate from browse invalidation
  (HEL-136): wait 30 seconds for pending approval and 10 seconds for active
  download/import work, only while that detail and the scene are active.
  Keep requests sequential, stop at terminal state or on navigation, reconcile
  immediately after foregrounding and moderation actions, retain the last good
  snapshot on transient failure, and leave static metadata out of the loop.
- Software-decoded 10-bit video reaches the renderer through
  `MetalFrameConverter` (`gpu-sdr` on tvOS HDR, `gpu-pq` otherwise); the
  VideoToolbox transfer modes are fallbacks and diagnostics. The GPU stage is
  asynchronous on purpose: measured synchronously it was as slow as what it
  replaced. See docs/playback.md.
- **Verify UI changes visually in the simulator** before considering them
  done: build → `simctl install/launch` → drive focus with
  `osascript -e 'tell application "System Events" to key code …'`
  (125/126/123/124 arrows, 36 select, 53 menu; `keystroke "…"` types into the
  tvOS keyboard) → `simctl io <udid> screenshot`. Exercise focus paths and
  deep scrolls, not just the landing state.
- End-to-end testing: the public demo server (`demo.jellyfin.org/stable`,
  user `demo`, empty password) supports the full flow including playback.
