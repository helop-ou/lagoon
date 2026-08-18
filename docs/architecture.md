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
    Detail/                Movie/episode + series detail
    Search/                Debounced library search
    Player/                Unified sample-buffer playback + progress reporting
    Settings/
```

## State management

- `@Observable` everywhere (never `ObservableObject`/`@Published`). Screen
  view models are owned as `@State private var viewModel = …`; the one shared
  object is `SessionStore`, injected with `.environment(session)`.
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

Server address input is expanded by `SessionStore.candidateURLs(for:)`:
schemeless input probes https then http, plus `:8096` when no port was given;
LAN-looking hosts (IP literals, `.local`) probe http first so a hanging https
attempt can't stall them.

## Navigation

`MainTabView` builds tabs dynamically: Home, one tab per `movies`/`tvshows`
library from `userViews()`, Search (`role: .search`), Settings. Each tab owns
its own `NavigationStack`; `MediaItem` is the navigation value
(Hashable by id), routed by `ItemDetailRouter` — `.series` →
`SeriesDetailView`, everything else → `ItemDetailView`.

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
