# Jellyfin API

Verified against Jellyfin **10.11** (the public demo server) — the client uses
the user-scoped legacy routes (`Users/{id}/…`), which every server from 10.8
onward still answers, rather than the newer `/UserViews`-style routes.

## Wire format

- JSON keys are **PascalCase** both ways. `JellyfinClient` installs global
  key strategies (lowercase-first-letter on decode, uppercase-first-letter on
  encode) so model types stay camelCase with no per-field CodingKeys.
- No `Date` fields are decoded anywhere. Jellyfin emits .NET 7-digit
  fractional-second timestamps that `ISO8601DateFormatter` rejects; the UI
  only needs `ProductionYear`, so dates are simply not modeled.
- Positions and durations are .NET **ticks** (100 ns; 1 s = 10 000 000).
  Convert only through the `Ticks` helpers.
- Decoding is defensive: `decodeIfPresent` + defaults, unknown item types
  collapse to `.other`, unexpected shapes in optional relations (`userData`,
  `mediaSources`) degrade to nil instead of failing the whole list.

## Auth

Every request carries:

```
Authorization: MediaBrowser Client="Lagoon", Device="Apple TV",
               DeviceId="<keychain uuid>", Version="<app version>"[, Token="…"]
```

- `POST Users/AuthenticateByName` `{Username, Pw}` → `AccessToken` + `User`.
- **Quick Connect**: `GET QuickConnect/Enabled` → if true, `POST
  QuickConnect/Initiate` (needs the MediaBrowser header, no token) returns
  `{Code, Secret}`; poll `GET QuickConnect/Connect?secret=` every 2 s until
  `Authenticated`, then `POST Users/AuthenticateWithQuickConnect {Secret}`.
  Expiry surfaces as an error on the poll — reset the UI, don't retry the
  same secret.
- `POST Sessions/Logout` on sign-out invalidates the token server-side.
- Pre-auth server validation hits `GET System/Info/Public` (no header
  needed); its `ServerName` seeds the sign-in screen.

## Library endpoints

| Purpose | Endpoint | Quirk |
|---|---|---|
| Libraries | `Users/{uid}/Views` | filter `CollectionType` to `movies`/`tvshows` |
| Browse/search | `Users/{uid}/Items` | `ParentId`, `IncludeItemTypes`, `SearchTerm`, paged via `StartIndex`/`Limit` |
| Item detail | `Users/{uid}/Items/{id}` | re-fetched after playback for fresh `UserData` |
| Continue watching | `Users/{uid}/Items/Resume` | `MediaTypes=Video` |
| Next up | `Shows/NextUp?UserId=` | |
| Recently added | `Users/{uid}/Items/Latest` | **returns a bare array**, not an `Items` wrapper |
| Seasons/episodes | `Shows/{seriesId}/Seasons` / `…/Episodes?SeasonId=` | |

List calls pass `Fields=Overview,Genres,…` (`JellyfinClient.defaultFields`)
because the server omits those from list payloads by default.

## Images

`imageURL(for:kind:maxWidth:)` builds `Items/{id}/Images/{type}` URLs with the
item's image **tag** (cache-buster) and falls back through parent artwork the
way official clients do: episode primary → series poster
(`SeriesPrimaryImageTag`), own backdrop → `ParentBackdropItemId`'s backdrop.
`kind: .thumb` prefers episode stills (their Primary slot), then `Thumb`,
then backdrops.

## App Transport Security

`LagoonInfo.plist` sets `NSAllowsArbitraryLoads` because home-LAN Jellyfin
servers are commonly plain http on `:8096`. The trade-off is deliberate and
matches Infuse/Swiftfin behavior; revisit if the app ever ships to the App
Store (scope to `NSAllowsLocalNetworking` + declared domains instead).

## Home Screen Sections plugin (HEL-47)

Optional server plugin; a server without it 404s the whole route and Home
falls back to Lagoon's own rails.

- `GET HomeScreen/Sections?userId=` — the section **catalogue**.
- `GET HomeScreen/Section/{sectionKey}?userId=` — that section's items,
  shaped as an ordinary `ItemsPage`.

**The catalogue is not a layout, and this is the whole difficulty.** Probed
against a real install (2026-08-18): it returns all 28 section types the
plugin knows — Books, Music, Jellyseerr rows included — for a
movies-and-TV-only library, with `OrderIndex` 999 and `Limit` 1 on every
one. It does *not* narrow to what the admin enabled, and the enabled set is
not readable anywhere: `HomeScreen/UserSettings`, `HomeScreen/Settings`,
`HomeScreen/Config` and `HomeScreen/Users/{id}/Settings` all 404, and core
`DisplayPreferences/usersettings` carries no `homesection*` keys.

So a client cannot honour the server's intended layout, and rendering the
catalogue wholesale is actively wrong: the same server offers
`ContinueWatching`, `NextUp` **and** `ContinueWatchingNextUp`, plus
`LatestMovies` alongside `RecentlyAddedMovies` — Home would show the same
films three times. `HomeViewModel.nativelyCoveredSections` therefore drops
every section Lagoon already draws and appends only the remainder.

Consequence worth knowing before testing: on a plain movies/TV server this
feature correctly renders **nothing**, because every non-empty section is
one Lagoon already has. It earns its keep on servers with Jellyseerr
requests, My List, Discover or custom collection sections.

Cost is low enough to fetch eagerly: all 28 sections resolve in ~1.8 s
concurrently, empties answering in ~0.1 s each.

## Testing without a home server

The public demo (`https://demo.jellyfin.org/stable`, user `demo`, empty
password) exercises the full flow including Quick Connect discovery and
playback, and is what the MVP was verified against end-to-end.
