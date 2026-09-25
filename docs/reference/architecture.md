# Architecture engineering notes

The reasoning behind the [architecture guide](../architecture.md). It is not a
release checklist or proof of hardware acceptance.

## Session lifecycle

`SessionStore`'s phases are **states, not screens you navigate to**;
`RootView` crossfades between them. Persistence:

- UserDefaults: the `accounts` list, the active account id, and the server
  being connected to right now (not an account until credentials work).
- `KeychainStore`: one token **per account**, keyed
  `token:{serverURL}|{userId}`, plus a per-install device id that survives
  reinstalls so the server's device list stays clean.

`restore()` resumes the last active account, so a single profile never sees
the picker. `choosingAccount` appears only when nothing can be resumed or
Settings asks. A missing token goes to `needsSignIn`; no accounts at all goes
to `needsServer`.

### Server reconciliation

SwiftUI keeps tab and navigation trees mounted in the background, so
returning does not re-run `task` or `onAppear`. `RootView` is the single
scene-lifecycle observer: each move to `ScenePhase.active` advances
`ServerSyncState.generation`, and each server-backed screen reconciles only
its own state.

Every reconciling surface keeps current content and focus while requests run,
discards superseded responses, and keeps the last good snapshot on failure.
Extra rules:

- **Home's hero always has a source.** `HeroSelection` walks tiers in order:
  Recently Added; Continue Watching and Next Up; Favorites; plugin and curated
  rails; last, a random library sample fetched only when all else is empty.
  The first tier with an item that has a backdrop and overview supplies the
  whole hero; tiers are never mixed to reach six. On refresh, items still
  returned by the server keep their place and gaps fill from the leading tier.
  Collections are excluded (their cards route to a collection page, the hero
  to an item).
- **Home's Next Up holds only unstarted, unwatched episodes**; in-progress
  ones belong to Continue Watching. Series detail Play still resumes, and
  autoplay has its own cursor. Recently Added TV resolves episodes to real,
  deduplicated series in latest-addition order, on load and refresh.
- **An open library re-reads as many items as it had loaded.** Focus and
  scroll identity survive instead of collapsing to page one.

`ServerRefreshModifier` gives top-level browse destinations a five-minute
cadence and manual refresh. `MainTabView` passes the selected tab and an empty
root path explicitly; otherwise mounted hidden tabs would poll and a pushed
detail would refresh content behind it.

tvOS Refresh button:

- A compact circle at the top leading edge, beside but outside the tab group,
  so Left/Right reaches it from the tab bar without an empty toolbar row or a
  tab entry.
- It joins the focus graph only while the top chrome is focused, so Up from
  content returns to the selected tab, and Down falls to the tab bar, not
  Home's hero.
- Its UIKit measuring control stays mounted but inert while a detail is
  pushed, and `MainTabView` keeps the last chrome offset at root scope. A
  recreated control first reports the screen origin and flashes Refresh over a
  deeply scrolled root.
- While refreshing, the arrow rotates; Reduce Motion keeps it still. It targets
  `ServerSyncState.activeTarget`, so only the visible destination refreshes.

The scene stays active under a full-screen player, so playback dismissal has
its own path: the targeted refresh waits for the stop report before
re-reading progress.

### Multiple accounts

`StoredAccount` is one server+user pair with `id` `{serverURL}|{userId}`,
never display names, so renaming cannot orphan a token or duplicate an entry.

Adding an account: `RootView` presents `AddAccountView` on a separate
`SessionStore(accountDraft: true)` while the active client and Seerr stay
mounted. `makeAccountDraft()` seeds only the server URL and name. Each
presentation gets a fresh draft, so a cancelled attempt cannot change the next
default, and changing the draft's server invalidates responses from the old
one. Nothing persists until `finishAddingAccount` commits the verified
account.

- **`migrateLegacySessionIfNeeded()` is load-bearing.** The old single-slot
  layout kept the token under the bare account `"accessToken"`. Without the
  move every existing install would be signed out. It runs first in
  `restore()` and is idempotent, guarded on the `accounts` key being absent.
- **Signing out forgets the account.** `logout` revokes the token, so a kept
  entry could only fail. Other accounts are untouched; the picker takes over
  if any remain.

Switching to a valid remembered account needs no re-authentication. The
session transition synchronously clears outgoing Seerr state, moves
recent-search ownership and invalidates Top Shelf work; entering the picker
drops active access. `MainTabView` is identified by account, so navigation,
details and search rebuild for the next viewer.

`AccountLocalData` owns forgetting: the Jellyfin token, every Seerr cookie
linked to the account (including earlier servers), cached libraries, recent
searches, and subtitle, track and Home preferences. The shared Seerr address
goes only with the last Jellyfin account using it. Legacy global recent
searches are discarded, since their owner is unknown.

- Forget locally **before** awaiting remote logout. Revocation uses immutable
  client copies, so a late completion cannot reach the next account.
- A Keychain deletion or enumeration failure leaves a persistent removal
  marker that blocks credential restore and raises a root-level cleanup alert.
  Re-adding that account must finish the cleanup before saving a new token.

### Seerr sessions

Seerr is an optional second service, separate from `JellyfinClient`.

- `SeerrSessionStore` shares the address between accounts on the same
  Jellyfin server, but keeps a separate `connect.sid` cookie per Lagoon
  account in the Keychain.
- Quick Connect is the main sign-in. A Jellyfin password works as a one-time
  fallback and is never stored.
- Switching accounts clears in-flight Seerr UI state and restores only the
  matching cookie. Activation invalidates pending restores and sign-ins before
  they can write into the next session.
- Automatic URLSession cookie handling is off, so only the selected cookie is
  sent. A failed cookie deletion is quarantined, not left restorable.

## Navigation

Each of the five tabs owns a `NavigationStack`. `ItemDetailRouter` resolves a
`ContentNavigationRoute`: `.series` → `SeriesDetailView`, everything else →
`ItemDetailView`. On tvOS playback is a `fullScreenCover(item:)` on the screen
that started it; on iOS the screen requests it and the tab root's host
presents it ([Playback](../playback.md#controls-and-presentation)).

**Library** is one paged grid of movies and series.

- Every filter (media type, sort, source library, genre, decade, unwatched,
  favorites, 4K movies) goes to Jellyfin on each page and refresh, so it holds
  across pagination. Resolution filtering is Movies-only; series folders have
  no resolution.
- `LibrarySelection` persists per server/account. Source choices come from
  cached `LibraryTab` values until `userViews()` succeeds, so a stale saved
  source is cleared only against an authoritative list.
- The Library filter appears only when several libraries share a media type.
  A redundant saved library filter becomes its media type, so a hidden menu
  never leaves an invisible constraint.
- Media type is a segmented Picker on iOS and a menu Picker on tvOS. **The
  tvOS menu commits on Select, not focus**, so moving past it toward Sort or
  Filters never flips Movies to Shows or clears the 4K filter. Only
  watch-state, favorites and 4K are Toggles; the rest are single-selection
  Pickers.
- Decade ranges come from Jellyfin's `Items/Filters` years for the current
  media type and source, not the loaded page or a fixed range. Gaps and
  undated titles make no choices; queries use the `Years` parameter. A saved
  decade stays clearable while loading or offline and drops only when a
  successful catalogue lacks it. A saved genre survives a catalogue that no
  longer lists it.
- `LibraryViewModel` resets paging on filter change, counts raw server rows
  for offsets and deduplicates visible IDs. Its refresh target is
  `library.all`, so filter changes add no timer and leave the stack alone.

**Search** (`SearchView`) is the single search location: Jellyfin and Seerr
matches as separate rails, recent terms (`RecentSearchStore`) under the
keyboard when the field is empty.

- It is **its own tab**. tvOS `.searchable` draws a resident field and full
  keyboard and expects to own the screen; folding it into Discover pushed
  content below the fold.
- `.searchable` goes on the content, **not** the `NavigationStack`, or the
  field draws over pushed details. The stack is a heterogeneous
  `NavigationPath`, since results carry two route types.
- Rails are previews. See All opens `ContentNavigationRoute.search(query)` or
  `SeerrNavigationRoute.search(query)` in the same stack, both drawn by
  `SearchResultsView`. Library cursors count raw server items and Seerr
  cursors follow server pages, so filtering and deduplicating cards must not
  touch either cursor. Seerr result identity includes media type and TMDB ID.
- **An empty section offers no See All.** The page would repeat the message,
  and a tvOS page of text has no focus, so Menu quits the app.
  `SearchResultsView` keeps a focusable element in both empty states:
  `LoadingView` for the first page, and a retry beside an empty result that
  rewinds the cursor. The status block is unfocusable so Down from the field
  reaches the Seerr section.

**Settings › About › Legal.** The Acknowledgements sheet follows the
changelog sheet's tvOS pattern: no `NavigationStack`, its own header and
footer at `Metrics.modalPanelSize`, and licence text split into focusable
paragraphs. Privacy Policy and Support rows appear only once
`LegalDestinations` has a URL; iOS opens it, tvOS shows the address to type
elsewhere. The sign-in screen's "About Lagoon" reaches the same section.

## Top Shelf is a full-screen carousel

`TVTopShelfCarouselItem` has **no `title` property** (it has `contextTitle`,
`summary`, `genre`, `duration`), so **the title must be in the artwork**, as
in the Apple TV app.

The app composes; the extension only reads.

- `TopShelfArtwork` draws the backdrop, a scrim over the text corner, then
  Jellyfin's logo or, failing that, the title in type (as `TitleArtImage`
  does).
- JPEGs at 3840x2160 and 1920x1080 go into the shared App Group container.
  The extension resolves them by file name against **its own** container URL,
  never an absolute path from another process. That keeps it credential-free
  and network-free.

`TopShelfPublisher` owns one cancellable task and commits on the main actor:

- Each operation captures its server/user and source URLs and writes only to
  a unique `<account-hash>-<generation>` staging directory.
- Once complete artwork exists it commits `snapshot-v2.json` atomically,
  prunes old generations and notifies TVServices. A stale worker deletes only
  its own directory; the extension never sees a half-written shelf.
- The extension reads only that manifest. It validates artwork paths and
  rechecks the generation.
- Switching accounts, entering the picker, forgetting and logout invalidate
  pending work and clear the snapshot. An empty resume result clears the
  shelf; a network failure keeps the last valid snapshot; an unrelated Next Up
  failure cannot block clearing.

Deep links: `lagoon://play/{id}` resumes and `lagoon://item/{id}` opens the
detail. Both require `owner=<account-hash>&generation=<UUID>`; the app checks
the active account and committed manifest before and after fetching, so
unowned links and links from cleared snapshots are ignored.
`DeepLinkRouterTests` and `TopShelfPublisherTests` cover this.

### Eight items, and why artwork is only composed once

The cap is **8**. The HIG's "three to eight" is for scrolling banners; nothing
numbers a carousel. The banner's reason still applies: a swipe-navigated,
wrapping carousel buries the title you want if it runs long.

- Artwork is reused when account/server, title, source URLs and layout
  version match the previous complete snapshot. Both images are copied into
  the new generation before commit, so deleting the old one cannot break it.
- Item IDs alone never identify artwork across servers. Changed image tags or
  URLs recompose (a server that changes pixels without changing the URL can
  still need cache recovery).
- Metadata is rewritten on every publication to keep remaining time and
  episode context current.
- No partial payload is ever visible. If every item's artwork fails, the
  prior snapshot stays.

### What the app derives, because the extension cannot

The extension has no library and no credentials, so the app writes into the
snapshot:

- **`context`**, the carousel's one line of text above the artwork title. It
  says why the item is shown and adds the detail: an episode names the
  episode (`railTitle` is the series), everything else says how much is left.
- **`mediaOptions`**, the 4K / HDR / Dolby Vision / Atmos badges tvOS draws,
  from the same `MediaQuality` thresholds as the detail page and the Info
  panel. `resumeItems` requests `MediaSources` for this. They are nil, not
  empty, when the server sent no streams, so "unknown" never reads as "plain
  SDR".

`TopShelfPayloadTests` pins both, and the JSON keys the extension mirrors by
hand.

**Top Shelf only shows when the app is in the top row of the tvOS Home
screen.** An empty shelf usually means that.

### The extension target's product type is load-bearing

`LagoonTopShelf` must be `com.apple.product-type.app-extension`.
`tv-app-extension` is the legacy TVML extension: its entry point is
`_TVExtensionMain`, so the appex never starts the NSExtension service
`com.apple.tv-top-shelf` needs. The system kills it and shows the static brand
image, which looks exactly like an empty shelf, and none of the extension's
code runs.

Check the entry point first:

```sh
nm -m Lagoon.app/PlugIns/LagoonTopShelf.appex/LagoonTopShelf | grep -i extensionmain
# must say _NSExtensionMain (from Foundation), never _TVExtensionMain
```

- The target sets `OTHER_LDFLAGS = "-framework TVServices"` explicitly, since
  the old product type linked it implicitly.
- Nothing about Top Shelf is configured in App Store Connect. The only portal
  requirement is the App Group on both App IDs, which signing enforces.

## Seerr status numbers are a contract

Two enums mirror Jellyseerr's `server/constants/media.ts`, with explicit raw
values pinned in `SeerrRequestStatusTests`. Adding a case means adding it to
those tests, which assert the numbers literally: a wrong value only shows as
a quietly wrong badge.

- `MediaRequestStatus`: `PENDING=1, APPROVED, DECLINED, FAILED, COMPLETED`.
  An unrecognised value is `.unknown`, never a real state. (Reading unknowns
  as pending once left completed requests saying "Pending Approval" forever.)
- `MediaStatus`: `UNKNOWN=1, PENDING, PROCESSING, PARTIALLY_AVAILABLE,
  AVAILABLE, BLOCKLISTED=6, DELETED=7`.

`BLOCKLISTED` and `DELETED` differ. Deleted media can be requested again and
reads "Not Requested". Blocklisted media cannot; an administrator with
`MANAGE_BLOCKLIST` gets an Unblock button, and since Jellyseerr drops the
media row with the blocklist entry, the reload shows the ordinary Request
button. Lagoon can lift a block but not add one.

`mediaInfo.downloadStatus` carries Radarr/Sonarr's queue, turning
"Processing" into "62%" or "Importing". **Deduplicate by `downloadId` before
aggregating**: Sonarr reports a season pack once per episode, each row with
the pack's full size. Each successful detail refresh commits status, progress,
ETA and any newly resolved Jellyfin item as one snapshot.

**Never show a request's own status alone.** Once granted, the media's
availability is what answers "can I watch this?". `SeerrRequestProgress`
combines them and reads `status4k` for a 4K request, which the library's
1080p copy does not satisfy.

## Discover's layout comes from the server

Discover opens on Home's `HeroSection`, then draws rails in the order the
**server owner** set. `settings/discover` returns Jellyseerr's slider list
(type numbers, an order, `title: null`), and `SeerrDiscoverLayout` maps them
onto rows, so re-ordering sliders in Jellyseerr re-orders Discover.

- Four of the twelve built-in types are skipped: `recentlyAdded` and
  `recentRequests` duplicate Home's rails and the Requests chip;
  `studios`/`networks` are web-client logo shelves the API does not serve.
- Unknown types are skipped too, so a newer Jellyseerr cannot break the page.
- If nothing renderable comes back, the layout falls back to Jellyseerr's
  default order minus those four.

**Every rail fetches itself.** `SeerrDiscoverRail` owns its state, so a dead
endpoint costs one rail, and rails below the fold cost nothing until near.

- A rail never renders at zero height while loading. A zero-height row in a
  `LazyVStack` is never realised, so its `.task` never runs.
- A rail that loads empty draws nothing. An empty watchlist is normal.
- Each rail is backed by a `SeerrCatalogSource`, which its heading also opens,
  so "see all" shows the same list.

Hero:

- `HeroSection` is generic over its route, so Home and Discover keep their
  route identities. Seerr serves **no logo artwork**, so Discover's hero
  always uses the title in type.
- `HeroCarouselSelection` stores the selected item ID, not an index, since a
  refresh can reorder slides. If that ID disappears, it falls back to the
  first item.
- iOS binds it to a paging ScrollView. tvOS handles Left/Right on one stable
  NavigationLink that wraps at the ends. Up/Down stays with the focus engine.
- Rotation is a cancellable seven-second view task, separate from refresh.
  Its identity includes item IDs, selected ID and whether cycling is allowed,
  so a manual pick restarts the interval. It runs only while the hero is
  visible, its root active and the scene foregrounded; touch scrolling, tvOS
  hero focus, Reduce Motion, VoiceOver and Home's playback pause it.
- Artwork and palette work checks cancellation before publishing, so a
  superseded slide's palette cannot land late.

TMDB:

- TMDB serves fixed image widths and answers 400 otherwise, so
  `SeerrClient.imageURL` snaps a width up to a real rendition. Request the
  width the layout needs.
- TMDB ids stay in the Seerr layer. An available title opens in Lagoon only
  after an exact `AnyProviderIdEquals=tmdb.{id}` lookup returns a Jellyfin
  item: no title/year guessing, and no Seerr detail in a Jellyfin stack under
  the wrong identity.
