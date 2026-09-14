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
| `Lagoon/App/` | App entry, root composition, navigation, refresh coordination, Top Shelf publishing |
| `Lagoon/Features/Accounts/` | Connection, sign-in, account selection and session ownership |
| `Lagoon/Features/{Home,Library,Discovery,Detail,Search,Settings}/` | Feature screens, models and local helpers |
| `Lagoon/Features/Playback/` | Controller, reporting, successor preparation, track preferences and system media |
| `Lagoon/Features/Playback/{Views,Engine,Transport,Subtitles,Diagnostics}/` | Player presentation, decode/render pipeline, byte sources/cache, subtitles and sampling |
| `Lagoon/Features/Downloads/` | Offline downloads: the store, its background session, and the Downloads screens (iOS only) |
| `Lagoon/Features/SyncPlay/` | Watch Together: group membership, the pure session reducer, and the driver that runs playback from a group |
| `Lagoon/Shared/UI/` | Visual components, design tokens, artwork and presentation helpers shared across features |
| `Lagoon/Shared/Networking/` | Jellyfin/Seerr clients, request authorization, bounded downloads and image cache |
| `Lagoon/Shared/Models/` | Shared wire DTOs and values |
| `Lagoon/Shared/Persistence/` | Credential storage, account data cleanup and legacy storage cleanup |
| `Lagoon/Shared/Diagnostics/` | Diagnostic schema/history/reporting and Sentry transport |
| `LagoonTopShelf/` | Credential-free Top Shelf extension |
| `LagoonTests/`, `LagoonUITests/` | Pure logic, integration, platform journeys and shared UI-test support |

Feature-owned state stays with its feature even when another feature presents
its controls. For example, Settings binds to playback/Home preference stores;
it does not own another copy of their values.

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

`SyncPlayStore` is owned by `SessionStore` beside `SeerrSessionStore`, and
`synchronizeAccountContext()` points it at the active account — a SyncPlay
group belongs to the account that joined it, so a switch or a sign-out leaves
it. `RootView` injects it into the environment, and the iOS UIKit player host
re-injects it because that presentation rebuilds the environment from scratch.
The store owns membership (socket, server clock, group, queue) and
`GroupPlaybackDriver` owns the playback side, holding `PlaybackController`
weakly and never an engine. See
[Watch Together](playback.md#watch-together-syncplay-hel-172).

`DownloadStore.shared` (iOS only) is the one owner of offline downloads:
its per-account manifest, the background `URLSession` that carries every
transfer, and the artwork saved beside each file. `SessionStore` activates it
for whichever account is current, on restore, switch, and sign-out; removing
an account removes its downloads too.

Its URLSession delegate uses `OperationQueue.main`. Commands and delegate
callbacks therefore share MainActor ownership: completing a download checks
the attempt, preserves the temporary file, and persists the manifest before
the callback returns. The active account uses its observed manifest; inactive
accounts use their stored manifest. Generation and attempt checks protect
operations that suspend, including permission queries and pause/restart.
`DownloadArtworkIndex` is the separate, lock-protected value snapshot read by
background image loaders.

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
| Item, series, collection, and Seerr detail composition | `DetailPageScaffold`, `DetailMetadataHeader`, `DetailActionLayout`, `TitleArtView`, `CastStrip` (Jellyfin people or `CastCredit`s) and `DetailLayout` in `DetailComponents.swift` |
| Adaptive actions, metadata wrapping, poster sizing | `AdaptiveActionStack`, `MetadataFlowLayout`, `PosterLayout` |
| Loading, retry, and failure presentation | `LoadingView`, `InlineRetryView`, `ErrorStateView` |
| Artwork and palette loading | `CachedAsyncImage`, `ImageCache`, `ArtworkPalette` |
| Theme colours and the profile's theme choice | `Theme`, `ThemePalette`, `ThemeStore`, `ThemeBloomOverlay` in `AppTheme.swift` and `ThemeBloomView.swift` |
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

HEL-155 establishes the layout above. `PlaybackController` has its own file;
reporting, successor preparation and optional HUD/trace sampling have explicit
owners. `VideoPlayerView` retains the controller with `@State`. Seerr request
list/detail models have separate homes, and Settings category views bind back
to the root's existing stores. `LagoonUITests/Support/` owns shared player
launching, fixture resolution and state waits; platform gestures remain in
their suites. The [migration plan](reference/source-migration-plan.md) records
verification progress and remaining acceptance.

Further engine/cache extractions should follow queue and resource ownership.
Line counts alone do not justify splitting a coupled implementation into
extensions. Preserve the [playback invariants](playback.md#lifecycle-and-memory)
and validate ownership changes with dismissal/replay, episode handoff, PiP
and physical performance checks in addition to both platform builds/tests.
