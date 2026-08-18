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
| Next up | `Shows/NextUp?UserId=` | rail only — **never** for autoplay, see below |
| Recently added | `Users/{uid}/Items/Latest` | **returns a bare array**, not an `Items` wrapper |
| Seasons/episodes | `Shows/{seriesId}/Seasons` / `…/Episodes?SeasonId=` | |
| The episode after this one | `Shows/{seriesId}/Episodes?startItemId=&Limit=2` | index 1 is the next one (HEL-66) |

List calls pass `Fields=Overview,Genres,…,OriginalLanguage`
(`JellyfinClient.defaultFields`) because the server omits those from list
payloads by default. `OriginalLanguage` is also read from the full item
request that already supplies chapters and trickplay at playback start.

## Playback language defaults (HEL-81)

Jellyfin's `MediaStream.IsOriginal` is the authority for Lagoon's Original
Audio mode. On servers or items that omit it, Lagoon falls back to the
item's `OriginalLanguage`; it never guesses from a stream title or filename.
`MediaStream.IsDefault`, `IsForced`, `IsHearingImpaired` and `Language` feed
the remaining selection modes.

The server profile provides only one audio and one subtitle language, while
Lagoon supports ordered primary/fallback choices. Those choices are local,
keyed by Lagoon's server+user account id. A manual in-player selection
carried into the next episode wins over the local default, which in turn
wins over the stream index Jellyfin marked as default. ISO 639-2 stream
codes and BCP-47/ISO 639-1 preferences normalize to the same language before
matching, including the older bibliographic ISO aliases.

**`Shows/NextUp` is a rail, not a cursor.** It returns the episode *in
progress* when there is one: `enableResumable` defaults to `true` (checked
against the server's own `/api-docs/openapi.json` on 10.11.11 — the build
both fixture and the public demo run). That is right for the Home rail and
wrong for anything asking "what plays after this", because a stop report
that hasn't landed yet leaves the episode you just finished looking
in-progress, so you get it back. Its other flags are `enableRewatching`
(default `false`) and `disableFirstEpisode` (default `false`).

`Shows/{seriesId}/Episodes` takes **`startItemId`**, which runs the list
forward to a given episode — so `startItemId=<current>&Limit=2` returns
`[current, next]` regardless of watch state, and naming no `SeasonId`
walks the whole series, which is what carries a binge over a season
boundary. Verified against the demo server: anchored on S1E3 it returned
exactly S1E3 and S1E4. It also takes `adjacentTo`, which returns siblings.

## Images

`imageURL(for:kind:maxWidth:)` builds `Items/{id}/Images/{type}` URLs with the
item's image **tag** (cache-buster) and falls back through parent artwork the
way official clients do: episode primary → series poster
(`SeriesPrimaryImageTag`), own backdrop → `ParentBackdropItemId`'s backdrop.
`kind: .thumb` prefers episode stills (their Primary slot), then `Thumb`,
then backdrops.

## Remote subtitles (HEL-49)

Lagoon uses Jellyfin's provider-agnostic remote-subtitle routes; no client
code knows whether a result came from OpenSubtitles or another plugin.

| Purpose | Endpoint | Notes |
|---|---|---|
| Search | `GET Items/{itemId}/RemoteSearch/Subtitles/{language}` | language is ISO 639-2; Apple/BCP-47 preferences are normalized and converted to three-letter form |
| Download | `POST Items/{itemId}/RemoteSearch/Subtitles/{subtitleId}` | only runs after an explicit viewer action; result IDs remain one encoded path component |

Preferred languages are searched in order and each provider's returned
ranking is retained. Empty results, absent-provider 404s, transport failures,
and download failures are distinct UI states. Automatic mode searches when
no suitable local track exists but never downloads silently.

After a successful download Lagoon requests PlaybackInfo again, locates the
new external subtitle stream, resolves its `DeliveryUrl` with authentication,
and inserts it into the active sample-buffer engine. Playback position,
renderers, selected audio, and the Now Playing session are not rebuilt.
Forced and hearing-impaired metadata from both the result and refreshed
stream is preserved.

## App Transport Security (HEL-42)

`LagoonInfo.plist` declares **`NSAllowsLocalNetworking` only** — the blanket
`NSAllowsArbitraryLoads` is gone, which was the App Store prerequisite.

The worry was that this breaks the primary setup: a LAN server on plain http
at `192.168.1.x:8096`, which is literally the connect screen's placeholder.
It does not, and the reason is worth recording because the public record is
contradictory — Apple's DTS says `NSAllowsLocalNetworking` has *no effect on
IP-address loads* because ATS never applied to them, while CVE-2023-38596
reported that exemption as a vulnerability and Apple confirmed a fix in
iOS 17+.

**Measured on tvOS 26.2 (2026-08-18), the exemption still holds.** With only
`NSAllowsLocalNetworking` set, a plain-http request to `192.168.1.173:8096`
opened a real TCP flow (`flow:start_connect`, `tcp`) and failed with a
network error — `-1001` timing out against a dead port — with **zero** ATS
or cleartext objections anywhere in the log. A policy block would have been
`-1022` before any socket work. Re-run that probe if a future OS changes it:
point `server.url` at a dead LAN port and check whether the failure is
`-1001`/`-1004` (allowed) or `-1022` (blocked).

So the three shapes that matter all still work on cleartext:

- **IP literals** — exempt from ATS entirely, and unaffected by any of these keys.
- **`.local` names** and **unqualified hostnames** (`http://mediaserver:8096`)
  — covered by `NSAllowsLocalNetworking`.

What the change *does* block is cleartext to a fully-qualified public domain,
which is exactly the intent: a remote server must be https.

`SessionStore.candidateURLs` needed no change. It already probes http first
for IP/`.local` input and https first otherwise, and every http candidate it
generates for a non-local name is one ATS should reject.

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
every section Lagoon already draws and appends only the remainder by
default.

HEL-60 adds an opt-in local layout in Settings. Once the viewer changes it,
that ordered enabled set wins outright, including for normally covered
sections; before then the additive behavior above is unchanged. The layout
is keyed by server+user, newly discovered catalogue entries start disabled
for configured layouts, and the entire Settings row stays hidden when the
plugin route is unavailable.

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
