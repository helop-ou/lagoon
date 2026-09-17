# Architecture engineering notes

Engineering notes from the September 10, 2026 documentation cleanup. Start
with the [current architecture guide](../architecture.md). This records the
reasoning at the time, not a release checklist or proof of current hardware
acceptance.

## Session lifecycle

`SessionStore`'s phases are **states, not screens you navigate to**:
`RootView` crossfades between them, and persistence splits three ways.
UserDefaults holds the `accounts` list, the active account id, and the server
being connected to *right now* — the sign-in screen's subject, not yet an
account, since a server becomes one only once credentials work.
`KeychainStore` holds one access token **per account**, keyed
`token:{serverURL}|{userId}`, plus a per-install device id that survives
reinstalls so the server's device list stays sane.

`restore()` resumes the last active account, so a single profile never sees
the picker: `choosingAccount` appears only when no account can be resumed, or
Settings asks for it. A missing token drops to `needsSignIn`; no accounts at
all drops to `needsServer`.

### Server reconciliation

SwiftUI keeps the tab and navigation trees mounted when Lagoon backgrounds, so
returning does not re-run a screen's `task` or `onAppear` work. Whatever
Jellyfin changed meanwhile used to stay invisible until a cold launch.
`RootView` is the single scene-lifecycle observer: each transition to
`ScenePhase.active` advances `ServerSyncState.generation`, and server-backed
screens reconcile only the state they own.

Every reconciling surface follows the same discipline: keep current content
and focus while requests are in flight, discard superseded responses, and
retain the last good snapshot on failure — stated once here, not per screen.
Three reconciliations add rules beyond it:

- Home's hero always has a source. `HeroSelection` walks the view model's
  tiers in priority order: Recently Added, then Continue Watching and Next Up,
  then Favorites, then the plugin and curated rails, and last a random library
  sample, fetched once only when everything above is empty. The first tier
  holding an item with a backdrop and an overview supplies the whole hero;
  tiers are never mixed to reach six. On refresh, items already on screen stay
  wherever the server still returns them, and vacancies fill from the leading
  tier. Collections stay out entirely: their cards route to a collection page,
  the hero to an item.
- Home's Next Up holds only unstarted, unwatched episodes; in-progress
  episodes belong to Continue Watching. The series detail Play action still
  resumes, and autoplay keeps its own episode cursor. Recently Added TV rails
  resolve episodes to real, deduplicated series records in latest
  child-addition order, on initial load and on refresh alike.
- An open library re-reads however many items it already loaded, keeping focus
  and scroll identity instead of collapsing to page one.

`ServerRefreshModifier` adds a five-minute cadence and manual refresh control
to top-level browse destinations. `MainTabView` passes the selected tab and an
empty root navigation path explicitly, since SwiftUI's mounted hidden tabs
would otherwise poll and a pushed detail would refresh content behind it.

On tvOS that control is a compact circular Refresh button at the top leading
edge, beside but outside the tab group. Sitting next to Home gives it a
natural Left/Right path from the tab bar and avoids both an empty toolbar row
and a Refresh entry in the tab navigation. It joins the focus graph only while
the top chrome is focused, so Up from content still returns to the selected
tab, and Down falls through SwiftUI focus state to the tab bar rather than
Home's hero. Its UIKit measuring control stays mounted but inert while a
detail is pushed, and `MainTabView` retains the last chrome offset at root
scope — otherwise a control recreated on return reports the screen origin
first and flashes Refresh over a deeply scrolled root. While refreshing, the
arrow rotates instead of swapping for a progress glyph, and Reduce Motion
keeps it still. The button targets `ServerSyncState.activeTarget`, so it
refreshes only the visible destination.

Playback dismissal is separate: the scene stays active while a full-screen
player is open, and the targeted refresh waits for the stop report before
re-reading watch progress.

### Multiple accounts

`StoredAccount` is one server+user pair whose `id` is `{serverURL}|{userId}`,
never the display names, so renaming a server or a user cannot orphan a token
or duplicate an entry.

`RootView` presents `AddAccountView` on a separate `SessionStore(accountDraft:
true)` while the active client and Seerr connection stay mounted, and
`makeAccountDraft()` seeds only that account's server URL and name. Each
presentation builds a fresh draft, so cancelling a different-server attempt
cannot change the next presentation's default, and changing the draft server
invalidates responses from its previous connection. Nothing is persisted until
`finishAddingAccount` commits the verified account.

Two rules are easy to get wrong:

- **`migrateLegacySessionIfNeeded()` is load-bearing.** The single-slot layout
  kept the token under the bare account `"accessToken"`, with the user id in
  UserDefaults. Without the one-time move, shipping this feature would
  silently sign every existing install out — the one thing it must not do. It
  runs before anything else in `restore()` and is idempotent, guarded on the
  `accounts` key being absent.
- **Signing out forgets the account.** `logout` revokes the token server-side,
  so keeping the entry would leave a tile in the picker that can only fail.
  Other accounts are untouched, and the picker takes over when any remain.

Switching to a valid remembered account costs no re-authentication. The
authoritative session transition synchronously clears outgoing Seerr state,
changes recent-search ownership, and invalidates Top Shelf work; entering the
picker itself drops active access. `MainTabView` is identified by account, so
navigation, details and search results rebuild for the next viewer.

`AccountLocalData` centralizes forgetting: the Jellyfin token, every Seerr
cookie linked to that account including previously configured servers, cached
libraries, recent searches, and subtitle, track and Home preferences, leaving
other accounts untouched. The shared Seerr server address goes only with the
last Jellyfin account that used it, and legacy global recent searches are
discarded because their owner cannot be determined.

Local forgetting happens **before** awaiting remote logout, and immutable
client copies perform revocation so a late completion cannot reach the next
account. A Keychain deletion or enumeration failure leaves a persistent
removal marker that blocks credential restoration and raises a root-level
cleanup alert; re-adding the same account must finish that cleanup before a
replacement token is saved.

### Seerr sessions

Seerr is an optional second service boundary, separate from `JellyfinClient`.
`SeerrSessionStore` shares the configured address between accounts on the same
Jellyfin server but keeps a separate opaque `connect.sid` cookie in the
Keychain per Lagoon account. Quick Connect is the primary sign-in path; a
Jellyfin password works only as a one-time fallback and is never persisted.
Changing accounts clears in-flight Seerr UI state and restores only the
matching cookie, and activation invalidates pending restores and sign-ins
before they can write into the next session. Automatic URLSession cookie
handling is disabled, so only the explicitly selected cookie is ever sent, and
a failed cookie deletion is quarantined rather than left restorable.

## Navigation

Each of the five stable tabs owns a `NavigationStack`, and `ItemDetailRouter`
resolves a `ContentNavigationRoute`: `.series` → `SeriesDetailView`,
everything else → `ItemDetailView`. On tvOS playback is a
`fullScreenCover(item:)` on whichever screen started it; on iOS the screen
requests it and the tab root's single host presents it
([Playback](../playback.md#controls-and-presentation)).

Library combines movies and series in one paged grid. Every filter — media
type, sort order, source library, genre, decade, unwatched, favorites, 4K
movies — goes to Jellyfin on each page and refresh, not to loaded posters, so
filtering holds across pagination. Resolution filtering applies only to
Movies, since series folders have no file resolution. `LibrarySelection`
persists per server/account; source choices come from cached `LibraryTab`
values until `userViews()` succeeds, so a deleted or incompatible saved source
clears only against an authoritative list. The Library filter appears only
when multiple libraries share a media type, and a redundant saved library
filter becomes its equivalent media type, so hiding the menu cannot leave an
invisible constraint.

Media type is a native segmented Picker on iOS and a menu Picker on tvOS, and
**the tvOS menu commits on Select, not focus**: passing through it toward Sort
or Filters must not flip Movies to Shows or silently clear the movie-only 4K
filter. Only watch-state, favorites and 4K are independent Toggles; the rest
are single-selection Pickers.

The Decade filter derives non-overlapping ranges from Jellyfin's
`Items/Filters` year catalogue for the current media type and source library,
not from the loaded page or a fixed calendar range. Gaps and undated titles
create no choices, and the filter constrains queries through the `Years`
parameter. A saved decade stays clearable while loading or offline and drops
only once a successful catalogue confirms it is absent; a saved genre survives
a catalogue that no longer lists it.

`LibraryViewModel` resets paging on filter changes, counts raw server rows for
offsets, and deduplicates visible item IDs. Its refresh target is
`library.all`, so sort and filter changes add no refresh timer and leave the
navigation stack alone.

`SearchView` is the app's single search location, drawing Jellyfin library and
Seerr catalogue matches as separate rails, with recent terms
(`RecentSearchStore`) below the keyboard when the field is empty. It is a
**tab of its own**, not a fixture on Discover: tvOS `.searchable` draws a
resident field and full A-Z keyboard and expects to own the screen, what the
HIG calls "a search screen is a specialized keyboard screen." An earlier
version folded search into Discover and unified the two result sets, which
pushed content below the fold. Two rules keep it working: `.searchable` goes
on the content, **not** the `NavigationStack`, or the field draws over pushed
detail pages, and the stack is a heterogeneous `NavigationPath`, since results
carry both route identities.

Search rails are previews, not the whole result set; See All opens
`ContentNavigationRoute.search(query)` or `SeerrNavigationRoute.search(query)`
in the same stack, both rendered by `SearchResultsView`. Library cursors count
raw server items and Seerr cursors follow server page numbers, so filtering
unsupported results and deduplicating cards must not touch either cursor.
Seerr result identity includes media type as well as TMDB ID.

An **empty section offers no See All**. The preview runs the same query the
page runs, so the page behind that link only repeats the message, and a tvOS
page of nothing but text has no focus to hold — Menu quits the app instead of
going back. `SearchResultsView` keeps a focusable element in both empty
states: `LoadingView` for the first page, and a retry beside an empty result,
which rewinds the cursor rather than requesting a page past the end. The
status block itself stays unfocusable, so Down from the search field can carry
on to the Seerr section.

Settings → About carries a Legal section (audit A06). Its Acknowledgements
sheet follows the changelog sheet's tvOS pattern: no `NavigationStack`, its
own header/footer at a fixed `Metrics.modalPanelSize` instead of a pushed
page's title and background, and licence text broken into focusable paragraphs
rather than one long unfocusable block. Privacy Policy and Support rows appear
only once `LegalDestinations` carries a URL: iOS opens the link, tvOS shows
the address to type on another device. The sign-in screen's "About Lagoon"
action reaches the same section pre-login.

## Top Shelf is a full-screen carousel

`TVTopShelfCarouselItem` has **no `title` property**. It inherits only
`playAction`, `displayAction` and `setImageURL` from `TVTopShelfItem`, and
adds `contextTitle`, `summary`, `genre` and `duration`; the `title` that
`TVTopShelfSectionedItem` has does not exist here. **The title's name must
therefore live in the artwork**, which is also how the Apple TV app does it.

So the app composes and the extension only reads. `TopShelfArtwork` draws the
backdrop, a scrim over the text's corner, then either Jellyfin's logo art or,
when a title has none, the title set in type — the same fallback
`TitleArtImage` uses. Results are written into the shared App Group container
as JPEGs at 3840x2160 and 1920x1080; the extension addresses them by file name
resolved against **its own** container URL, never an absolute path handed over
by another process. That keeps the extension credential-free and network-free
by rule. It also fixes old sizing, which asked Jellyfin for 800px and used one
URL for both `.screenScale1x` and `.screenScale2x` — under half the width a
16:9 item needs at @2x.

`TopShelfPublisher` owns one cancelable task and serializes the commit on the
main actor. Each operation captures its server/user and source URLs, writes
only into a unique `<account-hash>-<generation>` staging directory, commits
`snapshot-v2.json` atomically once complete artwork exists, then prunes old
generations and notifies TVServices — so a stale worker deletes only its own
directory, and the extension never sees a half-written shelf. The extension
reads only that owned manifest, validating artwork paths and rechecking the
generation before returning content. Switching accounts, entering the picker,
forgetting and logout all invalidate pending work and clear the shared
snapshot. A successful empty resume clears the shelf, a network failure
preserves the last valid snapshot, and an unrelated Next Up failure cannot
block that clearing.

The carousel's two buttons do two different things, so the `lagoon://`
contract has two hosts: `play/{id}` resumes and `item/{id}` opens the detail
page. Both require `owner=<account-hash>&generation=<UUID>`; the app checks
the active account and committed manifest before and after fetching the item,
so legacy unowned links and links from cleared or replaced snapshots are
ignored. `DeepLinkRouterTests` and `TopShelfPublisherTests` cover parsing and
ownership.

### Eight items, and why artwork is only composed once

The cap is **8**. The HIG's often-quoted "three to eight" guides a **scrolling
banner**, a different layout style; neither the HIG nor
`TVTopShelfCarouselContent` puts any number on a carousel. Eight comes from
the reason Apple gives for the banner ceiling, which does transfer: the
carousel is swipe-navigated and wraps, so a long one buries the title you
wanted.

Artwork is reused when account/server, title, source URLs and layout version
all match the previous complete snapshot; both images are copied into the new
generation before committing, so deleting the outgoing generation cannot break
the replacement. Item IDs alone never identify cached artwork across servers.
Changed source image tags or URLs trigger composition again — a server that
changes pixels without changing its URL can still require cache recovery.
Metadata is rewritten on each successful publication to keep remaining time
and episode context current. No partial payload becomes visible while images
are being prepared, and if every nonempty item's artwork fails, the prior
snapshot is retained.

### What the app derives, because the extension cannot

The extension has no library and no credentials, so anything needing Jellyfin
is resolved app-side and written into the snapshot:

- **`context`** is the carousel's one line of app-supplied text, above the
  title that lives in the artwork. It keeps `contextTitle`'s documented job
  ("why this item is being shown") and appends the identifying detail: an
  episode names the episode, since `railTitle` is the *series* for an episode
  and the shelf otherwise cannot say which one you are part way through;
  everything else says how much is left.
- **`mediaOptions`** are the 4K / HDR / Dolby Vision / Atmos badges tvOS draws
  itself, resolved from the media streams through the same `MediaQuality`
  thresholds the detail page and the player's Info panel use, so all three
  agree. `resumeItems` asks for `MediaSources` for exactly this reason. They
  are nil rather than zero when the server sent no streams, so an empty set is
  never mistaken for "checked, and it is plain SDR".

`TopShelfPayloadTests` pins both, plus the JSON key names the extension
mirrors by hand.

**Top Shelf content only appears when the app is in the top row of the tvOS
Home screen.** An empty shelf usually means that, not a bug.

### The extension target's product type is load-bearing

`LagoonTopShelf` must be `com.apple.product-type.app-extension`. It was
`com.apple.product-type.tv-app-extension` for its first seven weeks, and **no
line of Lagoon code in the extension ever ran** in that time, on any simulator
or on hardware.

`tv-app-extension` is the legacy tvOS 9 TVML "TV App" extension. Apple's own
spec (`tvOSShared.xcspec`) gives it `LD_ENTRY_POINT = _TVExtensionMain`, so
the appex booted through TVServices' TVML entry point instead of
`_NSExtensionMain` and never stood up the NSExtension XPC service
`com.apple.tv-top-shelf` requires. The system reported the plugin with pid 0,
failed to acquire a process assertion, killed it, and fell back to the static
brand image, which looks exactly like "the shelf is empty".

The tell is in the binary — one command:

```sh
nm -m Lagoon.app/PlugIns/LagoonTopShelf.appex/LagoonTopShelf | grep -i extensionmain
# must say _NSExtensionMain (from Foundation), never _TVExtensionMain
```

Check the entry point *first*: entitlements, app group,
`NSExtensionPointIdentifier`, principal class, `CFBundlePackageType`, signing,
embedding and architecture were all already correct and cost three sessions to
re-verify. An `ENABLE_DEBUG_DYLIB = NO` difference against a working extension
elsewhere looked significant but was only a side effect of the same wrong
product type, not a second problem. `tv-app-extension` also supplied
`-framework TVServices` for free, so the target now carries `OTHER_LDFLAGS =
"-framework TVServices"` explicitly. Nothing else about Top Shelf is
configured in App Store Connect; the only portal requirement is the App Group
on both App IDs, which signing already enforces.

## Seerr status numbers are a contract

Two enums are wire contracts with Jellyseerr's `server/constants/media.ts`;
both were wrong at once, so they are now spelled out with explicit raw values
and pinned in `SeerrRequestStatusTests`:

- `MediaRequestStatus` is `PENDING=1, APPROVED, DECLINED, FAILED, COMPLETED`.
  Lagoon knew only 1-3 and read anything else as *pending*, so a completed
  request — what an approved one becomes once the title arrives — claimed
  "Pending Approval" forever. An unrecognised value is now `.unknown`, never a
  real state.
- `MediaStatus` is `UNKNOWN=1, PENDING, PROCESSING, PARTIALLY_AVAILABLE,
  AVAILABLE, BLOCKLISTED=6, DELETED=7`. Lagoon had `deleted = 6`, so a
  blocklisted title offered a Request button the server would refuse, and a
  deleted one fell into the unknown fallback and looked untouched.

`BLOCKLISTED` and `DELETED` are not interchangeable. Deleted media can be
requested afresh and reads as "Not Requested"; blocklisted media cannot, and
an administrator holding `MANAGE_BLOCKLIST` gets an Unblock button on the
detail page — Jellyseerr drops the media row with the blocklist entry, so the
reload afterwards shows the ordinary Request button. Lagoon can lift a block
but does not add one.

`mediaInfo.downloadStatus` carries Radarr/Sonarr's queue, turning a bare
"Processing" into "62%" or "Importing." **Deduplicate by `downloadId` before
aggregating**: a season pack is one download that Sonarr reports once per
episode, each row carrying the pack's full size, so summing the rows claims
ten times the bytes and a meaningless percentage. Each successful detail
refresh commits status, progress, ETA and any newly resolved Jellyfin item as
one snapshot.

**Never show a request's own status alone.** It answers "can I watch this?"
only until the request is granted; after that the media's availability does.
`SeerrRequestProgress` combines them, and reads `status4k` for a 4K request,
since a 4K request is not satisfied by the 1080p copy already in the library.

Adding a case to either enum means adding it to those tests too, since they
assert the numbers literally: a wrong one stays invisible until someone reads
a badge that is quietly lying.

## Discover's layout comes from the server

Discover opens on the same `HeroSection` Home uses, then draws its rails in
the order the **server owner** arranged them. `settings/discover` returns
Jellyseerr's own slider list — bare type numbers, an order, and `title: null`,
since the client is expected to name them — so `SeerrDiscoverLayout` maps
those numbers onto rows, and Lagoon agrees with the Jellyseerr web page
instead of inventing a second layout. Re-ordering sliders there re-orders
Discover here.

Four of the twelve built-in types are deliberately skipped: `recentlyAdded`
and `recentRequests` duplicate Home's rails and the Requests chip, and
`studios`/`networks` are curated brand-logo shelves in Jellyseerr's web
client, not anything the API serves. A type this build has never heard of is
skipped the same way, so a newer Jellyseerr cannot break the page. When
nothing renderable comes back — an older server, a hidden endpoint — the
layout falls back to Jellyseerr's default order minus those four.

**Every rail fetches itself.** `SeerrDiscoverRail` owns its state, so one dead
endpoint costs one rail, not the screen, and a rail below the fold costs
nothing until scrolled near. Two consequences:

- A rail must never render to zero height while loading. A zero-height row
  inside a `LazyVStack` is never realised, so its `.task` never runs and it
  stays empty forever — the placeholder is what gets the row built.
- A rail that loaded and came back *empty* draws nothing at all. An empty
  watchlist is the ordinary case, not a fault.

Every rail is backed by a `SeerrCatalogSource`, which is also what its heading
opens, so a "see all" always shows the same list the rail was drawn from.

`HeroSection` is generic over its navigation route, so Home feeds it Jellyfin
items and Discover feeds it Seerr results without either losing route
identity. Seerr serves **no logo artwork anywhere** — not in discover results,
not in details — so Discover's hero always falls back to the title in type,
the same fallback `TitleArtImage` makes for a Jellyfin item without a logo.

`HeroCarouselSelection` stores the selected item ID, not its array index,
since a refresh may reorder slides without changing the title being viewed;
removing that ID falls back to the first available item. iOS binds the state
to a native paging ScrollView, while tvOS handles Left/Right on one stable
NavigationLink that wraps at the ends, leaving Up/Down to the focus engine.

Hero rotation is a cancellable seven-second view task, separate from server
refresh. Its identity includes the item IDs, the selected ID and whether
cycling is allowed, so manual selection restarts the interval, and it runs
only while the hero is visible, its root destination active and the scene
foregrounded; touch scrolling, tvOS hero focus, Reduce Motion, VoiceOver and
Home's presented playback pause it. Artwork and palette work checks
cancellation before publishing, so a superseded slide's palette cannot land
late.

TMDB serves a fixed set of image widths and answers 400 for anything else, so
`SeerrClient.imageURL` snaps a requested width up to a real rendition. Ask for
the width the layout needs — never hand it an arbitrary number and assume it
resolves.

TMDB ids stay in the Seerr model layer: an available title opens in Lagoon
only after an exact `AnyProviderIdEquals=tmdb.{id}` lookup returns a Jellyfin
item, avoiding title/year guessing and keeping a Seerr detail from entering a
Jellyfin stack under the wrong identity.
