# Jellyfin API

Checked against the public Jellyfin **10.11.11** stable and **12.0.0**
unstable servers on 2026-09-04. The unstable demo is a pre-release of 12.0,
but nothing it exposes says which one: `System/Info/Public`, authenticated
`System/Info` and its OpenAPI document all report the version as `12.0.0`, so
that is the string used throughout these docs.

Lagoon keeps using the user-scoped `Users/{id}/…` routes because both servers
answer them. That is a runtime observation, not a schema guarantee — several
of those routes are documented in neither version's OpenAPI surface; see
*Jellyfin 12 compatibility* below.

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

That header is now the only credential on media traffic too. Media consumers
such as FFmpeg's network transport, the playback cache, the external
subtitle loader and the trickplay loader used to accept a URL rather than a
request, so same-origin stream, external-subtitle and trickplay URLs carried
the token as a query item. Since the September 8 transport spike,
`MediaRequestAuthorization` builds a `URLRequest` for every one of them and
sets the same `Authorization: MediaBrowser … Token="…"` header instead; no
first-party media URL carries the token in its query any more. A server can
still hand back a `TranscodingUrl` or subtitle `DeliveryUrl` carrying the
token itself — as either `ApiKey` or the deprecated lowercase `api_key`,
which Jellyfin 12 disables by default — so `MediaRequestAuthorization`
sanitizes rather than trusts it: `sanitizedURL(_:)` strips either spelling
when the URL targets the Jellyfin origin, and leaves a URL on any other
origin byte-identical so the Jellyfin token is never sent to a subtitle
provider or CDN.

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

## Jellyfin 12 compatibility (HEL-138)

Jellyfin 12 drops older server-generated HLS routes — `master.m3u8`,
`main.m3u8`, `hls/…`, `hls1/…` and `live.m3u8` are in the 10.11.11 document
and gone from the 12.0.0 one — but Lagoon never constructs those: it resolves
the `TranscodingUrl` supplied by `PlaybackInfo`. The relevant `BaseItemDto`
and `MediaStream` changes are additive, so Lagoon's defensive decoders accept
both versions without a model fork.

**What the schema comparison can and cannot settle.** Five of the routes
Lagoon leans on hardest are documented in *neither* version's OpenAPI surface:
`/Users/{userId}/Items`, `/Users/{userId}/Views`, `/Users/{userId}/Items/Latest`,
`/Users/{userId}/Items/Resume` and `/Users/{userId}/Items/{itemId}`. They are
undocumented legacy routes that both servers nonetheless serve. So a
path-by-path diff of the two documents cannot clear them either way, and an
earlier version of this page claimed a conclusion its stated method could not
have produced. What actually clears them is a direct probe: each of the five
returns 200 on the 12.0.0 server. That is a fact about one server on one day
rather than a published compatibility guarantee, which is why these five get
re-probed, not re-read, when 12.0 ships.

A live 12.0.0 probe verified password authentication and an authenticated
library request with Lagoon's `Authorization` header. It also established
the media-URL boundary directly, on 2026-09-04: `ApiKey` succeeded while
lowercase `api_key` returned 401 on a normal authenticated endpoint — a fact
about that server on that day, and the reason a server-returned credential is
sanitized on sight rather than assumed absent. Focused integration coverage
now checks the header-only state that replaced the query fallback:
`playbackURLResolutionPreservesTheNegotiatedTransportMatrix` in
`LagoonTests/PlayerSystemIntegrationTests.swift` asserts that no same-origin
media URL — direct-play, direct-stream, transcode, external
subtitle sidecar or trickplay sheet — carries `ApiKey` or `api_key` in its
query, that the `Authorization` header carries the token instead, and that a
foreign-origin subtitle URL is left untouched.

**The app-level run against Jellyfin 12 (2026-09-04).** Lagoon was driven
against the 12.0.0 public preview on a clean tvOS 26 simulator, pointed there
with `LAGOON_REGRESSION_SERVER=https://demo.jellyfin.org/unstable`.
`PlayerRegressionUITests.testBufferedDirectH264PlaybackStartsAndSustains`
passed: it authenticates, browses for an episode with a direct-playable H.264
successor, negotiates `DirectPlay` through `PlaybackInfo`, reaches ready with
no buffering, then plays for 20 seconds advancing more than 14 seconds of
media time with zero buffering events, at most one stall, exactly one engine,
demuxer and renderer, no unclean teardown and under 96 MB of growth.

**The transcode chain was verified at the protocol level, not in the app.**
The harness picks whatever the server will play, and neither public demo
returns a transcode for it, so `testNativeHLSPlaybackStartsAndCrossesSegment\
Boundaries` resolves `DirectPlay` and fails its `Transcode` assertion on
**both** 10.11.11 and 12.0.0 — a stale expectation in the test rather than a
Jellyfin 12 regression; it passes against fixture, whose content does
transcode. So the transcode path was checked directly instead, on 2026-09-04
before the September 8 header-only change: authenticating on 12.0.0 and
calling `PlaybackInfo` with a profile that can direct-play nothing returned a
`TranscodingUrl`, and resolving it the way the client did that day — with
`ApiKey` in the query — reached a master playlist, a variant playlist and a
first media segment that all returned 200 with the credential propagated at
every hop (620 KB of transport stream on the segment). That is the exact
chain HEL-138 changed; the same chain is exercised today with the token in
the `Authorization` header instead.

Still outstanding: sustained *transcode* playback inside the app on 12, which
needs a server whose content forces one, and the deployment check on fixture
once it upgrades.

## Library endpoints

| Purpose | Endpoint | Quirk |
|---|---|---|
| Libraries | `Users/{uid}/Views` | filter `CollectionType` to `movies`/`tvshows` |
| Browse/search | `Users/{uid}/Items` | `ParentId`, `IncludeItemTypes`, `SearchTerm`, paged via `StartIndex`/`Limit` |
| Decade choices | `Items/Filters` | `Years` for `UserId`, `IncludeItemTypes`, optional `ParentId`; recursive full catalogue, not `Filters2` (which has no years) |
| Item detail | `Users/{uid}/Items/{id}` | re-fetched after playback for fresh `UserData` |
| Continue watching | `Users/{uid}/Items/Resume` | `MediaTypes=Video` |
| Next up | `Shows/NextUp?UserId=` | Home uses `EnableResumable=false&EnableRewatching=false`; **never** for autoplay, see below |
| Recently added | `Users/{uid}/Items/Latest` | **returns a bare array**, not an `Items` wrapper |
| Seasons/episodes | `Shows/{seriesId}/Seasons` / `…/Episodes?SeasonId=` | |
| The episode after this one | `Shows/{seriesId}/Episodes?startItemId=&Limit=2` | index 1 is the next one (HEL-66) |
| Collections | `Users/{uid}/Items?IncludeItemTypes=BoxSet` | **`EnableUserData=false` or it takes 40 s** — see below (HEL-122) |
| What is in a collection | `Users/{uid}/Items?ParentId={boxSetId}&Recursive=false` | `SortBy=PremiereDate,SortName` for release order |

List calls pass `Fields=Overview,Genres,…,OriginalLanguage`
(`JellyfinClient.defaultFields`) because the server omits those from list
payloads by default. `OriginalLanguage` is also read from the full item
request that already supplies chapters and trickplay at playback start.

**Recently Added Shows must normalize Latest's groups.** `GroupItems=true`
is already the default, but a group containing one recent episode is returned
as an `Episode`, while a multi-episode group is returned as its `Series`.
`latestSeries` replaces episode/season results with genuine parent series,
using one user-scoped `Items?Ids=…&IncludeItemTypes=Series` request for any
parents not already present. It deduplicates in first-occurrence order, so
an old show receiving a new episode still appears at its latest-addition
position. Do not replace this with a series `DateCreated` sort. Missing
parents are omitted; lookup failures propagate to Home's last-good-rail
fallback. Movie libraries continue to use the original Latest response.

## Collections are folders, and folders are expensive (HEL-122)

Two things about `BoxSet` items are not obvious until a real library is in
front of you, and both were measured against the reference server's 173
collections:

- **Listing them costs 38.6 s with user data and 0.25 s without.** A
  collection's `UserData` carries `UnplayedItemCount`, which the server can
  only answer by walking that collection's children — roughly a quarter of a
  second each. Nothing else moved the number: dropping `Fields`, naming the
  Collections library as `ParentId` instead of `Recursive=true`, and asking
  for 20 rows instead of 200 all still took about 40 s. `EnableUserData=false`
  is the whole fix, and it is safe here because a collection's own watched
  flags are not drawn anywhere; the titles *inside* one are a separate query
  that keeps its user data and answers in 50 ms.
- **Most collections are empty.** A metadata scrape creates a collection for a
  film's entire franchise the moment the library holds one entry in it, so of
  those 173, 35 contain anything at all and 18 contain more than one title.
  `ChildCount` rides along in the list response — it survives
  `EnableUserData=false` — so the stubs can be dropped without a request per
  collection. `CollectionShelf.minimumTitles` is that floor.

Artwork is patchy for the same reason: 11 of those 18 real collections have no
landscape image of their own, so Home borrows one from the first title inside
(`CollectionShelf.artworkSource`). Their contents are fully illustrated.

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
both fixture and the public demo run). Home explicitly sets
`EnableResumable=false` and `EnableRewatching=false`: started episodes belong
in Continue Watching. Jellyfin omits that series rather than skipping ahead
to a later episode. Lagoon also defensively removes records reporting any
progress or `Played=true`. The series detail Play button uses a separate
`nextUpEpisode` request with `EnableResumable=true`, so it still resumes.

NextUp is wrong for anything asking "what plays after this", because a stop report
that hasn't landed yet leaves the episode you just finished looking
in-progress, so the default request gives it back.

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
| Fetch provider file | `GET Providers/Subtitles/Subtitles/{subtitleId}` | result ids are opaque and remain one percent-encoded path component |
| Persist fetched file | `POST Videos/{itemId}/Subtitles` | uploads the already validated bytes as base64, avoiding a second provider download |
| Compatibility fallback | `POST Items/{itemId}/RemoteSearch/Subtitles/{subtitleId}` | retained for provider formats Lagoon cannot parse directly |

**Every one of those routes requires the per-user `EnableSubtitleManagement`
permission, and it is off by default for every non-administrator** (Jellyfin
10.9+). Accounts without it are shown administrator guidance instead of a
search (HEL-146) — see `docs/playback.md`, "One subtitle source". Without it
all four answer `403` with an HTML body — verified on both
fixture 10.11.11 and the public demo server, whose accounts are both
non-admin with the flag unset. On a shared server that is the common case, so
Lagoon reads `User.Policy.EnableSubtitleManagement` (free in the
`AuthenticateByName` response, lazily from `Users/Me` for a restored token)
and says so up front instead of failing one result at a time. An unreachable
server resolves to *permitted*: a network problem must never be reported as a
permissions problem. Administrators satisfy the policy implicitly.

Preferred languages are searched **concurrently** and the results re-sorted
into request order so each provider's ranking is retained. A failure for one
language does not discard successful results from another, and a permission or
session failure outranks whichever language happened to fail first. Empty
results, missing permission, absent-provider 404s, transport failures, and
download failures are distinct UI states. Automatic mode searches when no
suitable local track exists but never downloads silently.

Failures are classified rather than collapsed (HEL-91): 403 is a permission,
401 an expired session, 429 rate limiting, 5xx a provider fault, and a timeout
a timeout. The "provider could not supply this file / download limit" wording
is reserved for the case that earns it — the provider answered 404 for the
file itself *and* Jellyfin's save then attached nothing. Retries cover only
fast-failing transient errors: a timeout is excluded because the provider
budget is already 90 s, and rate limiting is excluded because retrying inside
seconds cannot clear a limit measured in minutes and only spends more of the
provider's quota getting there.

Provider calls carry a 90 s timeout rather than the 30 s client default, since
a search makes the *server* fan out to third-party services. A 401 or 403 on
the direct fetch never falls through to the compatibility endpoint: that would
make Jellyfin fetch from the provider a second time on the way to the same
error, spending quota to learn nothing.

Provider file responses use the shared `BoundedDownload` transport (audit A15):
8 MiB maximum, enforced on each delivered chunk as well as declared length.
HTML/JSON success responses, truncated transfers and unreadable cues are
rejected before selecting or saving a file. HTTP errors retain at most 16 KiB
of diagnostic body; 401/403/429 finish immediately without waiting for it.
The normal captured-session check still precedes response handling, so an old
account's late 401 cannot expire the account now in use. Oversized and invalid
files have explicit errors and do not invoke the compatibility download.
The same file-size limit applies to sidecars and to provider files fetched
through Jellyfin; see [download hardening validation](archive/download-hardening-validation.md).

Jellyfin 10.11's `DownloadRemoteSubtitles` controller catches its internal
provider/save exception and still returns HTTP 204, so a successful status is
not evidence that a subtitle exists. Lagoon instead fetches the provider file,
validates that it contains readable cues, inserts/selects those bytes in the
active engine immediately, and uploads the same bytes to Jellyfin for future
sessions. This uses one provider download and still works when the library is
read-only. Provider formats Lagoon cannot parse use the native endpoint and a
PlaybackInfo poll as a compatibility fallback. Playback position, renderers,
selected audio, and the Now Playing session are not rebuilt. Forced and
hearing-impaired metadata is preserved.

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

The HEL-42 ATS change retained the existing discovery order: HTTP first for
IP/`.local` input and HTTPS first otherwise. Public-host HTTP candidates remain
subject to ATS. The later A13 fix below changes address construction and
disclosure without broadening the transport exceptions.

## Server address entry and discovery (audit A13)

Jellyfin and Seerr use `Networking/ServerAddress.swift` to parse user-entered
service roots. An address may include a hostname, port, and reverse-proxy base
path. Explicit `http://` or `https://` selects exactly that transport and port;
discovery never downgrades an explicit HTTPS address or adds a default port to
it. Surrounding whitespace and trailing path slashes are normalized.

Schemeless input retains the discovery order above. Jellyfin also tries port
8096 and Seerr port 5055 when no port was supplied. Ports are assigned through
`URLComponents.port`, before the path: `media.example/jellyfin` can produce
`http://media.example:8096/jellyfin`. Bracketed IPv6 literals, including explicit
ports, and internationalized hostnames are supported. A terminal `/api/v1` on
Seerr input is removed so requests append the API prefix once. Configuration,
restoration, and session snapshots then treat that URL as a service root;
they do not strip another suffix if the proxy root itself ends in `/api/v1`.

Normalization uses `percentEncodedPath`: an escaped slash inside a proxy path
stays escaped. Credentials in the URL, query parameters, fragments, unsupported
schemes, malformed escapes, missing hosts, invalid ports, and internal
whitespace are rejected before discovery. Paste the service root rather than
a browser page or an API URL containing a token.

Sign-in and Seerr settings show the full selected scheme, host, port, and path.
HTTP connections carry a visible explanation of password, token, and activity
exposure before authentication controls. This also applies to restored sign-in
screens. Legacy embedded credentials/query strings are redacted from that
display; stored account identities are not migrated by this change.

Regression coverage is in `ServerAddressTests`, `SeerrClientTests`, and
`ServerAddressUITests`. Run the controlled UI journey on fresh simulators with:

```sh
python3 scripts/test-session-recovery.py --server-address
```

The fixture requires proxy paths for API requests and verifies both Jellyfin
authentication and Seerr discovery. iOS exercises typed setup and invalid-input
recovery; tvOS exercises restored sign-in and remote focus, then a synthetic
account with a restored Seerr pairing. HTTPS disclosure is checked using a
restored URL; that UI check is not a TLS-handshake test. See the
[server address validation record](archive/server-address-validation.md) for evidence
and remaining physical-network acceptance.

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

The public demos use user `demo` with an empty password. `stable` at
`https://demo.jellyfin.org/stable` exercises the supported 10.x baseline;
`unstable` at `https://demo.jellyfin.org/unstable` is the Jellyfin 12
pre-release used by HEL-138, reporting itself as `12.0.0`. Both are suitable
for authentication, navigation and playback regression runs, though their
shared libraries can change. The `unstable` playback run HEL-138 needs has
not been done yet.
