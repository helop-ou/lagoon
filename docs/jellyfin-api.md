# Jellyfin API

Lagoon uses the user-scoped `Users/{id}/…` routes because both server
generations answer them. That is observed behavior, not a schema guarantee:
several of those routes are in neither version's OpenAPI document.

## Wire format

- JSON keys are **PascalCase** both ways. `JellyfinClient` installs global key
  strategies (lowercase the first letter on decode, uppercase on encode), so
  models stay camelCase with no per-field CodingKeys.
- No `Date` is decoded anywhere. Jellyfin emits 7-digit fractional seconds,
  which `ISO8601DateFormatter` rejects, and the UI only needs
  `ProductionYear`. SyncPlay is the one exception, and even it keeps strings:
  see [SyncPlay](#syncplay).
- Positions and durations are .NET **ticks**: 100 ns, so 1 s = 10 000 000
  ticks. Convert only through the `Ticks` helpers.
- Decoding is defensive: `decodeIfPresent` with defaults, unknown item types
  become `.other`, and a bad shape in an optional relation (`userData`,
  `mediaSources`) becomes nil instead of failing the list.

## Auth

Every request carries:

```
Authorization: MediaBrowser Client="Lagoon", Device="Apple TV",
               DeviceId="<keychain uuid>", Version="<app version>"[, Token="…"]
```

That header is the only credential on media traffic too.
`MediaRequestAuthorization` builds a `URLRequest` with it for streams,
external subtitles and trickplay. No first-party media URL carries the token
in its query.

A server can still return a `TranscodingUrl` or subtitle `DeliveryUrl` with
the token in it, as `ApiKey` or the deprecated `api_key` (disabled by default
in Jellyfin 12). `sanitizedURL(_:)` strips either spelling when the URL is on
the Jellyfin origin and leaves any other origin byte-identical, so the token
never reaches a subtitle provider or CDN.

- `POST Users/AuthenticateByName` `{Username, Pw}` → `AccessToken` + `User`.
- **Quick Connect**: `GET QuickConnect/Enabled` returns true, then
  `POST QuickConnect/Initiate` (MediaBrowser header, no token) returns
  `{Code, Secret}`. Poll `GET QuickConnect/Connect?secret=` every 2 s until
  `Authenticated`, then `POST Users/AuthenticateWithQuickConnect {Secret}`.
  Expiry arrives as an error on the poll: reset the UI, never retry the same
  secret.
- `POST Sessions/Logout` on sign-out invalidates the token on the server.
- Server validation before sign-in uses `GET System/Info/Public` (no header).
  Its `ServerName` seeds the sign-in screen.

Session expiry:

- An authenticated 401 expires only the account session that made the
  request. Lagoon dismisses playback and opens sign-in for that server,
  keeping username, remembered identity and preferences; reauthentication
  replaces the token.
- Progress reports use the same path, so a remote revocation during buffered
  playback is caught on the next report. There is no expiry polling and no
  startup probe.
- Outages and 403s keep credentials. A late response cannot expire a newer
  session.

`python3 scripts/test-session-recovery.py` exercises direct and native HLS
playback, remote revocation and sign-in against a loopback synthetic server.

## Library endpoints

| Purpose | Endpoint | Quirk |
| --- | --- | --- |
| Libraries | `Users/{uid}/Views` | filter `CollectionType` to `movies`/`tvshows` |
| Browse/search | `Users/{uid}/Items` | `ParentId`, `IncludeItemTypes`, `SearchTerm`, paged via `StartIndex`/`Limit` |
| Decade choices | `Items/Filters` | `Years` for `UserId`, `IncludeItemTypes`, optional `ParentId`; recursive full catalogue. Not `Filters2`, which has no years |
| Item detail | `Users/{uid}/Items/{id}` | re-fetched after playback for fresh `UserData` |
| Continue watching | `Users/{uid}/Items/Resume` | `MediaTypes=Video` |
| Next up | `Shows/NextUp?UserId=` | Home uses `EnableResumable=false&EnableRewatching=false`; **never** for autoplay, see below |
| Recently added | `Users/{uid}/Items/Latest` | **returns a bare array**, not an `Items` wrapper |
| Seasons/episodes | `Shows/{seriesId}/Seasons` / `…/Episodes?SeasonId=` | |
| The episode after this one | `Shows/{seriesId}/Episodes?startItemId=&Limit=2` | index 1 is the next one |
| Collections | `Users/{uid}/Items?IncludeItemTypes=BoxSet` | **`EnableUserData=false` or it takes 40 s**, see below |
| What is in a collection | `Users/{uid}/Items?ParentId={boxSetId}&Recursive=false` | `SortBy=PremiereDate,SortName` for release order |

List calls pass `Fields=Overview,Genres,…,OriginalLanguage` through
`JellyfinClient.defaultFields`, because lists omit those fields by default.

**Recently Added Shows must normalize Latest's groups.** With the default
`GroupItems=true`, a group with one new episode comes back as an `Episode`,
and a multi-episode group as its `Series`. `latestSeries` swaps episode and
season results for their parent series (one `Items?Ids=…&IncludeItemTypes=Series`
request for missing parents) and deduplicates in first-occurrence order, so an
old show with a new episode appears at its latest-addition position.

- Do not replace this with a series `DateCreated` sort.
- Missing parents are dropped; a failed lookup falls back to Home's last good
  rail.
- Movie libraries use the Latest response as is.

## Collections are folders, and folders are expensive

Measured against a server with 173 collections:

- **Listing costs 38.6 s with user data, 0.25 s without.** A collection's
  `UserData` includes `UnplayedItemCount`, which walks its children. Dropping
  `Fields`, scoping by `ParentId` or shrinking the page did not help;
  `EnableUserData=false` is the whole fix. It is safe because a collection's
  own watched state is never drawn. The query for titles inside a collection
  keeps user data and answers in 50 ms.
- **Most collections are empty.** Metadata scrapes create a collection for a
  whole franchise when the library holds one film of it. 35 of 173 had
  anything, 18 had more than one title. `ChildCount` survives
  `EnableUserData=false`, so `CollectionShelf.minimumTitles` filters stubs
  without a request per collection.
- **Artwork is patchy.** 11 of those 18 had no landscape image, so Home
  borrows the first title's through `CollectionShelf.artworkSource`.

## Playback language defaults

- `MediaStream.IsOriginal` decides Original Audio mode. If the server omits
  it, Lagoon uses the item's `OriginalLanguage` (also read from the full item
  request). It never guesses from a stream title or filename.
- `IsDefault`, `IsForced`, `IsHearingImpaired` and `Language` drive the other
  selection modes.
- The server profile holds one audio and one subtitle language; Lagoon's
  ordered primary and fallback choices are local, keyed by server and user.
- Precedence: a manual in-player choice carried into the next episode, then
  the local default, then Jellyfin's default stream.
- ISO 639-2 stream codes and BCP-47/ISO 639-1 preferences, including the old
  bibliographic aliases, normalize to one language before matching.

**`Shows/NextUp` is a rail, not a cursor.** It returns the in-progress episode
when there is one, since `enableResumable` defaults to `true` (checked in the
10.11.11 OpenAPI document).

- Home sets `EnableResumable=false` and `EnableRewatching=false`, because
  started episodes belong in Continue Watching. Jellyfin then omits that
  series rather than skipping ahead, and Lagoon also drops any record with
  progress or `Played=true`.
- The series detail Play button uses a separate `nextUpEpisode` request with
  `EnableResumable=true`, so it resumes.
- Never use NextUp for "what plays after this": a stop report that has not
  landed leaves the finished episode looking in progress, and NextUp returns
  it again.

For the next episode, use `Shows/{seriesId}/Episodes` with
**`startItemId=<current>&Limit=2`**, which returns `[current, next]`
regardless of watch state. With no `SeasonId` it walks the whole series, so a
binge crosses season boundaries. (`adjacentTo` returns siblings instead.)

## Images

`imageURL(for:kind:maxWidth:)` builds `Items/{id}/Images/{type}` URLs with the
image **tag** as a cache-buster, and falls back through parent artwork like the
official clients:

- episode primary → series poster (`SeriesPrimaryImageTag`)
- own backdrop → `ParentBackdropItemId`'s backdrop
- `kind: .thumb`: episode still (Primary), then `Thumb`, backdrops, poster, so
  a title with only a Primary image still fills a landscape card

A landscape card with no artwork shows its title.

## Downloads

| Purpose | Endpoint | Notes |
| --- | --- | --- |
| Original file | `GET Items/{id}/Download` | gated by the per-user `EnableContentDownloading` policy; the control is hidden without it |
| Progressive transcode | `GET Videos/{id}/stream.ts` | one MPEG-TS response, playable while incomplete, so a background `URLSession` task can carry a whole transcode. Needs a fresh `playSessionId` per request: the server keys the job on it and would reuse an abandoned job's output |
| Permission and policy fields | `GET Users/Me` | `EnableContentDownloading` and `EnableVideoPlaybackTranscoding` on `UserPolicy`, like `EnableSubtitleManagement` |

- Administrators may always download.
- Unknown or unreachable content-download permission means **no** (unlike
  subtitle management): offering a transfer the server refuses is worse than
  not offering it.
- `canDownloadContent()` and `canTranscodeForDownload()` resolve the flags
  from sign-in's policy or a lazy `Users/Me` refresh.
  `cachedContentDownloadingAllowed` and `cachedVideoTranscodingAllowed` answer
  synchronously for menu bodies. The context menu warms both with a `.task`,
  since a rail card cannot await one per tap.
- `EnableContentDownloading` decides whether the Download control or submenu
  appears. `EnableVideoPlaybackTranscoding` decides only the qualities:
  Original is always offered; High and Standard are server transcodes and are
  hidden when the account may not transcode.

## Remote subtitles

Lagoon uses Jellyfin's provider-agnostic remote-subtitle routes; no client
code knows which provider plugin answered.

| Purpose | Endpoint | Notes |
| --- | --- | --- |
| Search | `GET Items/{itemId}/RemoteSearch/Subtitles/{language}` | ISO 639-2; Apple/BCP-47 preferences are converted to three letters |
| Fetch provider file | `GET Providers/Subtitles/Subtitles/{subtitleId}` | ids are opaque and stay one percent-encoded path component |
| Persist fetched file | `POST Videos/{itemId}/Subtitles` | uploads the validated bytes as base64, avoiding a second provider download |
| Compatibility fallback | `POST Items/{itemId}/RemoteSearch/Subtitles/{subtitleId}` | for provider formats Lagoon cannot parse |

**All four need the per-user `EnableSubtitleManagement` permission, off by
default for non-administrators** since Jellyfin 10.9. Without it they answer
`403` with an HTML body. Lagoon reads `User.Policy.EnableSubtitleManagement`
(from `AuthenticateByName`, or lazily from `Users/Me` for a restored token)
and shows administrator guidance instead of a search. An unreachable server
counts as _permitted_: a network problem is never reported as a permission
problem.

Search and failures:

- Preferred languages are searched **concurrently**, then re-sorted into
  request order to keep each provider's ranking. One language failing does
  not discard another's results; a permission or session failure outranks
  other failures.
- Empty results, missing permission, absent-provider 404s, transport failures
  and download failures are distinct UI states. Automatic mode searches when
  no suitable local track exists, but never downloads silently.
- Classification: 403 permission, 401 expired session, 429 rate limit, 5xx
  provider fault, timeout. "Provider could not supply this file / download
  limit" is only for a provider 404 on the file _and_ nothing attached after
  Jellyfin's save.
- Provider calls time out at 90 s, not the 30 s default, because the server
  fans out to third parties. Retries cover only fast transient errors: not
  timeouts (already 90 s) and not 429 (a limit measured in minutes).
- A 401 or 403 on the direct fetch never falls through to the compatibility
  endpoint, which would spend provider quota to reach the same error.

Provider file limits (shared `BoundedDownload` transport):

- 8 MiB maximum, enforced per chunk as well as on declared length. The same
  cap applies to sidecars and to provider files fetched through Jellyfin.
- HTML/JSON success bodies, truncated transfers and unreadable cues are
  rejected before selecting or saving.
- HTTP errors keep at most 16 KiB of body; 401/403/429 finish without
  waiting for it.
- The captured-session check still runs first, so an old account's late 401
  cannot expire the current one.
- Oversized and invalid files get explicit errors and never trigger the
  compatibility download.

**Do not trust a 204.** Jellyfin 10.11's `DownloadRemoteSubtitles` swallows
its provider/save exception and still returns 204. So Lagoon fetches the
provider file itself, checks it has readable cues, inserts and selects it in
the running engine, and uploads the same bytes to Jellyfin for later
sessions. That is one provider download, and it works on a read-only library.
Formats Lagoon cannot parse use the native endpoint plus a PlaybackInfo poll.
Position, renderers, selected audio and Now Playing are not rebuilt; forced
and hearing-impaired flags are preserved.

**Jellyfin is the only subtitle source.** There is no direct OpenSubtitles
provider: its REST terms require one API key per application and ban asking
users for their own. Settings shows the account's subtitle permission so a
viewer knows to ask their administrator.

## SyncPlay

The server owns a group's state and tells every member _when_, on its own
clock, to unpause, pause, seek or stop. A client that acts on a command
immediately is already wrong. Probed against Jellyfin 12.0.0.

| Purpose | Endpoint | Notes |
| --- | --- | --- |
| Groups | `GET SyncPlay/List` | `[]` with no groups; also the availability probe, since a server without SyncPlay fails the route |
| Membership | `POST SyncPlay/New {GroupName}`, `Join {GroupId}`, `Leave` | 204 each. The new group's id is **not** in the response; it arrives over the socket as `GroupJoined`, like a join |
| Queue | `POST SyncPlay/SetNewQueue {PlayingQueue, PlayingItemPosition, StartPositionTicks}`, `SetPlaylistItem`, `NextItem`, `PreviousItem` | item ids go up; the group's `PlaylistItemId`s come back in a `PlayQueue` update |
| Transport | `POST SyncPlay/Unpause`, `Pause`, `Stop`, `Seek {PositionTicks}` | nothing happens locally; the server sends every member a command |
| Readiness | `POST SyncPlay/Buffering`, `Ready` `{When, PositionTicks, IsPlaying, PlaylistItemId}` | the slowest member sets the pace. `SetIgnoreWait {IgnoreWait}` stops this client holding the group up |
| Latency | `POST SyncPlay/Ping {Ping}` | milliseconds, from the clock estimate below |
| Capabilities | `POST Sessions/Capabilities/Full` | **not** needed for command delivery. Sent so the session appears controllable; `SupportedCommands` stays empty until the player handles `GeneralCommand` |

**The socket.** `wss://<server>/socket?api_key=<token>&deviceId=<id>`, built
from `serverRelativeURL("socket")` with the scheme swapped, so a reverse-proxy
base path survives. It is the one first-party URL with the token in its query,
because the handshake was not verified to carry the `Authorization` header.

- Envelope: `{"MessageType", "MessageId"?, "Data"}`. `MessageId` has been
  absent on every SyncPlay message. `Data` can be an object
  (`SyncPlayGroupUpdate`), a bare integer (`ForceKeepAlive`) or a bare string
  (`GroupLeft`), so `ServerSocket` splits the envelope with
  `JSONSerialization` and re-serialises `Data` for the caller to decode.
- An unknown `MessageType` is ignored, never a decoding failure.
- `ForceKeepAlive` carries a timeout in seconds (60 observed). Reply
  `{"MessageType":"KeepAlive"}` at once, then every half-timeout. The server
  echoes it; neither is forwarded.
- Reconnect backs off 1, 2, 4, 8, 16, 30 s with ±20 % jitter, reset once a
  connection delivers a message.

**Group ids have two spellings.** `GroupId` fields are undashed lowercase hex;
`GroupLeft`'s payload is the dashed form. Compare through
`SyncPlayGroupIdentifier`, never `==`. It also recognises the all-zero
`PlaylistItemId` on the `Stop` a new group receives.

**The clock.** `GET GetUtcTime` returns `{RequestReceptionTime,
ResponseTransmissionTime}`; with the local send and receive instants, that is
NTP's four-timestamp measurement. `ServerClock` keeps the last eight samples
and uses the one with the _lowest_ round trip, never an average: a slow sample
is asymmetric, not noisy. It samples three times a second apart, then once a
minute.

**The timestamp exception.** Those timestamps and SyncPlay's `When`,
`EmittedAt` and `LastUpdate` are wall-clock instants the protocol needs. They
stay `String` on the DTOs and convert only through `JellyfinTimestamp`, which
parses `yyyy-MM-ddTHH:mm:ss[.f{0,7}]Z` by hand (6 and 7 fraction digits appear
in the same response) and writes the seven-digit form back. A non-UTC offset
is refused.

**Permission.** `Users/Me` → `Policy.SyncPlayAccess` is
`CreateAndJoinGroups`, `JoinGroups` or `None`, decoded onto `UserPolicy` with
an `unknown` fallback for a missing answer. Unknown is not a denial: say the
permission could not be checked.

## Seerr title details, cast and recommendations

A Seerr title page reads `movie/{id}` or `tv/{id}`:

- `credits.cast` and `credits.crew` carry TMDB billing, with `profilePath` for
  headshots.
- Age rating comes from a movie's `releases` or a show's `contentRatings`:
  the viewer's region first, US as fallback. Those two blocks are snake_case
  on the wire, unlike the rest of Seerr, so their DTOs carry their own keys.
- "More Like This" is `movie/{id}/recommendations` or
  `tv/{id}/recommendations`. TMDB's `similar` list is keyword-matched and
  weaker, so it is not used. Recommendations load once; live refresh re-reads
  only the details.
- Discovery titles use their name in type unless a matching Jellyfin item has
  a Logo image.

## App Transport Security

`LagoonInfo.plist` declares **`NSAllowsLocalNetworking` only**, with no
`NSAllowsArbitraryLoads` (an App Store requirement). Plain-http LAN servers
still work:

- **IP literals** are exempt from ATS entirely.
- **`.local` names** and **unqualified hostnames** (`http://mediaserver:8096`)
  are covered by `NSAllowsLocalNetworking`.
- Cleartext to a fully-qualified public domain is blocked, as intended: a
  remote server must be https.

Apple's documentation and CVE-2023-38596 disagree about the IP-literal
exemption, so it was measured on tvOS 26.2: plain http to `192.168.1.173:8096`
opened a real TCP flow and failed `-1001` with no ATS objection. If a future
OS changes it, point `server.url` at a dead LAN port: `-1001`/`-1004` means
allowed, `-1022` (before any socket work) means blocked.

Discovery order is unchanged: HTTP first for IP/`.local` input, HTTPS first
otherwise. Public-host HTTP candidates stay subject to ATS.

## Server address entry and discovery

Jellyfin and Seerr parse user-entered service roots with
`Shared/Networking/ServerAddress.swift`. An address may include host, port and
reverse-proxy base path.

- Explicit `http://` or `https://` selects exactly that transport and port.
  Discovery never downgrades explicit HTTPS or adds a default port to it.
- Surrounding whitespace and trailing slashes are normalized.
- Schemeless input uses the discovery order above. With no port, Jellyfin also
  tries 8096 and Seerr 5055. Ports go through `URLComponents.port` before the
  path, so `media.example/jellyfin` can become
  `http://media.example:8096/jellyfin`.
- Bracketed IPv6 literals (with or without port) and internationalized
  hostnames work.
- A trailing `/api/v1` on Seerr input is removed once, so the API prefix is
  appended once. Stored URLs are treated as service roots and never stripped
  again, even if the proxy root ends in `/api/v1`.
- Normalization uses `percentEncodedPath`, so an escaped slash in a proxy path
  stays escaped.
- Rejected before discovery: credentials in the URL, query strings,
  fragments, unsupported schemes, malformed escapes, missing hosts, invalid
  ports, internal whitespace.

Sign-in and Seerr settings show the full scheme, host, port and path. HTTP
connections show a warning about password, token and activity exposure before
the sign-in controls, including on restored sign-in screens. Legacy embedded
credentials and query strings are redacted from that display.

Coverage: `ServerAddressTests`, `SeerrClientTests`, `ServerAddressUITests`.
Run the UI journey on fresh simulators with:

```sh
python3 scripts/test-session-recovery.py --server-address
```

The fixture requires proxy paths and checks Jellyfin sign-in and Seerr
discovery. iOS covers typed setup and invalid-input recovery; tvOS covers
restored sign-in, remote focus and a restored Seerr pairing. The HTTPS
disclosure check is a UI check, not a TLS test. Physical-network acceptance is
still owed.

## Home Screen Sections plugin

An optional server plugin. Without it the route 404s and Home uses Lagoon's
own rails.

- `GET HomeScreen/Sections?userId=` returns the section **catalogue**.
- `GET HomeScreen/Section/{sectionKey}?userId=` returns one section's items as
  an ordinary `ItemsPage`.

**The catalogue is not a layout.** It returns all 28 section types the plugin
knows (Books, Music and Jellyseerr included, even on a movies-and-TV server),
each with `OrderIndex` 999 and `Limit` 1. The admin's enabled set is not
readable anywhere (`HomeScreen/UserSettings`, `/Settings`, `/Config` and
`/Users/{id}/Settings` 404; `DisplayPreferences/usersettings` has no
`homesection*` keys).

Rendering it wholesale would repeat rows: the same server offers
`ContinueWatching`, `NextUp` and `ContinueWatchingNextUp`, plus `LatestMovies`
and `RecentlyAddedMovies`. So `HomeViewModel.nativelyCoveredSections` drops
every section Lagoon already draws, and only the rest is appended.

Arrangement (Settings › Home Rows):

- One ordered list covers native and plugin rows, so a plugin row can sit
  anywhere. With no stored arrangement, Lagoon's default order applies and
  remaining plugin sections follow it. Once the viewer arranges rows, that
  order wins and hides what it leaves out.
- Natively covered sections are never offered, so an arrangement cannot bring
  back a duplicate.
- Keyed by server and user. A catalogue entry found after plugin rows were
  arranged starts hidden; for an account that only ever hid native rows it
  starts shown.
- Rows are never pruned: a failed `homeSections()` returns an empty
  catalogue, and pruning would erase the order the first time the server was
  slow.
- A row added by a later Lagoon build is inserted at its designed place, not
  appended after the plugin rows.

On a plain movies/TV server this correctly shows **nothing** new; it matters
with Jellyseerr requests, My List, Discover or custom collection sections. All
28 sections resolve in about 1.8 s concurrently (empties about 0.1 s each), so
they load eagerly.

### Top 10 rows

- Source: Seerr's authenticated `discover/movies` and `discover/tv`, trending
  merged ahead of popular.
- A bounded, paginated library scan intersects each list with the user's
  Jellyfin items by exact `ProviderIds.Tmdb` match within the same movie or TV
  catalogue. Duplicate editions and repeated ids take one slot.
- Fewer than four matches omits the row, and so does an unconfigured Seerr
  connection. Rows contain only playable library items; no title or year
  guessing.
- Top 10 loads independently, so a slow catalogue never delays the native
  shelves.
- Legacy Home Screen Sections Manager sections still work; its ranked-section
  API is not needed.

This approximates popularity; it is not a personal `PlayCount` substitute.

## Testing without a home server

The public demos use user `demo` with an empty password:

- `https://demo.jellyfin.org/stable`: the supported 10.x baseline.
- `https://demo.jellyfin.org/unstable`: the Jellyfin 12 pre-release
  (`12.0.0`).

Both work for sign-in, navigation and playback regression runs, but their
libraries can change.
