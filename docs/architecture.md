# Architecture

## Project layout

One multiplatform app target (`Lagoon`) building for tvOS and iOS from a single
filesystem-synchronized group — new files are auto-included in the build. tvOS
is the primary platform; iOS shares every screen with platform-conditional
metrics (see [design-system.md](design-system.md)).

```
Lagoon/
  LagoonApp.swift          App entry; locks the app to dark mode
  Models/                  Jellyfin DTOs (nonisolated structs, defensive decoding)
  Networking/              JellyfinClient + extensions, keychain, image cache, palette
  ViewModels/              @Observable stores (SessionStore, HomeViewModel, …)
  Views/
    Components/            DesignSystem tokens, cards, rails, glow, state views
    Onboarding/            Server connect + sign-in (password / Quick Connect)
    Main/                  MainTabView + detail routing
    Home/                  Home screen, hero carousel
    Library/               Paged poster grid
    Discovery/             Seerr browse (hero + server-ordered rails), details, requests
    Detail/                Movie/episode + series detail
    Search/                The app's one search screen: library + Seerr, recents
    Player/                Unified sample-buffer playback + progress reporting
    Settings/
```

## State management

- `@Observable` everywhere (never `ObservableObject`/`@Published`). Screen
  view models are owned as `@State private var viewModel = …`. `SessionStore`
  owns the shared account context, including `SeerrSessionStore` and recent
  searches; `RootView` injects the session and its Seerr store.
- The Swift default actor isolation is `MainActor` (build setting). Model
  types are declared `nonisolated` so Codable conformances stay usable off
  the main actor.
- Loading is driven by `.task(id:)`, never `onAppear` + manual dedupe.

## Session lifecycle

`SessionStore` owns the connection state machine:

```
needsServer → needsSignIn → signedIn
                    ↑            ↓
              choosingAccount ←──┘
```

These are **states, not screens you navigate to** — `RootView` switches on
the phase with a crossfade. Persistence:

- UserDefaults: the `accounts` list (JSON), the active account id, and the
  server being connected to *right now* (the sign-in screen's subject,
  which is deliberately separate — a server only becomes an account once
  credentials actually work).
- Keychain (`KeychainStore`): one access token **per account**, keyed
  `token:{serverURL}|{userId}`, plus the per-install device id (survives
  reinstalls, which keeps the server's device list sane).

On launch `restore()` resumes the last active account. A single profile
therefore never sees the picker — `choosingAccount` appears only when no
account can be resumed, or when Settings asks for it. A missing token drops
to `needsSignIn`, no accounts at all to `needsServer`.

### Server reconciliation (HEL-135)

SwiftUI keeps the tab and navigation trees mounted when Lagoon goes into the
background. Returning to the app therefore does not re-run the screens'
ordinary `task` or `onAppear` work, which used to leave whatever Jellyfin had
changed in the meantime invisible until a cold launch.

`RootView` is the single scene-lifecycle observer. Each transition to
`ScenePhase.active` advances the environment's `ServerSyncState.generation`.
Server-backed screens observe that generation and reconcile only the state
they own. This remains the foreground path for every mounted screen:

- `MainTabView` refreshes the server's movie/show library tabs.
- Home refreshes watch-state rails, Recently Added, curated/plugin rows,
  collections, the hero values and Top Shelf without replacing the screen
  with a loading state. Failed primary rail requests keep their last good
  content.
- Home's Next Up contains only unstarted, unwatched episodes; in-progress
  episodes stay in Continue Watching. The series detail Play action still
  resumes, and autoplay keeps its separate episode cursor. Recently Added
  TV rails resolve episodes to real, deduplicated series records in latest
  child-addition order on both initial load and refresh. Failed parent lookups
  preserve that rail's last good snapshot; movie rails are unchanged.
- An open library re-reads however many items it has already loaded, which
  keeps focus and scroll identity instead of collapsing to page one.
- Open item, series and collection details re-read their item or episode
  state, and an open Jellyfin search repeats its current query.

The top-level browse destinations also use `ServerRefreshModifier`. It adds a
five-minute reconciliation cadence while Home, a movie/show library, or a
connected Discover screen is both visible and active. `MainTabView` passes the
selected tab and empty root navigation path explicitly, so SwiftUI's mounted
hidden tabs do not poll, a pushed detail does not refresh content behind it,
and timers stop in the background. Home also pauses its cadence while its
full-screen player is presented. Refreshes preserve the current content and
focus while requests are in flight, and transient failures retain the last
good content.

The same modifier owns the explicit platform affordance. On iOS it contributes
native pull-to-refresh to each browse scroll view. On tvOS, `MainTabView`
places one compact circular Refresh button at the top leading edge, beside but
outside the tab group. Its proximity to Home gives it a natural Left/Right
focus path from the tab bar. The button joins the focus graph only while the
top chrome is focused, so content's Up path still returns to the selected tab.
A quick move across the tabs can reach Refresh without selecting an
intermediate destination, and Down from Refresh is intercepted through
SwiftUI focus state and routed directly to Home's hero instead of falling back
into the tab bar. This avoids adding an otherwise empty toolbar row or putting
Refresh in the tab navigation itself.

Refresh shares the native tab bar's presentation offset: it scrolls offscreen
with the top chrome while the viewer moves down through Home and returns with
the tab bar, rather than becoming a sticky control over lower rails. It is not
hittable while that chrome is offscreen. Its UIKit measuring control remains
mounted but invisible, non-focusable, and inert while a detail is pushed; the
root `MainTabView` retains the last chrome offset and tracking pauses during
the transition, so returning to a deeply scrolled root cannot briefly place
Refresh over its content. While refreshing, the arrow itself rotates instead
of being replaced by an unrelated progress glyph; Reduce Motion keeps it
still. The button is routed to
`ServerSyncState.activeTarget`, so it can only refresh the visible Home,
library, or Discover destination.

Playback dismissal remains deliberately separate. The scene stays active
while a full-screen player is open, and HEL-132's targeted dismissal refresh
waits for the stop report before re-reading watch progress.

### Multiple accounts (HEL-38)

`StoredAccount` is one server+user pair. Its `id` is
`{serverURL}|{userId}` and never the display names, so renaming a server or
a user cannot orphan a token or duplicate an entry.

Adding an account is presented by `RootView` in `AddAccountView`, using a
separate `SessionStore(accountDraft: true)`. The active client and Seerr
connection stay mounted. `makeAccountDraft()` seeds only the active account's
server URL and name, so Add Account opens sign-in for that server without
copying its user or credentials. “Use Another Server” returns the draft to
server entry; without an active account, setup starts at server entry as before.
Each presentation creates a fresh draft, so cancelling a different-server
attempt does not change the next presentation's default. Draft connection
details and authentication results remain in memory until `finishAddingAccount`
persists the verified account and switches to it. Cancel invalidates pending
operations without logging out or changing the current account; changing the
draft server also invalidates responses from its previous connection.

Two rules that are easy to get wrong:

- **`migrateLegacySessionIfNeeded()` is load-bearing.** The single-slot
  layout kept the token under the bare account `"accessToken"` with the user
  id in UserDefaults. Without the one-time move, shipping this feature
  silently signs every existing install out — the one thing it must not do.
  It runs before anything else in `restore()` and is idempotent (guarded on
  the `accounts` key being absent).
- **Signing out forgets the account.** `logout` revokes the token
  server-side, so keeping the entry would leave a tile in the picker that
  can only fail. Other accounts are untouched, and the picker takes over
  when any remain.

Switching a valid remembered account costs no re-authentication. The
authoritative session transition synchronously clears outgoing Seerr state,
changes recent-search ownership, and invalidates Top Shelf work. Entering the
picker itself drops active access. `MainTabView` is identified by account so
navigation, details and search results are rebuilt for the next viewer.

`AccountLocalData` centralizes forgetting (HEL-141). It removes the Jellyfin
token, all Seerr cookies linked to that account (including previously configured
Seerr servers), cached libraries, recent searches, and subtitle, track and Home
preferences. Another account's data remains. The shared Seerr server address
is removed only when its last Jellyfin account is forgotten. Legacy global
recent searches are discarded because their owner cannot be determined.

Local forgetting happens before awaiting remote logout. Immutable client copies
perform Jellyfin/Seerr revocation so a late completion cannot affect the next
account. Keychain deletion/enumeration failures retain a persistent removal
marker, block credential restoration, and surface a root-level cleanup alert
with Retry. Relaunch retries cleanup; re-adding the same account must finish it
before saving a replacement token. See [HEL-141 validation](hel-141-account-privacy-validation.md).

### Seerr sessions

Seerr is an optional second service boundary, not part of `JellyfinClient`.
`SeerrSessionStore` shares the configured Seerr address between accounts on
the same Jellyfin server, but stores a separate opaque `connect.sid` cookie in
the Keychain for each Lagoon account. Jellyfin passwords are accepted only as
a one-time fallback and are never persisted; Jellyfin Quick Connect is the
primary sign-in path. Changing Lagoon accounts clears in-flight Seerr UI state
and restores only the matching cookie. Activation invalidates pending restores
and sign-ins before they can write into the next session. Automatic URLSession
cookie handling is disabled; only the explicitly selected account cookie is
sent. Failed cookie deletions are persistently quarantined and cannot restore;
a verified new sign-in replaces them.

Server address input is expanded by `SessionStore.candidateURLs(for:)`:
schemeless input probes https then http, plus `:8096` when no port was given;
LAN-looking hosts (IP literals, `.local`) probe http first so a hanging https
attempt can't stall them.

## Navigation

`MainTabView` has five stable tabs: Home, Discover, Library, Search, and
Settings (HEL-140). Each owns a `NavigationStack`; `ContentNavigationRoute`
provides stable item identity, routed by `ItemDetailRouter` — `.series` →
`SeriesDetailView`, everything else → `ItemDetailView`.

Library combines movies and series in one paged grid. All / Movies / Shows,
sort order, source library, genre, decade, unwatched, favorites, and 4K movie filters
are sent to Jellyfin on every page and refresh. `LibrarySelection` persists
per server/account; switching accounts recreates the browse state. Source
choices come from cached `LibraryTab` values until `userViews()` succeeds.
Only then can a deleted or incompatible saved source be cleared. Resolution
filtering is offered for Movies because series folders have no file resolution.
The Library filter appears only when multiple libraries share a media type;
a server with one movie and one show library needs only the media-type controls.
Redundant saved library filters become their equivalent media type so hiding
the menu does not leave an invisible constraint. Media type uses SwiftUI's
native segmented Picker on iOS and a menu Picker on tvOS. The tvOS menu
commits on Select, not focus, so reaching Sort or Filters cannot change
Movies to Shows or clear the movie-only 4K filter. Sort, Library, Genre, and
Decade are native single-selection Pickers inside menus; only the independent
watch-state, favorites, and 4K options use Toggles.
The native Decade filter derives non-overlapping ranges from Jellyfin's
`Items/Filters` year catalogue for the selected media type and source library,
not from the loaded page or a fixed calendar range. Gaps and undated titles
don't create choices; Genre and watch-state filters don't narrow the catalogue.
It sends ten production years through Jellyfin's `Years`
parameter for movies and series, so it applies across pagination and refresh,
not just to loaded posters. All Decades omits the constraint; Clear Filters
removes it along with the other filters. Older saved preferences remain valid.
Year and genre choices refresh with the Library's existing foreground,
periodic, manual, and return-navigation refresh lifecycle. Failed refreshes
retain the last good catalogue; year lists remain scoped to their library
and media type. Replacement requests supersede older responses even for the
same scope, including when a cancelled view task has not finished unwinding.
An unloaded or cancelled catalogue offers retry rather than claiming it is
empty. A saved decade stays clearable while loading/offline and is removed
only after a successful catalogue confirms it is absent. A saved genre stays
visible even if the refreshed catalogue no longer includes it.

`LibraryViewModel` discards responses from superseded queries, resets paging
on filter changes, and counts raw server rows for offsets while deduplicating
visible item IDs. Refresh re-fetches the loaded depth and retains the grid on
failure. The shared refresh target is `library.all`; sort/filter changes do
not create new refresh timers or replace the containing navigation stack.

`SearchView` is the app's single search location, presenting Jellyfin
library matches and Seerr catalogue matches as separate rails, with recent
terms (`RecentSearchStore`) below the keyboard when the field is empty. It is
a **tab of its own** rather than a fixture on Discover: on tvOS `.searchable`
draws a resident search field and full A-Z keyboard and expects to own the
screen, which is what the HIG means by "a search screen is a specialized
keyboard screen". Carrying one on Discover pushed that screen's content below
the fold (HEL-111), and HEL-36 had folded search in there while unifying the
two result sets. Two rules keep it working: `.searchable` goes on the
content, **not** the `NavigationStack`, or the field is drawn over pushed
detail pages; and the stack is a heterogeneous `NavigationPath`, because
results carry both route identities.

Search rails are previews, not the entire result set. See All opens
`ContentNavigationRoute.search(query)` or `SeerrNavigationRoute.search(query)`
in that same stack. Both routes use `SearchResultsView`, with a source-specific
fetch and native Load More Results action. Library cursors count raw server
items; Seerr cursors follow server page numbers. Filtering unsupported results
and deduplicating cards must not alter either cursor. Loading and retry retain
the existing grid and its next-page position. Seerr result identity includes
media type as well as TMDB ID. Changing the root search query clears its old
rail matches before the replacement request completes.

### Top Shelf is a full-screen carousel

`TVTopShelfCarouselItem` has **no `title` property**. It inherits only
`playAction`, `displayAction` and `setImageURL` from `TVTopShelfItem`, and
adds `contextTitle`, `summary`, `genre` and `duration`; the `title` that
`TVTopShelfSectionedItem` has does not exist here. **The name of the title
must therefore be part of the artwork**, which is also how the Apple TV app
does it (HEL-119).

So the app composes and the extension only reads. `TopShelfArtwork` draws the
backdrop, a scrim over the corner the text occupies, and then either
Jellyfin's logo art or the title set in type when a title has no logo — the
same fallback `TitleArtImage` makes. The results are written into the shared
App Group container as JPEGs at 3840x2160 and 1920x1080, and the extension
addresses them by file name resolved against **its own** container URL, never
an absolute path handed over by another process.

This keeps HEL-37's rule intact: the extension holds no credentials and does
no networking. It also fixes the old sizing, which asked Jellyfin for 800px
and set that one URL for both `.screenScale1x` and `.screenScale2x` — under
half the width a 16:9 item needs at @2x.

`TopShelfPublisher` owns one cancelable task and serializes the commit on the
main actor (HEL-141). Each operation captures its server/user and source URLs
and writes only into a unique `<account-hash>-<generation>` staging directory.
It commits `snapshot-v2.json` atomically after complete artwork is available,
then prunes old generations and notifies TVServices. A stale worker can delete
only its own directory. Switching, entering the picker, forgetting and logout
invalidate pending work and clear the shared snapshot/artwork.

A successful empty resume result clears the shelf. Network failures preserve
the last valid snapshot; an unrelated Next Up failure cannot prevent a successful
empty resume result from clearing. The extension reads only the new owned
manifest, validates artwork paths and rechecks its generation before returning
content. Old unowned shared-defaults payloads are retired on upgrade.

The carousel's two buttons must do two different things, so the `lagoon://`
contract has two hosts: `play/{id}` resumes and `item/{id}` opens the detail
page. Both require `owner=<account-hash>&generation=<UUID>`. The app checks the
active account and committed manifest before and after fetching the item.
Legacy unowned links and links from cleared/replaced snapshots are ignored.
`DeepLinkRouterTests` and `TopShelfPublisherTests` cover parsing and ownership.

#### Eight items, and why artwork is only composed once

The cap is **8**. The HIG's often-quoted "three to eight" is guidance for a
**scrolling banner**, a different layout style; neither the HIG nor
`TVTopShelfCarouselContent` puts any number on a carousel. Eight is taken
from the reason Apple gives for the banner ceiling, which does transfer: the
carousel is swipe-navigated and wraps, so a long one buries the title you
wanted.

Artwork is reused when account/server, title, source URLs and layout version
match the previous complete snapshot. Both images are copied into the new
generation before committing, so deletion of the outgoing generation cannot
break the replacement. Item IDs alone never identify cached artwork across
servers. Changed source image tags/URLs trigger composition again; a server
that changes pixels without changing its URL can still require cache recovery.

Metadata is rewritten on each successful publication to keep remaining time
and episode context current. No partial payload becomes visible while images
are being prepared; if every nonempty item's artwork fails, the prior snapshot
is retained. Settings exposes current snapshot and artwork counts and the last
publication result.

#### What the app derives, because the extension cannot

The extension has no library and no credentials, so anything needing Jellyfin
is resolved app-side and written into the snapshot:

- **`context`** is the carousel's one line of app-supplied text, above the
  title that lives in the artwork. It keeps `contextTitle`'s documented job
  ("why this item is being shown") and appends the identifying detail:
  an episode names the episode, because `railTitle` is the *series* for an
  episode and the shelf otherwise cannot say which one you are part way
  through; everything else says how much is left.
- **`mediaOptions`** are the 4K / HDR / Dolby Vision / Atmos badges tvOS draws
  itself, resolved from the media streams through the same `MediaQuality`
  thresholds the detail page and the player's Info panel use, so all three
  agree (HEL-46). `resumeItems` asks for `MediaSources` for exactly this
  reason. Nil rather than zero when the server sent no streams, so an empty
  set is never mistaken for "checked, and it is plain SDR".

`TopShelfPayloadTests` pins both, plus the JSON key names the extension
mirrors by hand.

**Top Shelf content only appears when the app is in the top row of the tvOS
Home screen.** An empty shelf usually means that, not a bug.

#### The extension target's product type is load-bearing (HEL-119)

`LagoonTopShelf` must be `com.apple.product-type.app-extension`. It was
`com.apple.product-type.tv-app-extension` for its first seven weeks, and
**no line of Lagoon code in the extension ever ran** in that time — on any
simulator or on hardware.

`tv-app-extension` is the legacy tvOS 9 TVML "TV App" extension. Apple's own
spec (`tvOSShared.xcspec`) gives it `LD_ENTRY_POINT = _TVExtensionMain`, so
the appex booted through TVServices' TVML entry point instead of
`_NSExtensionMain`, and never stood up the NSExtension XPC service that
`com.apple.tv-top-shelf` requires. The system then reported the plugin with
pid 0, failed to acquire a process assertion, killed it, and fell back to the
static brand image — which looks exactly like "the shelf is empty".

The tell is in the binary, and it is one command:

```sh
nm -m Lagoon.app/PlugIns/LagoonTopShelf.appex/LagoonTopShelf | grep -i extensionmain
# must say _NSExtensionMain (from Foundation), never _TVExtensionMain
```

Everything else was already correct and cost three sessions to re-verify:
entitlements, app group, `NSExtensionPointIdentifier`, principal class,
`CFBundlePackageType`, signing, embedding, architecture. Check the entry
point *first*. The `ENABLE_DEBUG_DYLIB = NO` difference against the reference app that
looked significant was a side effect of the same wrong product type, not a
second problem.

`tv-app-extension` also supplied `-framework TVServices` for free, so the
target now carries `OTHER_LDFLAGS = "-framework TVServices"` explicitly.

Nothing about Top Shelf needs configuration in App Store Connect. The only
portal requirement is the App Group on both App IDs, which signing already
enforces.

### Seerr status numbers are a contract

Two enums are wire contracts with Jellyseerr's `server/constants/media.ts`,
and both were wrong at once (HEL-115), so they are now spelled out with
explicit raw values and pinned in `SeerrRequestStatusTests`:

- `MediaRequestStatus` is `PENDING=1, APPROVED, DECLINED, FAILED, COMPLETED`.
  Lagoon knew only 1-3 and read anything else as *pending*, so a completed
  request — what an approved one becomes once the title arrives — claimed
  "Pending Approval" forever. An unrecognised value is now `.unknown`, never
  a real state.
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

`mediaInfo.downloadStatus` carries Radarr/Sonarr's queue, and it is what
turns a bare "Processing" into "62%" or "Importing" (HEL-116). **Deduplicate
by `downloadId` before aggregating**: a season pack is one download that
Sonarr reports once per episode, each row carrying the pack's full size, so
summing the rows claims ten times the bytes and a meaningless percentage.

Seerr media and request details keep that snapshot live while the page is
visible and the scene is active (HEL-136). Pending approval refreshes every
30 seconds; downloading and importing refresh every 10 seconds. The ordinary
page task performs the immediate first load, returning to the foreground
reconciles immediately, and the structured refresh task is cancelled on
backgrounding or navigation. Settled states stop scheduling altogether.
Requests are sequential, so a slow response cannot overlap the next one.
Each successful refresh commits status, progress, ETA, and any newly resolved
Jellyfin item as one snapshot; a transient failure keeps the last good page.
Static request metadata such as the quality-profile name is deliberately not
part of the polling loop.

**Never show a request's own status alone.** It answers "can I watch this?"
only until the request is granted; after that the media's availability does.
`SeerrRequestProgress` combines them, and reads `status4k` for a 4K request —
a 4K request is not satisfied by the 1080p copy already in the library.

Adding a case to either enum means adding it to those tests, which assert the
numbers literally: a wrong one is invisible until someone reads a badge that
is quietly lying.

### Discover's layout comes from the server

Discover opens on the same `HeroSection` Home uses and then draws its rails in
the order the **server owner** arranged them. `settings/discover` returns
Jellyseerr's own slider list — bare type numbers, an order, and `title: null`,
because the client is expected to name them — so `SeerrDiscoverLayout` maps
those numbers onto rows and Lagoon agrees with their Jellyseerr web page
instead of inventing a second layout. Re-ordering sliders there re-orders
Discover here.

Four of the twelve built-in types are deliberately skipped: `recentlyAdded`
and `recentRequests` duplicate Home's rails and the Requests chip, and
`studios`/`networks` are curated brand-logo shelves in Jellyseerr's web client
rather than anything the API serves. A type this build has never heard of is
skipped the same way, so a newer Jellyseerr cannot break the page. When
nothing renderable comes back — an older server, a hidden endpoint — the
layout falls back to Jellyseerr's default order minus those four.

**Every rail fetches itself.** `SeerrDiscoverRail` owns its own state, so one
dead endpoint costs one rail rather than the screen, and a rail below the fold
costs nothing until it is scrolled near. Two consequences worth knowing:

- A rail must never render to zero height while it is still loading. A
  zero-height row inside a `LazyVStack` is never realised, so its `.task` never
  runs and it stays empty forever — the placeholder is what gets the row built.
- A rail that loaded and came back *empty* draws nothing at all. An empty
  watchlist is the ordinary case, not a fault.

Every rail is backed by a `SeerrCatalogSource`, which is also what its heading
opens, so a "see all" always shows the same list the rail was drawn from.

`HeroSection` is generic over its navigation route and takes `HeroItem`s, so
Home feeds it Jellyfin items and Discover feeds it Seerr results without
either losing its own route identity. Seerr serves **no logo artwork
anywhere** — not in discover results, not in details — so Discover's hero
always falls back to the title in type, which is the same fallback
`TitleArtImage` makes for a Jellyfin item without a logo.

`HeroCarouselSelection` stores the selected item ID, not its array index.
Refreshes may reorder the slides without changing the title being viewed;
removing that ID falls back to the first available item, and an empty list
clears the selection. iOS binds this state to a native paging ScrollView;
tvOS handles Left/Right on one stable NavigationLink, wrapping at the ends.
Up/Down still belongs to the focus engine, and activation always opens the
visible item's route. VoiceOver gets the slide position and adjustable
next/previous actions.

Hero rotation is a cancellable seven-second view task, separate from server
refresh. Its identity includes item IDs, the selected ID, and whether cycling
is allowed, so manual selection restarts the interval. It runs only while the
hero is visible, its root destination is active, and the scene is foregrounded;
touch scrolling, tvOS hero focus, Reduce Motion, and VoiceOver pause it. Home
also gates it while presenting playback. Artwork/palette work checks cancellation
before publishing, preventing a superseded slide's palette from landing late.

TMDB serves a fixed set of image widths and answers 400 for anything else, so
`SeerrClient.imageURL` snaps a requested width up to a real rendition. Ask for
the width the layout needs; do not hand it an arbitrary number and assume it
resolves.

Discover and Search both use a heterogeneous `NavigationPath` with
`SeerrNavigationRoute` and `ContentNavigationRoute`, because their result
rails deliberately preserve their respective identities. TMDB ids remain in
the Seerr model layer; an available title is opened in Lagoon only after an
exact `AnyProviderIdEquals=tmdb.{id}` lookup returns a Jellyfin item. This
avoids title/year guesses and prevents a Seerr detail from entering a Jellyfin
stack under the wrong identity.

Playback is presented as `fullScreenCover(item:)` from whichever screen
started it; dismissal waits for the stop report and then triggers a targeted
re-fetch so resume state stays fresh (HEL-132).

There is one playback path: `SampleBufferPlayerEngine` demuxes with FFmpeg,
uses VideoToolbox as an internal HEVC decode stage, and presents video/audio
through AVFoundation sample-buffer renderers under one synchronizer. AVPlayer
and AVKit are not alternate playback engines. See [playback.md](playback.md).

## tvOS invariants (violating these regresses real bugs)

- A screen with **no focusable element makes the Menu button quit the app** —
  `LoadingView` is `.focusable()`, error views carry a button.
- The page-level vertical `ScrollView` uses `.scrollClipDisabled()` and rails
  use `Metrics.railTopPadding` / `Metrics.railBottomPadding` (48 / 96 pt on
  tvOS) inside their horizontal ScrollViews — the system
  focus lift draws outside card bounds and gets clipped flat otherwise.
- The episodes rail stays mounted across season switches (dimmed, not
  replaced by a spinner) so the layout doesn't collapse and yank focus.
- The hero's whole-banner NavigationLink lives **outside** the `.id()`-keyed
  transitioning label content, so focus survives slide changes. Left/Right
  changes the selected title, not the identity of the focused control.
- `.searchable` belongs only on `SearchView`, and on its **content** rather
  than its `NavigationStack`. On a browse screen it costs the top third of
  the display to a keyboard nobody asked for; on the stack it draws the field
  over pushed detail pages.
