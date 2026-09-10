# Architecture

Lagoon is one SwiftUI app target for tvOS 26 and iOS 26, with a tvOS Top Shelf
extension, unit tests, and UI tests. The filesystem-synchronized app group
includes new Swift files automatically. `Packages/LagoonFFmpeg` is the only
local package dependency.

Follow [Coding standards](standards.md) for the target folder convention and
rules for new code. The layout below describes the current implementation.

## Project layout

| Location | Responsibility |
| --- | --- |
| `Lagoon/LagoonApp.swift` | App entry and shared environment |
| `Lagoon/Models/` | Value types, wire DTOs, preferences, release metadata |
| `Lagoon/Networking/` | Jellyfin and Seerr clients, credentials, bounded downloads, image cache |
| `Lagoon/ViewModels/` | Account/session stores and screen state |
| `Lagoon/Views/Components/` | Shared visual primitives, navigation and presentation helpers |
| `Lagoon/Views/{Home,Library,Discovery,Detail,Search,Settings,Onboarding}/` | Feature screens |
| `Lagoon/Views/Player/` | Player UI and, currently, playback orchestration, cache, and engine code |
| `LagoonTopShelf/` | Credential-free Top Shelf extension |
| `LagoonTests/`, `LagoonUITests/` | Pure logic, integration, and platform journeys |

The player folder's mixed responsibilities are a cleanup target, not the
recommended pattern for new features. See [refactoring priorities](#refactoring-priorities).

## State and ownership

Use `@Observable` stores, owned with `@State` where their lifetime begins.
The project defaults to `MainActor` isolation; DTOs and other values used off
the main actor declare `nonisolated` explicitly. Drive asynchronous loading
from stable `.task(id:)` roots so loading-state changes do not cancel their
own work. Invalidate late results on account, query, or filter changes.

`SessionStore` owns the active account and its `SeerrSessionStore`.
`RootView` switches among connection phases; these are states, not pushed
navigation destinations:

```text
needsServer → needsSignIn → signedIn
                    ↑          ↓
                 choosingAccount
```

Accounts are server/user pairs, identified by `{serverURL}|{userId}`.
UserDefaults stores account metadata and the active account ID; Keychain
stores each account's token and the install's device ID. Restore the last
usable account on launch. Preserve the idempotent legacy token migration.

Add Account uses a separate draft session seeded with the current server,
without copying credentials. Only a successful, current verification commits
and activates it. Cancel leaves the active Jellyfin and Seerr sessions intact.
Sign-out revokes and forgets the account and clears its owned local data.
Seerr sessions remain scoped to the Jellyfin account and Seerr origin.

## Refresh and navigation

`RootView` alone observes foreground transitions and advances the shared
`ServerSyncState.generation`. Screens reconcile their own data. The
`ServerRefreshModifier` adds manual refresh and a five-minute cadence to
visible, active root browse destinations. `MainTabView` gates it by selected
tab and navigation path; Home also suspends it while presenting playback.
Keep existing content, focus, loaded page depth, and the last good snapshot
when a refresh fails. Hidden tabs and content behind details must not poll.

Seerr's detail refresh is separate: pending approval waits 30 seconds, active
download/import waits 10 seconds. Requests are sequential, stop when the
detail becomes inactive or reaches a terminal state, and reconcile immediately
after foregrounding or moderation. Static metadata stays out of that loop.

Home, Discover, Library, Search, and Settings are stable tabs. Route identity
belongs to `ContentNavigationRoute`; `MediaItem` retains value equality so
updated progress and metadata reach SwiftUI. Playback dismissal waits for
`client.playbackReports.settle()` before refreshing the underlying screen;
the dismissal itself never waits for that network report.

## Reusable components

Use the existing shared boundaries before adding another screen-specific copy:

| Need | Existing implementation |
| --- | --- |
| Poster and landscape cards, horizontal browsing | `MediaCards.swift`, `MediaRail.swift` |
| Item, series, collection, and Seerr detail composition | `DetailPageScaffold`, `DetailMetadataHeader`, `TitleArtView`, `CastStrip` in `DetailComponents.swift` |
| Adaptive actions, metadata wrapping, poster sizing | `AdaptiveActionStack`, `MetadataFlowLayout`, `PosterLayout` |
| Loading, retry, and failure presentation | `LoadingView`, `InlineRetryView`, `ErrorStateView` |
| Artwork and palette loading | `CachedAsyncImage`, `ImageCache`, `ArtworkPalette` |
| Foreground/manual refresh | `ServerSyncState`, `ServerRefreshModifier` |
| Shared playback with platform presentation | `PlayerEngine`, `playerPresentation`, player overlay views |

Keep a component local to its feature until multiple callers need the same
behavior. Shared business state belongs in an owner or service, not in a
generic view wrapper. See [Design system](design-system.md) for visual rules.

## tvOS invariants (violating these regresses real bugs)

- Every screen needs a focusable element; otherwise Menu can exit the app.
- Preserve `.scrollClipDisabled()` and rail focus padding. Keep episode rails
  mounted while switching seasons so focus and layout survive loading.
- The hero's focused navigation control stays outside its transitioning,
  `.id()`-keyed artwork. Left/Right changes content without replacing focus.
- Put `.searchable` on Search's content, never on the navigation stack or a
  browse screen.
- Refresh moves with the native tab chrome. Keep its measuring control mounted
  but inert over pushed details, retain the offset at tab scope, and route
  Down from Refresh to Home's hero. It must not remain hittable over lower rails.
- Top Shelf consumes a sanitized local snapshot and artwork. The extension
  gets no credentials and does no network fetching. Preserve its extension
  product type and `_NSExtensionMain` entry point when changing the project.

See [Playback](playback.md#controls-and-presentation) for the separate touch
and remote input rules, and the [engineering notes](reference/architecture.md)
for Top Shelf composition, Seerr status interpretation, and Discover's
server-defined rail layout.

## Refactoring priorities

Assessment from the September 10, 2026 checkout. These are proposed steps,
not completed migrations. Line counts identify places to inspect; ownership
and repeated behavior determine what should actually be extracted.

1. **Separate player orchestration from its view.**
   `VideoPlayerView.swift` is 2,392 lines; `PlaybackController` occupies roughly
   2,000 before the actual view starts. First give the controller its own file
   without changing lifetime, visibility, or behavior. Then extract reporting,
   successor preparation, and diagnostic sampling around explicit ownership
   and cancellation boundaries. Existing subtitle, audio-session, Now Playing,
   and cache coordinators show this approach already works here.
2. **Give playback a cohesive feature area.** Move the controller, engine,
   demux/transport, cache, and subtitle processing into
   `Lagoon/Features/Playback/` in reviewable steps. Keep SwiftUI surfaces and
   controls in that feature's `Views/` subfolder, following the
   [target structure](standards.md#folder-structure).
   `SampleBufferPlayerEngine.swift` is 3,671 lines and
   `PlaybackCache.swift` is 1,863; later extractions should follow queue and
   resource ownership. Splitting the engine into arbitrary extensions would
   leave its coupling intact. Preserve the [playback invariants](playback.md#lifecycle-and-memory).
3. **Separate screens that currently share a file.**
   `SeerrRequestsView.swift` contains list state, list UI, cards, detail state,
   and detail UI. Split list/detail responsibilities and give their observable
   models explicit homes. `SettingsView.swift` is 1,044 lines; its native
   platform/category composition is another bounded extraction, keeping
   common setting behavior shared and platform controls native.
4. **Share the repeated player test harness.** `TouchPlayerUITests` explicitly
   copies launch, fixture, state parsing, and waiting helpers from
   `PlayerRegressionUITests`. Extract those helpers into test support while
   leaving touch and Siri Remote interactions in their platform suites.

Validate each step with both platform builds and the relevant existing tests.
Playback ownership changes also need dismissal/replay, episode handoff, PiP,
and physical performance checks. Keep behavior changes in separate work from
the structural move so a regression has a narrow cause.
