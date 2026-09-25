# Architecture

Lagoon is one SwiftUI app target for tvOS 26 and iOS 26, plus a tvOS Top
Shelf extension, unit tests and UI tests. The filesystem-synced app group picks
up new Swift files automatically. The only dependency is the `LagoonEngine`
package, pinned to a tagged version in `Package.resolved` so each build records
its engine.

[Coding standards](standards.md) owns folder conventions and rules for new
code.

## Project layout

| Location | Responsibility |
| --- | --- |
| `Lagoon/App/` | App entry, root composition, navigation, refresh coordination, Top Shelf publishing |
| `Lagoon/Features/Accounts/` | Connection, sign-in, account selection and session ownership |
| `Lagoon/Features/{Home,Library,Discovery,Detail,Search,Settings}/` | Feature screens, models and local helpers |
| `Lagoon/Features/Playback/` | The controller, and the audio session the player owns |
| `Lagoon/Features/Playback/{Session,Automation,Tracks}/` | The delivery ladder, server reporting and successor negotiation; what happens when an episode ends; remembered track choices |
| `Lagoon/Features/Playback/{Views,Subtitles,Diagnostics}/` | Player presentation, subtitle search and preferences, optional sampling |
| `Lagoon/Features/Downloads/` | Offline downloads: the store, its background session, and the Downloads screens (iOS only) |
| `Lagoon/Features/SyncPlay/` | Watch Together: group membership, the pure session reducer, and the driver that runs playback from a group |
| `Lagoon/Shared/UI/` | Visual components, design tokens, artwork and presentation helpers shared across features |
| `Lagoon/Shared/Networking/` | Jellyfin/Seerr clients, request authorization, bounded downloads and image cache |
| `Lagoon/Shared/Models/` | Shared wire DTOs and values |
| `Lagoon/Shared/Persistence/` | Credential storage, account data cleanup and legacy storage cleanup |
| `Lagoon/Shared/Diagnostics/` | Diagnostic schema/history/reporting and Sentry transport |
| `LagoonTopShelf/` | Credential-free Top Shelf extension |
| `LagoonTests/`, `LagoonUITests/` | Pure logic, integration, platform journeys and shared UI-test support |

Feature-owned state stays with its feature, even when another feature shows
its controls. Settings binds to the playback and Home preference stores rather
than keeping a copy.

Home's row order is data. `HomeSectionPreferenceResolver` owns the default
order, the viewer's arrangement and which rows are hidden; `HomeView` draws
one row per resolved identifier. A new row needs both an entry in the
resolver's list and a branch to draw it, and the unit suite fails if either is
missing. Server plugin rows join the same arrangement: see [Home Screen
Sections](jellyfin-api.md#home-screen-sections-plugin).

## State and ownership

- `@Observable` stores are owned with `@State` where their lifetime begins.
  The default isolation is `MainActor`; DTOs and other off-actor values are
  `nonisolated`.
- Async loading runs from stable `.task(id:)` roots, so a loading-state change
  never cancels its own work. Late results are dropped on account, query or
  filter changes.
- `SessionStore` owns the active account and its `SeerrSessionStore`.
  `RootView` switches between connection phases, which are states, not pushed
  destinations:

```text
needsServer → needsSignIn → signedIn
                    ↑          ↓
                 choosingAccount
```

Accounts:

- An account is a server/user pair, keyed `{serverURL}|{userId}`.
  UserDefaults holds account metadata and the active account ID; Keychain
  holds each token and the install's device ID.
- Launch restores the last usable account. Keep the idempotent legacy token
  migration.
- Add Account uses a separate draft session seeded with the current server
  but no credentials. A successful, current verification commits and
  activates it; cancel leaves the active Jellyfin and Seerr sessions intact.
- "Who's watching?" is the `choosingAccount` phase at launch and after
  sign-out. Settings opens the same `AccountPickerView` over the app through
  `openProfilePicker` (a full-screen cover on tvOS, a sheet on iOS), leaving
  the active account in place: Back or choosing it again closes the picker,
  and Add Profile closes it before the draft session opens. Profiles group by
  server (`ProfileGrouping`), most recently activated first; activation
  stamps `lastUsedAt`, so compare accounts by `id`, never whole.
- Sign-out revokes and forgets the account and clears its local data.
- Seerr sessions are scoped to the Jellyfin account and the Seerr origin.

`SyncPlayStore` sits in `SessionStore` beside `SeerrSessionStore` and follows
the active account through `synchronizeAccountContext()`. A group belongs to
the account that joined it, so switching accounts or signing out leaves it.
`RootView` injects the store, and the iOS UIKit player host injects it again
because that presentation rebuilds the environment. The store owns membership
(socket, clock, group, queue); `GroupPlaybackDriver` owns playback and holds
`PlaybackController` weakly, never an engine. See [Watch
Together](playback.md#watch-together-syncplay).

`DownloadStore.shared` (iOS only) is the single owner of offline downloads:
the per-account manifest, the background `URLSession` and each file's artwork.

- `SessionStore` activates it on restore, switch and sign-out. Removing an
  account removes its downloads.
- The delegate runs on `OperationQueue.main`, so commands and callbacks share
  MainActor ownership. Completion checks the attempt, keeps the temporary file
  and persists the manifest before the callback returns.
- The active account uses its observed manifest, inactive ones their stored
  manifest. Generation and attempt checks guard anything that suspends.
- `DownloadArtworkIndex` is a separate lock-protected snapshot for background
  image loaders.

## Refresh and navigation

- Only `RootView` observes foreground transitions. It advances the shared
  `ServerSyncState.generation`, and each screen reconciles its own data.
- `ServerRefreshModifier` adds manual refresh and a five-minute cadence to the
  visible, active root browse destination. `MainTabView` gates it by selected
  tab and navigation path; Home also suspends it while playback is presented.
  Hidden tabs and content behind details never poll.
- A failed refresh keeps existing content, focus, loaded page depth and the
  last good snapshot.
- Seerr's detail refresh is separate: 30 seconds while pending approval,
  10 seconds while downloading or importing. Requests are sequential, stop
  when the detail goes inactive or terminal, and reconcile at once after
  foregrounding or moderation. Static metadata stays out of that loop.
- Home, Discover, Library, Search and Settings are stable tabs. Route identity
  belongs to `ContentNavigationRoute`. `MediaItem` keeps value equality so
  updated progress and metadata reach SwiftUI.
- After playback dismissal, the underlying screen refreshes only once
  `client.playbackReports.settle()` returns, but the dismissal itself never
  waits for that report.

## Reusable components

Use these before writing a screen-specific copy:

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

Keep a component in its feature until several callers need the same
behavior. Shared business state belongs in an owner, not a generic view
wrapper. [Design system](design-system.md) owns the visual rules.

## tvOS invariants (violating these regresses real bugs)

- Every screen needs a focusable element, or Menu can exit the app.
- Keep `.scrollClipDisabled()` and rail focus padding. Episode rails stay
  mounted while seasons switch, so focus and layout survive loading.
- The hero's focused control sits outside its `.id()`-keyed, transitioning
  artwork, so Left/Right changes content without replacing focus.
- `.searchable` goes on Search's content, never on the navigation stack or a
  browse screen.
- Refresh moves with the native tab chrome. Its measuring control stays
  mounted but inert over pushed details, the offset lives at tab scope, and
  Down from Refresh goes to Home's hero. It must never stay hittable over
  lower rails.
- Top Shelf reads a sanitized local snapshot and artwork. The extension gets
  no credentials and makes no network calls. Keep its extension product type
  and `_NSExtensionMain` entry point.

Touch and remote input rules are in
[Playback](playback.md#controls-and-presentation). Top Shelf composition, Seerr
status and Discover's rail layout are in the [engineering
notes](reference/architecture.md).

## Refactoring priorities

- Extractions follow queue and resource ownership. Line count alone never
  justifies splitting a coupled implementation.
- Keep the [playback invariants](playback.md#lifecycle-and-memory). Validate
  an ownership change with dismissal and replay, episode handoff, PiP and
  hardware performance, plus both builds and the tests.
