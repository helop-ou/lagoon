# Jellyfin API

Lagoon keeps using the user-scoped `Users/{id}/…` routes because both servers
answer them. That is a runtime observation, not a schema guarantee: several of
those routes are documented in neither version's OpenAPI surface.

## Wire format

- JSON keys are **PascalCase** both ways. `JellyfinClient` installs global key
  strategies — lowercase the first letter on decode, uppercase it on encode —
  so model types stay camelCase with no per-field CodingKeys.
- No `Date` fields are decoded anywhere. Jellyfin emits .NET 7-digit
  fractional-second timestamps that `ISO8601DateFormatter` rejects. The UI
  only needs `ProductionYear`, so dates are not modeled. SyncPlay is the one
  documented exception, and it is still not a `Date`: see _SyncPlay_ below.
- Positions and durations are .NET **ticks**: 100 ns, so 1 s is 10 000 000
  ticks. Convert only through the `Ticks` helpers.
- Decoding is defensive: `decodeIfPresent` plus defaults, unknown item types
  collapse to `.other`, and unexpected shapes in optional relations such as
  `userData` and `mediaSources` degrade to nil instead of failing the whole
  list.

## Auth

Every request carries:

```
Authorization: MediaBrowser Client="Lagoon", Device="Apple TV",
               DeviceId="<keychain uuid>", Version="<app version>"[, Token="…"]
```

That header is now the only credential on media traffic too. FFmpeg's network
transport, the playback cache, the external subtitle loader and the trickplay
loader used to accept a URL rather than a request, so same-origin stream,
external-subtitle and trickplay URLs carried the token as a query item. Since
the September 8 transport spike, `MediaRequestAuthorization` builds a
`URLRequest` for each of them and sets the same `Authorization: MediaBrowser …
Token="…"` header instead. No first-party media URL carries the token in its
query any more.

A server can still hand back a `TranscodingUrl` or subtitle `DeliveryUrl` that
carries the token itself, as either `ApiKey` or the deprecated lowercase
`api_key`. Jellyfin 12 disables `api_key` by default.
`MediaRequestAuthorization` sanitizes rather than trusts a returned URL:
`sanitizedURL(_:)` strips either spelling when the URL targets the Jellyfin
origin, and leaves a URL on any other origin byte-identical, so the Jellyfin
token is never sent to a subtitle provider or CDN.

- `POST Users/AuthenticateByName` `{Username, Pw}` → `AccessToken` + `User`.
- **Quick Connect**: `GET QuickConnect/Enabled` returns true, then `POST
QuickConnect/Initiate` — needs the MediaBrowser header, no token — returns
  `{Code, Secret}`. Poll `GET QuickConnect/Connect?secret=` every 2 s until
  `Authenticated`, then `POST Users/AuthenticateWithQuickConnect {Secret}`.
  Expiry surfaces as an error on the poll: reset the UI, don't retry the same
  secret.
- `POST Sessions/Logout` on sign-out invalidates the token server-side.
- Pre-auth server validation hits `GET System/Info/Public`, which needs no
  header. Its `ServerName` seeds the sign-in screen.

## Library endpoints

| Purpose                    | Endpoint                                                | Quirk                                                                                                                        |
| -------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Libraries                  | `Users/{uid}/Views`                                     | filter `CollectionType` to `movies`/`tvshows`                                                                                |
| Browse/search              | `Users/{uid}/Items`                                     | `ParentId`, `IncludeItemTypes`, `SearchTerm`, paged via `StartIndex`/`Limit`                                                 |
| Decade choices             | `Items/Filters`                                         | `Years` for `UserId`, `IncludeItemTypes`, optional `ParentId`; recursive full catalogue, not `Filters2` (which has no years) |
| Item detail                | `Users/{uid}/Items/{id}`                                | re-fetched after playback for fresh `UserData`                                                                               |
| Continue watching          | `Users/{uid}/Items/Resume`                              | `MediaTypes=Video`                                                                                                           |
| Next up                    | `Shows/NextUp?UserId=`                                  | Home uses `EnableResumable=false&EnableRewatching=false`; **never** for autoplay, see below                                  |
| Recently added             | `Users/{uid}/Items/Latest`                              | **returns a bare array**, not an `Items` wrapper                                                                             |
| Seasons/episodes           | `Shows/{seriesId}/Seasons` / `…/Episodes?SeasonId=`     |                                                                                                                              |
| The episode after this one | `Shows/{seriesId}/Episodes?startItemId=&Limit=2`        | index 1 is the next one                                                                                                      |
| Collections                | `Users/{uid}/Items?IncludeItemTypes=BoxSet`             | **`EnableUserData=false` or it takes 40 s** — see below                                                                      |
| What is in a collection    | `Users/{uid}/Items?ParentId={boxSetId}&Recursive=false` | `SortBy=PremiereDate,SortName` for release order                                                                             |

List calls pass `Fields=Overview,Genres,…,OriginalLanguage` via
`JellyfinClient.defaultFields`, because the server omits those fields from
list payloads by default. `OriginalLanguage` is also read from the full item
request, which already supplies chapters and trickplay at playback start.

**Recently Added Shows must normalize Latest's groups.** `GroupItems=true` is
already the default, but a group with one recent episode comes back as an
`Episode`, while a multi-episode group comes back as its `Series`.
`latestSeries` replaces episode and season results with the genuine parent
series, using one user-scoped `Items?Ids=…&IncludeItemTypes=Series` request
for any parents not already present. It deduplicates in first-occurrence
order, so an old show that receives a new episode still appears at its
latest-addition position. Do not replace this with a series `DateCreated`
sort. Missing parents are omitted, and lookup failures fall back to Home's
last-good rail. Movie libraries continue to use the original Latest response.

## Collections are folders, and folders are expensive

Two things about `BoxSet` items are not obvious until a real library is in
front of you. Both were measured against the reference server's 173
collections:

- **Listing them costs 38.6 s with user data and 0.25 s without.** A
  collection's `UserData` carries `UnplayedItemCount`, which the server can
  only answer by walking that collection's children, roughly a quarter of a
  second each. Nothing else moved the number: dropping `Fields`, naming the
  Collections library as `ParentId` instead of `Recursive=true`, and asking
  for 20 rows instead of 200 all still took about 40 s. `EnableUserData=false`
  is the whole fix. It is safe here because a collection's own watched flags
  are not drawn anywhere; the titles _inside_ one are a separate query that
  keeps its user data and answers in 50 ms.
- **Most collections are empty.** A metadata scrape creates a collection for a
  film's entire franchise the moment the library holds one entry in it. Of
  those 173, 35 contain anything at all and 18 contain more than one title.
  `ChildCount` rides along in the list response and survives
  `EnableUserData=false`, so the stubs can be dropped without a request per
  collection. `CollectionShelf.minimumTitles` is that floor.

Artwork is patchy for the same reason: 11 of those 18 real collections have no
landscape image of their own, so Home borrows one from the first title inside,
through `CollectionShelf.artworkSource`. Their contents are fully illustrated.

## Playback language defaults

Jellyfin's `MediaStream.IsOriginal` is the authority for Lagoon's Original
Audio mode. On servers or items that omit it, Lagoon falls back to the item's
`OriginalLanguage`. It never guesses from a stream title or filename.
`MediaStream.IsDefault`, `IsForced`, `IsHearingImpaired` and `Language` feed
the remaining selection modes.

The server profile provides only one audio and one subtitle language, while
Lagoon supports ordered primary and fallback choices. Those choices are local,
keyed by Lagoon's server and user account id. A manual in-player selection
carried into the next episode wins over the local default, which in turn wins
over the stream index Jellyfin marked as default. ISO 639-2 stream codes and
BCP-47/ISO 639-1 preferences normalize to the same language before matching,
including the older bibliographic ISO aliases.

**`Shows/NextUp` is a rail, not a cursor.** It returns the episode _in
progress_ when there is one. `enableResumable` defaults to `true`: checked
against the server's own `/api-docs/openapi.json` on 10.11.11, the build both
the fixture server and the public demo run. Home explicitly sets
`EnableResumable=false` and `EnableRewatching=false`, because started episodes
belong in Continue Watching. Jellyfin omits that series rather than skipping
ahead to a later episode, so Lagoon also defensively removes records reporting
any progress or `Played=true`. The series detail Play button uses a separate
`nextUpEpisode` request with `EnableResumable=true`, so it still resumes.

NextUp is wrong for anything asking "what plays after this": a stop report
that hasn't landed yet leaves the episode you just finished looking
in-progress, so the default request gives it back.

`Shows/{seriesId}/Episodes` takes **`startItemId`**, which runs the list
forward to a given episode. `startItemId=<current>&Limit=2` returns `[current,
next]` regardless of watch state, and naming no `SeasonId` walks the whole
series, which is what carries a binge over a season boundary. Verified against
the demo server: anchored on S1E3, it returned exactly S1E3 and S1E4. It also
takes `adjacentTo`, which returns siblings.

## Images

`imageURL(for:kind:maxWidth:)` builds `Items/{id}/Images/{type}` URLs with the
item's image **tag** as a cache-buster, and falls back through parent artwork
the way official clients do: episode primary to series poster
(`SeriesPrimaryImageTag`), own backdrop to `ParentBackdropItemId`'s backdrop.
`kind: .thumb` prefers episode stills (their Primary slot), then `Thumb`, then
backdrops, then the poster, so a title with only a Primary image still fills a
landscape card instead of leaving it blank; jellyfin-web ends its card chain
the same way. A landscape card with no artwork at all shows its title.

## Downloads

| Purpose                      | Endpoint                    | Notes                                                                                                                                                                                                                                                                                                         |
| ---------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Original file                | `GET Items/{id}/Download`   | gated by the per-user `EnableContentDownloading` policy; the download control is hidden without it rather than let the server refuse                                                                                                                                                                          |
| Progressive transcode        | `GET Videos/{id}/stream.ts` | one MPEG-TS response the encode writes as it runs, playable while incomplete, so a background `URLSession` task can carry a whole transcode; needs a fresh `playSessionId` on every request, since the server keys the transcode job on it and reuses whatever an abandoned earlier job left behind otherwise |
| Permission and policy fields | `GET Users/Me`              | decodes `EnableContentDownloading` and `EnableVideoPlaybackTranscoding` on `UserPolicy`, same pattern as `EnableSubtitleManagement`                                                                                                                                                                           |

An administrator may always download, regardless of the policy flags. Unlike
subtitle management, an unknown or unreachable answer for content downloading
defaults to no rather than yes, because starting a transfer the server would
refuse is worse than not offering it.

`JellyfinClient` caches both flags the same way. `canDownloadContent()` and
`canTranscodeForDownload()` resolve them from sign-in's policy or a lazy
`Users/Me` refresh, and `cachedContentDownloadingAllowed` and
`cachedVideoTranscodingAllowed` expose whatever the cache currently holds, so
view code can answer synchronously while building a menu body.
`EnableContentDownloading` gates whether the Download control or context-menu
submenu appears at all. `EnableVideoPlaybackTranscoding` gates only which
qualities it offers once downloading is allowed. Original is always offered,
since it is the file the server already has. High and Standard are transcodes
the server has to build for offline use, so they are hidden when the account
may not ask the server to transcode. The context menu warms both caches with a
`.task` the first time it needs an answer, since a rail card cannot afford to
await one per tap.

## Remote subtitles

Lagoon uses Jellyfin's provider-agnostic remote-subtitle routes. No client
code knows whether a result came from OpenSubtitles or another plugin.

| Purpose                | Endpoint                                                  | Notes                                                                                             |
| ---------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Search                 | `GET Items/{itemId}/RemoteSearch/Subtitles/{language}`    | language is ISO 639-2; Apple/BCP-47 preferences are normalized and converted to three-letter form |
| Fetch provider file    | `GET Providers/Subtitles/Subtitles/{subtitleId}`          | result ids are opaque and remain one percent-encoded path component                               |
| Persist fetched file   | `POST Videos/{itemId}/Subtitles`                          | uploads the already validated bytes as base64, avoiding a second provider download                |
| Compatibility fallback | `POST Items/{itemId}/RemoteSearch/Subtitles/{subtitleId}` | retained for provider formats Lagoon cannot parse directly                                        |

**Every one of those routes requires the per-user `EnableSubtitleManagement`
permission, which is off by default for every non-administrator** on Jellyfin
10.9 and later. Without it all four answer `403` with an HTML body — the
common case on a shared server, confirmed on both the fixture and public demo
servers. So Lagoon reads `User.Policy.EnableSubtitleManagement`, free in the
`AuthenticateByName` response and lazily from `Users/Me` for a restored token,
and shows administrator guidance instead of a search. An unreachable server
resolves to _permitted_: a network problem must never be reported as a
permissions problem.

Preferred languages are searched **concurrently**, and the results are
re-sorted into request order so each provider's ranking is retained. A failure
for one language does not discard successful results from another, and a
permission or session failure outranks whichever language happened to fail
first. Empty results, missing permission, absent-provider 404s, transport
failures, and download failures are distinct UI states. Automatic mode
searches when no suitable local track exists but never downloads silently.

Failures are classified rather than collapsed: 403 is a permission, 401 an
expired session, 429 rate limiting, 5xx a provider fault, and a timeout a
timeout. The "provider could not supply this file / download limit" wording is
reserved for the case that earns it, when the provider answered 404 for the
file itself _and_ Jellyfin's save then attached nothing. Retries cover only
fast-failing transient errors. A timeout is excluded because the provider
budget is already 90 s, and rate limiting is excluded because retrying inside
seconds cannot clear a limit measured in minutes and only spends more of the
provider's quota getting there.

Provider calls carry a 90 s timeout rather than the 30 s client default, since
a search makes the _server_ fan out to third-party services. A 401 or 403 on
the direct fetch never falls through to the compatibility endpoint, because
that would make Jellyfin fetch from the provider a second time on the way to
the same error, spending quota to learn nothing.

Provider file responses use the shared `BoundedDownload` transport (audit
A15): 8 MiB maximum, enforced on each delivered chunk as well as declared
length. HTML/JSON success responses, truncated transfers and unreadable cues
are rejected before selecting or saving a file. HTTP errors retain at most 16
KiB of diagnostic body; 401/403/429 finish immediately without waiting for it.
The normal captured-session check still precedes response handling, so an old
account's late 401 cannot expire the account now in use. Oversized and invalid
files have explicit errors and do not invoke the compatibility download. The
same file-size limit applies to sidecars and to provider files fetched through
Jellyfin.

Jellyfin 10.11's `DownloadRemoteSubtitles` controller catches its internal
provider/save exception and still returns HTTP 204, so a successful status is
not evidence that a subtitle exists. Lagoon instead fetches the provider file,
validates that it contains readable cues, inserts and selects those bytes in
the active engine immediately, and uploads the same bytes to Jellyfin for
future sessions. This uses one provider download and still works when the
library is read-only. Provider formats Lagoon cannot parse use the native
endpoint and a PlaybackInfo poll as a compatibility fallback. Playback
position, renderers, selected audio, and the Now Playing session are not
rebuilt. Forced and hearing-impaired metadata is preserved.

## SyncPlay

Group playback. The server owns a group's state and tells every member _when_,
on its own clock, to unpause, pause, seek or stop. A client that acts on a
command immediately is already wrong. Probed against the fixture server on
12.0.0 on 2026-09-14.

| Purpose      | Endpoint                                                                                                                           | Notes                                                                                                                                                                                                                             |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Groups       | `GET SyncPlay/List`                                                                                                                | `[]` with no groups; also the availability probe, since a server without SyncPlay fails the route                                                                                                                                 |
| Membership   | `POST SyncPlay/New {GroupName}`, `Join {GroupId}`, `Leave`                                                                         | 204 each. The new group's id is **not** read from the response: it arrives over the socket as a `GroupJoined` update, the same path a join takes                                                                                  |
| Queue        | `POST SyncPlay/SetNewQueue {PlayingQueue, PlayingItemPosition, StartPositionTicks}`, `SetPlaylistItem`, `NextItem`, `PreviousItem` | item ids go up, the `PlaylistItemId`s the group assigns come back as a `PlayQueue` update                                                                                                                                         |
| Transport    | `POST SyncPlay/Unpause`, `Pause`, `Stop`, `Seek {PositionTicks}`                                                                   | nothing happens locally; the server answers every member with a command                                                                                                                                                           |
| Readiness    | `POST SyncPlay/Buffering`, `Ready` `{When, PositionTicks, IsPlaying, PlaylistItemId}`                                              | the slowest member sets the pace. `SetIgnoreWait {IgnoreWait}` opts this client out of holding the group up                                                                                                                       |
| Latency      | `POST SyncPlay/Ping {Ping}`                                                                                                        | milliseconds, from the clock estimate below                                                                                                                                                                                       |
| Capabilities | `POST Sessions/Capabilities/Full`                                                                                                  | **not** required for command delivery: a session that never posted it still received every group command. Sent anyway so the session appears controllable; `SupportedCommands` is empty until the player handles `GeneralCommand` |

**The socket.** `wss://<server>/socket?api_key=<token>&deviceId=<id>`, built
from `serverRelativeURL("socket")` with the scheme swapped, so a reverse-proxy
base path survives. This is the one first-party URL that still carries the
token in its query: the handshake is not a request Lagoon's `Authorization`
header was verified to reach. The envelope is `{"MessageType", "MessageId"?,
"Data"}`. `MessageId` is absent on every SyncPlay message seen, and `Data` is
anything: an object for `SyncPlayGroupUpdate`, a bare integer for
`ForceKeepAlive`, a bare string for `GroupLeft`. So `ServerSocket` splits the
envelope with `JSONSerialization` and re-serialises the `Data` subtree for the
caller to decode; an unknown `MessageType` is ignored, never a decoding
failure. `ForceKeepAlive` carries a timeout in seconds, 60 observed, and wants
`{"MessageType":"KeepAlive"}` at once and then every half-timeout. The server
echoes that reply back, and neither is forwarded. Reconnection backs off 1, 2,
4, 8, 16, 30 s with ±20 % jitter, reset once a connection carries a message.

**Group ids have two spellings.** `GroupId` fields use undashed lowercase hex,
while the `GroupLeft` update's payload is the dashed form of the same value.
Compare through `SyncPlayGroupIdentifier`, never with `==`. The same helper
recognises the all-zero `PlaylistItemId` on the `Stop` a newly created group
is greeted with.

**The clock, and the timestamp exception.** `GET GetUtcTime` returns
`{RequestReceptionTime, ResponseTransmissionTime}`. With the local instants
either side of the request, that gives NTP's four-timestamp measurement.
`ServerClock` keeps the last eight samples and uses the one with the _lowest_
round trip, never an average: a slow sample is asymmetric, not noisy, and
averaging folds that error in. It takes three samples a second apart, then one
a minute.

Those timestamps, and SyncPlay's `When`, `EmittedAt` and `LastUpdate`, are
wall-clock instants the protocol cannot do without, so they are the documented
exception to "no `Date` is decoded". They stay `String` on the DTOs and are
converted only through `JellyfinTimestamp`, which parses
`yyyy-MM-ddTHH:mm:ss[.f{0,7}]Z` by hand. The fraction has a _variable_ number
of digits, 6 and 7 in the same response, and `ISO8601DateFormatter` rejects 7.
`JellyfinTimestamp` writes the seven-digit form back. A non-UTC offset is
refused rather than guessed at.

**Permission.** `Users/Me` → `Policy.SyncPlayAccess` is `CreateAndJoinGroups`,
`JoinGroups` or `None`, decoded onto `UserPolicy` with an `unknown` fallback
that also covers an answer that never arrived. Unknown is not a denial: say
the permission could not be checked.

## Seerr title details, cast and recommendations

A Seerr title's page reads `movie/{id}` or `tv/{id}` and uses more of the
response than the request state. `credits.cast` and `credits.crew` carry
TMDB's billing, with `profilePath` for the headshot. A movie's `releases` and
a show's `contentRatings` give the age rating, where the viewer's own region's
certification is shown and the US one is the fallback, as Jellyfin's providers
do. Those two blocks are snake_case on the wire, unlike the rest of Seerr, so
their DTOs carry their own keys. "More Like This" is
`movie/{id}/recommendations` or `tv/{id}/recommendations`, TMDB's
recommendations relayed by Seerr. TMDB's `similar` list is keyword-matched and
much weaker, so it is not used. Recommendations are fetched with the first
load only; the live refresh re-reads the details alone. Discovery titles use
their name in type unless a matching Jellyfin library item provides a stored
Logo image.

## App Transport Security

`LagoonInfo.plist` declares **`NSAllowsLocalNetworking` only**. The blanket
`NSAllowsArbitraryLoads` is gone, which was the App Store prerequisite.

The worry was that this breaks the primary setup: a LAN server on plain http
at `192.168.1.x:8096`, which is literally the connect screen's placeholder. It
does not, and the reason matters, because the public record is contradictory.
Apple's DTS says `NSAllowsLocalNetworking` has _no effect on IP-address
loads_, because ATS never applied to them. CVE-2023-38596 reported that
exemption as a vulnerability, and Apple confirmed a fix in iOS 17+.

**Measured on tvOS 26.2 (2026-08-18), the exemption still holds.** With only
`NSAllowsLocalNetworking` set, a plain-http request to `192.168.1.173:8096`
opened a real TCP flow (`flow:start_connect`, `tcp`) and failed with a network
error: `-1001` timing out against a dead port, with **zero** ATS or cleartext
objections anywhere in the log. A policy block would have been `-1022` before
any socket work. Re-run that probe if a future OS changes it: point
`server.url` at a dead LAN port and check whether the failure is
`-1001`/`-1004` (allowed) or `-1022` (blocked).

So the three shapes that matter all still work on cleartext:

- **IP literals** are exempt from ATS entirely, unaffected by any of these
  keys.
- **`.local` names** and **unqualified hostnames** (`http://mediaserver:8096`)
  are covered by `NSAllowsLocalNetworking`.

What the change _does_ block is cleartext to a fully-qualified public domain,
which is exactly the intent: a remote server must be https.

This ATS change retained the existing discovery order: HTTP first for
IP/`.local` input and HTTPS first otherwise. Public-host HTTP candidates
remain subject to ATS. The later A13 fix below changes address construction
and disclosure without broadening the transport exceptions.

## Server address entry and discovery (audit A13)

Jellyfin and Seerr use `Shared/Networking/ServerAddress.swift` to parse
user-entered service roots. An address may include a hostname, port, and
reverse-proxy base path. Explicit `http://` or `https://` selects exactly that
transport and port; discovery never downgrades an explicit HTTPS address or
adds a default port to it. Surrounding whitespace and trailing path slashes
are normalized.

Schemeless input retains the discovery order above. Jellyfin also tries port
8096 and Seerr port 5055 when no port was supplied. Ports are assigned through
`URLComponents.port`, before the path: `media.example/jellyfin` can produce
`http://media.example:8096/jellyfin`. Bracketed IPv6 literals, including
explicit ports, and internationalized hostnames are supported. A terminal
`/api/v1` on Seerr input is removed so requests append the API prefix once.
Configuration, restoration, and session snapshots then treat that URL as a
service root; they do not strip another suffix if the proxy root itself ends
in `/api/v1`.

Normalization uses `percentEncodedPath`, so an escaped slash inside a proxy
path stays escaped. Credentials in the URL, query parameters, fragments,
unsupported schemes, malformed escapes, missing hosts, invalid ports, and
internal whitespace are rejected before discovery. Paste the service root
rather than a browser page or an API URL containing a token.

Sign-in and Seerr settings show the full selected scheme, host, port, and
path. HTTP connections carry a visible explanation of password, token, and
activity exposure before authentication controls, and this also applies to
restored sign-in screens. Legacy embedded credentials and query strings are
redacted from that display; stored account identities are not migrated by this
change.

Regression coverage is in `ServerAddressTests`, `SeerrClientTests`, and
`ServerAddressUITests`. Run the controlled UI journey on fresh simulators
with:

```sh
python3 scripts/test-session-recovery.py --server-address
```

The fixture requires proxy paths for API requests and verifies both Jellyfin
authentication and Seerr discovery. iOS exercises typed setup and
invalid-input recovery; tvOS exercises restored sign-in and remote focus, then
a synthetic account with a restored Seerr pairing. HTTPS disclosure is checked
using a restored URL; that UI check is not a TLS-handshake test.
Physical-network acceptance is still owed.

## Home Screen Sections plugin

This is an optional server plugin. A server without it 404s the whole route,
and Home falls back to Lagoon's own rails.

- `GET HomeScreen/Sections?userId=` returns the section **catalogue**.
- `GET HomeScreen/Section/{sectionKey}?userId=` returns that section's items,
  shaped as an ordinary `ItemsPage`.

**The catalogue is not a layout, and this is the whole difficulty.** Probed
against a real install (2026-08-18), it returns all 28 section types the
plugin knows, Books, Music and Jellyseerr rows included, for a
movies-and-TV-only library, with `OrderIndex` 999 and `Limit` 1 on every one.
It does _not_ narrow to what the admin enabled, and the enabled set is not
readable anywhere: `HomeScreen/UserSettings`, `HomeScreen/Settings`,
`HomeScreen/Config` and `HomeScreen/Users/{id}/Settings` all 404, and core
`DisplayPreferences/usersettings` carries no `homesection*` keys.

So a client cannot honour the server's intended layout, and rendering the
catalogue wholesale is actively wrong. The same server offers
`ContinueWatching`, `NextUp` **and** `ContinueWatchingNextUp`, plus
`LatestMovies` alongside `RecentlyAddedMovies`, so Home would show the same
films three times. `HomeViewModel.nativelyCoveredSections` therefore drops
every section Lagoon already draws and appends only the remainder by default.

Settings, Home Rows holds one ordered arrangement covering every Home row,
Lagoon's own and the plugin's together, so a plugin row can sit anywhere among
the native ones. Until the viewer arranges it there is no stored arrangement
at all: Lagoon's default order applies and the remaining catalogue sections
follow it, which is the additive behavior above. Once they arrange it, that
order wins and hides whatever it leaves out. Sections Lagoon already draws are
never offered, so an arrangement cannot resurrect a duplicate of a native row.

The arrangement is keyed by server and user. A catalogue entry discovered
after plugin rows were arranged starts hidden; one discovered by an account
that had only ever hidden a native row starts shown, because that account
never arranged a plugin row. A row is never dropped from an arrangement:
`homeSections()` answers a failed request with an empty catalogue, and pruning
unknown rows would erase the viewer's order the first time the server was
slow. A row added by a later Lagoon build is inserted at its designed place
rather than appended under the plugin rows.

Before testing: on a plain movies/TV server this feature correctly renders
**nothing**, because every non-empty section is one Lagoon already has. It
earns its keep on servers with Jellyseerr requests, My List, Discover or
custom collection sections.

Cost is low enough to fetch eagerly: all 28 sections resolve in ~1.8 s
concurrently, empties answering in ~0.1 s each.

### Top 10 rows

The practical workaround uses Seerr's authenticated `discover/movies` and
`discover/tv` catalogues, with trending results merged ahead of popular
results. A bounded, paginated library scan then intersects each list with the
current user's Jellyfin items by exact `ProviderIds.Tmdb` matches within the
same movie or TV catalogue. Duplicate editions and repeated discovery IDs
occupy one slot; fewer than four matches omits that row. Top 10 loads
independently, so a slow external catalogue never delays the native curated
shelves. The resulting Top 10 Movies and Top 10 Shows rows contain playable
library items only, with no title or year guessing, and an unconfigured Seerr
connection omits the rows. The Home Screen Sections Manager remains supported
for its existing legacy sections; its newer ranked-section API is not required
for these rows. This is an approximation of popularity, not a personal
`PlayCount` substitute.

## Testing without a home server

The public demos use user `demo` with an empty password. `stable` at
`https://demo.jellyfin.org/stable` exercises the supported 10.x baseline.
`unstable` at `https://demo.jellyfin.org/unstable` is the Jellyfin 12
pre-release covered above, reporting itself as `12.0.0`. Both are suitable for
authentication, navigation and playback regression runs, though their shared
libraries can change. The outstanding `unstable` video-transcode run noted
above has not been done yet.
