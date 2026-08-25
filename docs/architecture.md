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
  view models are owned as `@State private var viewModel = …`; the one shared
  objects are `SessionStore` and the account-scoped `SeerrSessionStore`,
  injected from `RootView`.
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

### Multiple accounts (HEL-38)

`StoredAccount` is one server+user pair. Its `id` is
`{serverURL}|{userId}` and never the display names, so renaming a server or
a user cannot orphan a token or duplicate an entry.

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

Switching costs no re-authentication and nothing else has to know: every
Jellyfin call is user-scoped, so Continue Watching and the rest follow from
the client being re-pointed.

### Seerr sessions

Seerr is an optional second service boundary, not part of `JellyfinClient`.
`SeerrSessionStore` shares the configured Seerr address between accounts on
the same Jellyfin server, but stores a separate opaque `connect.sid` cookie in
the Keychain for each Lagoon account. Jellyfin passwords are accepted only as
a one-time fallback and are never persisted; Jellyfin Quick Connect is the
primary sign-in path. Changing Lagoon accounts clears in-flight Seerr UI state
and restores only the matching cookie.

Server address input is expanded by `SessionStore.candidateURLs(for:)`:
schemeless input probes https then http, plus `:8096` when no port was given;
LAN-looking hosts (IP literals, `.local`) probe http first so a hanging https
attempt can't stall them.

## Navigation

`MainTabView` builds tabs dynamically: Home, Discover, one tab per
`movies`/`tvshows` library from `userViews()`, Search, and Settings. Each tab
owns its own `NavigationStack`; `MediaItem` is the content navigation value
(Hashable by id), routed by `ItemDetailRouter` — `.series` →
`SeriesDetailView`, everything else → `ItemDetailView`.

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

Composed artwork is cleaned on every publish and wiped on sign-out along with
the snapshot: a 4K still of what someone was watching is the same privacy
leak as the title list.

The carousel's two buttons must do two different things, so the `lagoon://`
contract has two hosts: `play/{id}` resumes and `item/{id}` opens the detail
page. `DeepLinkRouterTests` is the only thing holding that contract together
across the two targets, which cannot import each other.

**Top Shelf content only appears when the app is in the top row of the tvOS
Home screen.** An empty shelf usually means that, not a bug.

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
Nothing polls it — the value is a snapshot from whatever response the screen
already fetched.

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
started it; dismissal triggers a re-fetch so resume state stays fresh
(HomeView refreshes its progress rails in `onAppear`).

There is one playback path: `SampleBufferPlayerEngine` demuxes with FFmpeg,
uses VideoToolbox as an internal HEVC decode stage, and presents video/audio
through AVFoundation sample-buffer renderers under one synchronizer. AVPlayer
and AVKit are not alternate playback engines. See [playback.md](playback.md).

## tvOS invariants (violating these regresses real bugs)

- A screen with **no focusable element makes the Menu button quit the app** —
  `LoadingView` is `.focusable()`, error views carry a button.
- The page-level vertical `ScrollView` uses `.scrollClipDisabled()` and rails
  pad `top 40 / bottom 80` inside their horizontal ScrollViews — the system
  focus lift draws outside card bounds and gets clipped flat otherwise.
- The episodes rail stays mounted across season switches (dimmed, not
  replaced by a spinner) so the layout doesn't collapse and yank focus.
- The hero's CTA button lives **outside** the `.id()`-keyed transitioning
  subtree so focus survives slide changes.
- `.searchable` belongs only on `SearchView`, and on its **content** rather
  than its `NavigationStack`. On a browse screen it costs the top third of
  the display to a keyboard nobody asked for; on the stack it draws the field
  over pushed detail pages.
