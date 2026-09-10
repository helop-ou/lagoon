# Architecture engineering notes

Detailed implementation rationale and dated investigations retained during the
September 10, 2026 documentation cleanup. Start with the [current architecture guide](../architecture.md).
Earlier experiments, ticket states, and measurements below describe their recorded
revision; they are not a release checklist or proof of current hardware acceptance.

## Session lifecycle

`SessionStore`'s phases are **states, not screens you navigate to** — `RootView`
crossfades between them — and its persistence splits three ways on purpose.
UserDefaults holds the `accounts` list and the active account id, plus the
server being connected to *right now*: that is the sign-in screen's subject and
deliberately not an account, because a server becomes an account only once
credentials actually work. The Keychain (`KeychainStore`) holds one access token
**per account**, keyed `token:{serverURL}|{userId}`, and the per-install device
id, which survives reinstalls so the server's device list stays sane.

`restore()` resumes the last active account, so a single profile never sees the
picker: `choosingAccount` appears only when no account can be resumed, or when
Settings asks for it. A missing token drops to `needsSignIn`; no accounts at all
to `needsServer`.

### Server reconciliation (HEL-135)

SwiftUI keeps the tab and navigation trees mounted when Lagoon goes into the
background, so returning to the app does not re-run the screens' ordinary `task`
or `onAppear` work, and whatever Jellyfin changed in the meantime used to stay
invisible until a cold launch. `RootView` is therefore the single
scene-lifecycle observer: each transition to `ScenePhase.active` advances
`ServerSyncState.generation`, and server-backed screens reconcile only the state
they own.

Every reconciling surface follows the same discipline — keep current content and
focus while requests are in flight, discard superseded responses, retain the
last good snapshot on failure — so it is stated once here instead of per screen.
Three reconciliations have rules beyond it:

- Home's hero always has a source (HEL-147). `HeroSelection` walks the view
  model's tiers in priority order — Recently Added, then Continue Watching and
  Next Up, then Favorites, then the plugin and curated rails, and last a random
  library sample fetched once and only when everything above is empty — and the
  first tier holding an item with a backdrop and an overview supplies the whole
  hero. Tiers are never mixed to reach six. On refresh, items already on screen
  stay wherever the server still returns them and vacancies fill from the
  leading tier. Collections stay out entirely: their cards route to a collection
  page, and the hero routes to an item.
- Home's Next Up contains only unstarted, unwatched episodes; in-progress
  episodes belong to Continue Watching. The series detail Play action still
  resumes, and autoplay keeps its separate episode cursor. Recently Added TV
  rails resolve episodes to real, deduplicated series records in latest
  child-addition order, on initial load and on refresh alike.
- An open library re-reads however many items it has already loaded, which keeps
  focus and scroll identity instead of collapsing to page one.

`ServerRefreshModifier` adds the five-minute cadence and the manual affordance
to top-level browse destinations. `MainTabView` passes the selected tab and the
empty root navigation path explicitly, because SwiftUI's mounted hidden tabs
would otherwise poll and a pushed detail would refresh the content behind it.

On tvOS that affordance is one compact circular Refresh button at the top
leading edge, beside but outside the tab group: its proximity to Home gives it a
natural Left/Right path from the tab bar, which is what avoids both an otherwise
empty toolbar row and a Refresh entry in the tab navigation itself. It joins the
focus graph only while the top chrome is focused, so content's Up path still
returns to the selected tab, and Down is intercepted through SwiftUI focus state
because the default fallback is the tab bar rather than Home's hero. Its UIKit
measuring control stays mounted but inert while a detail is pushed and
`MainTabView` retains the last chrome offset at root scope, because a control
recreated on return reports the screen origin first and flashes Refresh over a
deeply scrolled root. While refreshing, the arrow rotates rather than being
swapped for an unrelated progress glyph, and Reduce Motion keeps it still. The
button targets `ServerSyncState.activeTarget`, so it can only refresh the
visible destination.

Playback dismissal is deliberately separate: the scene stays active while a
full-screen player is open, and HEL-132's targeted refresh waits for the stop
report before re-reading watch progress.

### Multiple accounts (HEL-38)

`StoredAccount` is one server+user pair whose `id` is `{serverURL}|{userId}` and
never the display names, so renaming a server or a user cannot orphan a token or
duplicate an entry.

`RootView` presents `AddAccountView` on a separate `SessionStore(accountDraft: true)`
while the active client and Seerr connection stay mounted, and
`makeAccountDraft()` seeds only that account's server URL and name. Each
presentation builds a fresh draft, so cancelling a different-server attempt
cannot change the next presentation's default, and changing the draft server
invalidates responses from its previous connection. Nothing is persisted until
`finishAddingAccount` commits the verified account.

Two rules that are easy to get wrong:

- **`migrateLegacySessionIfNeeded()` is load-bearing.** The single-slot layout
  kept the token under the bare account `"accessToken"` with the user id in
  UserDefaults. Without the one-time move, shipping this feature silently signs
  every existing install out — the one thing it must not do. It runs before
  anything else in `restore()` and is idempotent (guarded on the `accounts` key
  being absent).
- **Signing out forgets the account.** `logout` revokes the token server-side,
  so keeping the entry would leave a tile in the picker that can only fail.
  Other accounts are untouched, and the picker takes over when any remain.

Switching to a valid remembered account costs no re-authentication. The
authoritative session transition synchronously clears outgoing Seerr state,
changes recent-search ownership, and invalidates Top Shelf work; entering the
picker itself drops active access. `MainTabView` is identified by account, so
navigation, details and search results are rebuilt for the next viewer.

`AccountLocalData` centralizes forgetting (HEL-141): the Jellyfin token, every
Seerr cookie linked to that account including previously configured servers,
cached libraries, recent searches, and subtitle, track and Home preferences,
leaving other accounts untouched. The shared Seerr server address goes only with
the last Jellyfin account that used it, and legacy global recent searches are
discarded because their owner cannot be determined. Local forgetting happens
**before** awaiting remote logout, and immutable client copies perform
revocation so a late completion cannot reach the next account. A Keychain
deletion or enumeration failure leaves a persistent removal marker that blocks
credential restoration and raises a root-level cleanup alert; re-adding the same
account must finish that cleanup before a replacement token is saved. See
[HEL-141 validation](../archive/hel-141-account-privacy-validation.md).

### Seerr sessions

Seerr is an optional second service boundary, not part of `JellyfinClient`.
`SeerrSessionStore` shares the configured address between accounts on the same
Jellyfin server but keeps a separate opaque `connect.sid` cookie in the Keychain
per Lagoon account. Quick Connect is the primary sign-in path; a Jellyfin
password is accepted only as a one-time fallback and never persisted. Changing
accounts clears in-flight Seerr UI state and restores only the matching cookie,
and activation invalidates pending restores and sign-ins before they can write
into the next session. Automatic URLSession cookie handling is disabled so only
the explicitly selected cookie is ever sent, and a failed cookie deletion is
quarantined rather than left restorable.

## Navigation

Each of the five stable tabs (HEL-140) owns a `NavigationStack`, and
`ItemDetailRouter` resolves a `ContentNavigationRoute` — `.series` →
`SeriesDetailView`, everything else → `ItemDetailView`. Playback is a
`fullScreenCover(item:)` on whichever screen started it.

Library combines movies and series in one paged grid. Every filter — media type,
sort order, source library, genre, decade, unwatched, favorites, 4K movies — is
sent to Jellyfin on each page and refresh rather than applied to loaded posters,
which is what makes it hold across pagination. Resolution filtering is offered
only for Movies because series folders have no file resolution.
`LibrarySelection` persists per server/account, and source choices come from
cached `LibraryTab` values until `userViews()` succeeds, so a deleted or
incompatible saved source is cleared only against an authoritative list. The
Library filter appears only when multiple libraries share a media type, and a
redundant saved library filter becomes its equivalent media type so hiding the
menu cannot leave an invisible constraint.

Media type is a native segmented Picker on iOS and a menu Picker on tvOS, and
**the tvOS menu commits on Select, not focus**: passing through it on the way to
Sort or Filters must not flip Movies to Shows or silently clear the movie-only
4K filter. Only the independent watch-state, favorites and 4K options are
Toggles; the rest are single-selection Pickers.

The Decade filter derives non-overlapping ranges from Jellyfin's `Items/Filters`
year catalogue for the current media type and source library rather than from
the loaded page or a fixed calendar range, so gaps and undated titles create no
choices, and it constrains queries through the `Years` parameter. A saved decade
stays clearable while loading or offline and is dropped only once a successful
catalogue confirms it is absent; a saved genre survives a catalogue that no
longer lists it.

`LibraryViewModel` resets paging on filter changes and counts raw server rows
for offsets while deduplicating visible item IDs. Its refresh target is
`library.all`, so sort and filter changes add no refresh timer and do not
replace the navigation stack.

`SearchView` is the app's single search location, drawing Jellyfin library and
Seerr catalogue matches as separate rails with recent terms (`RecentSearchStore`)
below the keyboard while the field is empty. It is a **tab of its own** rather
than a fixture on Discover because on tvOS `.searchable` draws a resident field
and full A-Z keyboard and expects to own the screen — what the HIG means by "a
search screen is a specialized keyboard screen". HEL-36 folded search into
Discover while unifying the two result sets, and it pushed that screen's content
below the fold (HEL-111). Two rules keep it working: `.searchable` goes on the
content, **not** the `NavigationStack`, or the field is drawn over pushed detail
pages; and the stack is a heterogeneous `NavigationPath`, because results carry
both route identities.

Search rails are previews, not the whole result set; See All opens
`ContentNavigationRoute.search(query)` or `SeerrNavigationRoute.search(query)`
in the same stack, both rendered by `SearchResultsView`. Library cursors count
raw server items and Seerr cursors follow server page numbers, so filtering
unsupported results and deduplicating cards must not touch either cursor. Seerr
result identity includes media type as well as TMDB ID.

Settings → About carries a Legal section (HEL-143, audit A06) whose
Acknowledgements sheet follows the changelog sheet's tvOS pattern: no
`NavigationStack`, its own header/footer at a fixed `Metrics.modalPanelSize`
instead of the title and background a pushed page would give it, and licence
text broken into focusable paragraphs rather than one long unfocusable block.
Privacy Policy and Support rows appear only once `LegalDestinations` carries a
URL; iOS opens the link, tvOS shows the address to type on another device. The
sign-in screen's "About Lagoon" action reaches the same section pre-login.

## Top Shelf is a full-screen carousel

`TVTopShelfCarouselItem` has **no `title` property**. It inherits only
`playAction`, `displayAction` and `setImageURL` from `TVTopShelfItem`, and adds
`contextTitle`, `summary`, `genre` and `duration`; the `title` that
`TVTopShelfSectionedItem` has does not exist here. **The name of the title must
therefore be part of the artwork**, which is also how the Apple TV app does it
(HEL-119).

So the app composes and the extension only reads. `TopShelfArtwork` draws the
backdrop, a scrim over the corner the text occupies, and then either Jellyfin's
logo art or the title set in type when a title has no logo — the same fallback
`TitleArtImage` makes. The results are written into the shared App Group
container as JPEGs at 3840x2160 and 1920x1080, and the extension addresses them
by file name resolved against **its own** container URL, never an absolute path
handed over by another process. This keeps HEL-37's rule intact: the extension
holds no credentials and does no networking. It also fixes the old sizing, which
asked Jellyfin for 800px and set that one URL for both `.screenScale1x` and
`.screenScale2x` — under half the width a 16:9 item needs at @2x.

`TopShelfPublisher` owns one cancelable task and serializes the commit on the
main actor (HEL-141). Each operation captures its server/user and source URLs
and writes only into a unique `<account-hash>-<generation>` staging directory,
commits `snapshot-v2.json` atomically once complete artwork exists, then prunes
old generations and notifies TVServices — so a stale worker can delete only its
own directory, and the extension never sees a half-written shelf. On its side
the extension reads only that owned manifest, validating artwork paths and
rechecking the generation before it returns content. Switching
accounts, entering the picker, forgetting and logout invalidate pending work and
clear the shared snapshot. A successful empty resume result clears the shelf
while a network failure preserves the last valid snapshot, and an unrelated Next
Up failure cannot block that clearing.

The carousel's two buttons must do two different things, so the `lagoon://`
contract has two hosts: `play/{id}` resumes and `item/{id}` opens the detail
page. Both require `owner=<account-hash>&generation=<UUID>`, and the app checks
the active account and committed manifest before and after fetching the item, so
legacy unowned links and links from cleared or replaced snapshots are ignored.
`DeepLinkRouterTests` and `TopShelfPublisherTests` cover parsing and ownership.

### Eight items, and why artwork is only composed once

The cap is **8**. The HIG's often-quoted "three to eight" is guidance for a
**scrolling banner**, a different layout style; neither the HIG nor
`TVTopShelfCarouselContent` puts any number on a carousel. Eight is taken from
the reason Apple gives for the banner ceiling, which does transfer: the carousel
is swipe-navigated and wraps, so a long one buries the title you wanted.

Artwork is reused when account/server, title, source URLs and layout version all
match the previous complete snapshot, and both images are copied into the new
generation before committing, so deleting the outgoing generation cannot break
the replacement. Item IDs alone never identify cached artwork across servers.
Changed source image tags or URLs trigger composition again; a server that
changes pixels without changing its URL can still require cache recovery.
Metadata is rewritten on each successful publication to keep remaining time and
episode context current. No partial payload becomes visible while images are
being prepared, and if every nonempty item's artwork fails the prior snapshot is
retained.

### What the app derives, because the extension cannot

The extension has no library and no credentials, so anything needing Jellyfin is
resolved app-side and written into the snapshot:

- **`context`** is the carousel's one line of app-supplied text, above the title
  that lives in the artwork. It keeps `contextTitle`'s documented job ("why this
  item is being shown") and appends the identifying detail: an episode names the
  episode, because `railTitle` is the *series* for an episode and the shelf
  otherwise cannot say which one you are part way through; everything else says
  how much is left.
- **`mediaOptions`** are the 4K / HDR / Dolby Vision / Atmos badges tvOS draws
  itself, resolved from the media streams through the same `MediaQuality`
  thresholds the detail page and the player's Info panel use, so all three agree
  (HEL-46). `resumeItems` asks for `MediaSources` for exactly this reason. They
  are nil rather than zero when the server sent no streams, so an empty set is
  never mistaken for "checked, and it is plain SDR".

`TopShelfPayloadTests` pins both, plus the JSON key names the extension mirrors
by hand.

**Top Shelf content only appears when the app is in the top row of the tvOS Home
screen.** An empty shelf usually means that, not a bug.

### The extension target's product type is load-bearing (HEL-119)

`LagoonTopShelf` must be `com.apple.product-type.app-extension`. It was
`com.apple.product-type.tv-app-extension` for its first seven weeks, and **no
line of Lagoon code in the extension ever ran** in that time — on any simulator
or on hardware.

`tv-app-extension` is the legacy tvOS 9 TVML "TV App" extension. Apple's own
spec (`tvOSShared.xcspec`) gives it `LD_ENTRY_POINT = _TVExtensionMain`, so the
appex booted through TVServices' TVML entry point instead of `_NSExtensionMain`
and never stood up the NSExtension XPC service that `com.apple.tv-top-shelf`
requires. The system then reported the plugin with pid 0, failed to acquire a
process assertion, killed it, and fell back to the static brand image — which
looks exactly like "the shelf is empty".

The tell is in the binary, and it is one command:

```sh
nm -m Lagoon.app/PlugIns/LagoonTopShelf.appex/LagoonTopShelf | grep -i extensionmain
# must say _NSExtensionMain (from Foundation), never _TVExtensionMain
```

Check the entry point *first*: entitlements, app group,
`NSExtensionPointIdentifier`, principal class, `CFBundlePackageType`, signing,
embedding and architecture were all already correct and cost three sessions to
re-verify, and the `ENABLE_DEBUG_DYLIB = NO` difference against the reference app that
looked significant was a side effect of the same wrong product type rather than
a second problem. `tv-app-extension` also supplied `-framework TVServices` for
free, so the target now carries `OTHER_LDFLAGS = "-framework TVServices"`
explicitly. Nothing else about Top Shelf is configured in App Store Connect; the
only portal requirement is the App Group on both App IDs, which signing already
enforces.

## Seerr status numbers are a contract

Two enums are wire contracts with Jellyseerr's `server/constants/media.ts`, and
both were wrong at once (HEL-115), so they are now spelled out with explicit raw
values and pinned in `SeerrRequestStatusTests`:

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
requested afresh and reads as "Not Requested"; blocklisted media cannot, and an
administrator holding `MANAGE_BLOCKLIST` gets an Unblock button on the detail
page — Jellyseerr drops the media row with the blocklist entry, so the reload
afterwards shows the ordinary Request button. Lagoon can lift a block but does
not add one.

`mediaInfo.downloadStatus` carries Radarr/Sonarr's queue, and it is what turns a
bare "Processing" into "62%" or "Importing" (HEL-116). **Deduplicate by
`downloadId` before aggregating**: a season pack is one download that Sonarr
reports once per episode, each row carrying the pack's full size, so summing the
rows claims ten times the bytes and a meaningless percentage. Each successful
detail refresh (HEL-136) commits status, progress, ETA and any newly resolved
Jellyfin item as one snapshot.

**Never show a request's own status alone.** It answers "can I watch this?" only
until the request is granted; after that the media's availability does.
`SeerrRequestProgress` combines them, and reads `status4k` for a 4K request — a
4K request is not satisfied by the 1080p copy already in the library.

Adding a case to either enum means adding it to those tests, which assert the
numbers literally: a wrong one is invisible until someone reads a badge that is
quietly lying.

## Discover's layout comes from the server

Discover opens on the same `HeroSection` Home uses and then draws its rails in
the order the **server owner** arranged them. `settings/discover` returns
Jellyseerr's own slider list — bare type numbers, an order, and `title: null`,
because the client is expected to name them — so `SeerrDiscoverLayout` maps
those numbers onto rows and Lagoon agrees with their Jellyseerr web page instead
of inventing a second layout. Re-ordering sliders there re-orders Discover here.

Four of the twelve built-in types are deliberately skipped: `recentlyAdded` and
`recentRequests` duplicate Home's rails and the Requests chip, and
`studios`/`networks` are curated brand-logo shelves in Jellyseerr's web client
rather than anything the API serves. A type this build has never heard of is
skipped the same way, so a newer Jellyseerr cannot break the page. When nothing
renderable comes back — an older server, a hidden endpoint — the layout falls
back to Jellyseerr's default order minus those four.

**Every rail fetches itself.** `SeerrDiscoverRail` owns its state, so one dead
endpoint costs one rail rather than the screen and a rail below the fold costs
nothing until it is scrolled near. Two consequences:

- A rail must never render to zero height while it is still loading. A
  zero-height row inside a `LazyVStack` is never realised, so its `.task` never
  runs and it stays empty forever — the placeholder is what gets the row built.
- A rail that loaded and came back *empty* draws nothing at all. An empty
  watchlist is the ordinary case, not a fault.

Every rail is backed by a `SeerrCatalogSource`, which is also what its heading
opens, so a "see all" always shows the same list the rail was drawn from.

`HeroSection` is generic over its navigation route, so Home feeds it Jellyfin
items and Discover feeds it Seerr results without either losing its route
identity. Seerr serves **no logo artwork anywhere** — not in discover results,
not in details — so Discover's hero always falls back to the title in type, the
same fallback `TitleArtImage` makes for a Jellyfin item without a logo.

`HeroCarouselSelection` stores the selected item ID, not its array index,
because a refresh may reorder the slides without changing the title being
viewed; removing that ID falls back to the first available item. iOS binds the
state to a native paging ScrollView, while tvOS handles Left/Right on one stable
NavigationLink that wraps at the ends, leaving Up/Down to the focus engine.

Hero rotation is a cancellable seven-second view task, separate from server
refresh. Its identity includes the item IDs, the selected ID and whether cycling
is allowed, so manual selection restarts the interval, and it runs only while
the hero is visible, its root destination active and the scene foregrounded;
touch scrolling, tvOS hero focus, Reduce Motion, VoiceOver and Home's presented
playback pause it. Artwork and palette work checks cancellation before
publishing, so a superseded slide's palette cannot land late.

TMDB serves a fixed set of image widths and answers 400 for anything else, so
`SeerrClient.imageURL` snaps a requested width up to a real rendition. Ask for
the width the layout needs; do not hand it an arbitrary number and assume it
resolves.

TMDB ids stay in the Seerr model layer: an available title opens in Lagoon only
after an exact `AnyProviderIdEquals=tmdb.{id}` lookup returns a Jellyfin item.
That avoids title/year guessing and keeps a Seerr detail from entering a
Jellyfin stack under the wrong identity.
