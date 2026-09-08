# Transport spike: FFmpeg without a network stack

September 8, 2026, branch `spike/urlsession-transport`, based on build 0.1 (91)
after HEL-146. This is the measured record behind a go/no-go on moving every
HTTP byte libavformat reads onto URLSession and dropping the GnuTLS stack.
The mechanism itself is documented in [playback.md § Network transport](playback.md#network-transport);
this file records why, what was found on the way, and what the numbers say.

## Why

The 1.0 audit left three gates that all trace to one dependency: libavformat's
own network stack and the GnuTLS/GMP/nettle/hogweed libraries it linked.

- A01 verified TLS on the simulator but still owed physical-device acceptance
  of a vendored TLS implementation.
- A05 had to cover LGPLv3 components, because GMP and nettle are LGPLv3 and
  GnuTLS forced `--enable-version3` onto the FFmpeg build.
- A07 could not record an encryption classification while a non-Apple TLS and
  bignum implementation was bundled.

Removing the stack settles all three at once, and it has to land before the
device-acceptance evening or those runs measure a transport that changes.

## What was built

- `FFmpegNetworkTransport` installs on every `AVFormatContext` and owns
  `io_open`/`io_close2`. HTTP and HTTPS opens become a `URLSessionByteSource`
  behind the existing `FFmpegCachedIO` bridge: one ranged GET streamed with
  backpressure, retries from the current position, a 15 s idle timeout and the
  demuxer's interrupt polled every 100 ms. `crypto+https://` segments decrypt in
  Swift with CommonCrypto. `file:` and `data:` still use `avio_open2`.
- libavformat n8.1.2 rebuilt with `--disable-network --disable-protocols
  --enable-protocol=file --enable-protocol=data`, no GnuTLS patch, no version3.
  The package drops four binary targets; the xcframework is 15 MB instead of
  19 MB. `BUILD.json` records `network: false`, `license: LGPL-2.1-or-later`
  and the hash of the one patch that remains.
- The demuxer no longer sets `tls_verify`, `rw_timeout` or `reconnect*`, no
  longer calls `avformat_network_init`, and sets `http_persistent=0`.
- `MediaRequestAuthorization`: the Jellyfin token leaves the URL and travels
  as the `Authorization` header on same-origin requests only, dropped on any
  cross-origin redirect. Built by the client, handed through `prepare` and the
  demuxer to the transport.
- 16 new unit tests: 13 against a scripted `URLProtocol` stub for the byte
  source, the transport and the credential handling, 3 for the native side
  including the invariant that no http, https, tcp or tls protocol is linked.

## What the unit tests could not have found

**hls.c refuses URLs whose scheme has no registered protocol.** The first
build passed every suite and then failed real playback: "The stream could not
be opened (Invalid data found when processing input)" on the negotiated rung
and again on the remux rung. `open_url` in hls.c asks `avio_find_protocol_name`
for the scheme and returns `AVERROR_INVALIDDATA` when nothing answers, which
without a network stack is every http(s) URL, before `io_open` is consulted.
`Patches/0001-hls-scheme-without-network-protocols.patch` lets it classify
`http:`/`https:` from the URL text (also behind `crypto+`) and hand the open to
`io_open`. The build script applies it, records its hash, and `--verify-only`
fails if it changes.

**Keepalive leaks a context per segment.** hls.c reuses a segment's connection
only through FFmpeg's own HTTP protocol; with that compiled out,
`open_url_keepalive` returns `AVERROR_PROTOCOL_NOT_FOUND`, hls.c falls back to
`io_open` for the next segment and overwrites the pointer to the previous one
without closing it. Over a two-hour film that is roughly 1,200 leaked
`AVIOContext`s at a few hundred kilobytes each. `http_persistent=0` makes hls.c
close every segment through `io_close2` as it finishes. The demuxer used to set
the same option for the experimental HLS cache for a related reason.

**CFNetwork logs the URL of every failed request.** The first certificate
matrix run passed all 32 cases and then failed the script's last guard: the
synthetic query token appeared in the test log 137 times. Not a Lagoon print;
CFNetwork writes a failed task's `NSError`, `NSErrorFailingURLKey` and all,
to the unified log, and Jellyfin media URLs carry the access token as a query
item. The playback cache's ranged requests have exposed the same class on
main since HEL-86; the transport made it frequent, because now every failed
manifest, segment or key fetch is a URLSession task. The fix is to carry the
credential as a request header for the server's origin only:
`MediaRequestAuthorization` strips `ApiKey`/`api_key` from the URL and sets
the `MediaBrowser … Token=` header on same-origin requests, the delegate drops
the header on any cross-origin redirect, and the fixture script no longer
plants the token in its redirect target. The cache's own requests still use
the query form and are the next candidate for the same treatment.

## Measurements

Fixture: *Deadgirl* on fixture, 1080p HEVC SDR at 2.2 Mbps, which the
simulator's forced-transcode profile turns into a server HLS transcode
(`Method: Transcode (hls)` in the HUD). Pinned start at 600 s, 10 s warm-up,
60 s window, Apple TV 4K (3rd generation) simulator, three runs each, nothing
else running. Both builds were driven through the app's launch-time bench hook
rather than the bench script (see *Found on the way*).

| Build | Runs | Dropped | Stalls | Frames in window | Peak memory |
|---|---|---|---|---|---|
| Native transport (build 91 as merged) | 3 of 3 | 0, 0, 0 | 0 | 1450, 1475, 1475 | 115, 129, 136 MB |
| URLSession transport (this branch) | 3 of 3 | 0, 0, 0 | 0 | 1450, 1475, 1475 | 125, 136, 130 MB |

Nothing distinguishes the two. Frame counts are identical run for run, no
stall or audio starvation counter moved, memory sits in the same band. The
first URLSession attempt, before the hls.c patch, produced no bench result at
all in three runs, which is the failure described above. A single smoke run of
the final build, with the credential carried as a header, read 0 dropped, 0
stalls and 1475 frames again.

| Check | Result |
|---|---|
| tvOS simulator build | Passed |
| iOS simulator build | Passed |
| iOS unit suite | 553 tests in 63 suites passed |
| tvOS unit suite | 577 tests in 65 suites passed (a pre-existing timing test flaked in two earlier full runs and passed alone; see below) |
| Native networking compiled out | Passed on both platforms |
| 32-case certificate matrix (`scripts/test-ffmpeg-tls.py`, tvOS and iOS) | Passed on both: every invalid peer rejected, every valid and reconnect case completed, no request reached an invalid peer, and the synthetic token appears nowhere in either test log |
| Direct and HLS session-recovery lane (`scripts/test-session-recovery.py`, tvOS) | Passed: direct/HLS playback, revocation, sign-in and resumed playback |

## Found on the way

- **The bench script's deep link no longer resolves.** HEL-141 made
  `lagoon://play/{id}` require an owner hash and a Top Shelf generation, so
  `scripts/framedrop-bench.sh` seeds a resume point and then opens a link the
  router now drops. The app's launch-time hook (`debug.frameLossBench` with
  `debug.benchSearchTerm`, `debug.benchStartSeconds` and `debug.benchAutoExit`)
  still works and is what this record used; the script and the bench section of
  playback.md need updating to it. That hook resolves movies only, by exact
  title, so episodes cannot be benched this way.
- **`PlaybackReportLedgerTests` has a tight wall-clock bound.** Two tests
  assert a wait finishes in under 2 s and measured 2.03 to 2.09 s during full
  tvOS suite runs, then pass in 0.18 s alone. Unrelated to the transport;
  worth loosening or restructuring.
- **The three MPVKit-built libraries still say LGPL v3.** libavcodec,
  libavutil and libswresample were configured upstream with
  `--enable-version3` (`CONFIG_VERSION3 1` in their headers), so
  `avcodec_license()` keeps answering v3-or-later although nothing v3-only is
  linked into them. Rebuilding them in-repo the way libavformat is built is the
  remaining step for an unambiguous licence record.
- **`scripts/inventory-native-dependencies.py` hard-coded eleven targets.**
  Changed to seven; `docs/native-dependency-inventory.json` regenerated with
  7 dependencies and 50 slices.

## What this does not settle

- Physical-device playback over the new transport. The certificate matrix and
  the session lane run on simulators; a real Apple TV and iPhone still owe a
  direct-play, HLS, seek, reconnect and interruption pass, which is the same
  acceptance evening the audit already asks for.
- The licence decision. The inputs are now LGPL-2.1-or-later plus BSD and MIT
  once the three MPVKit libraries are rebuilt, which is a far easier set to
  cover, but attribution, corresponding source and the static-linking
  arrangement still need the qualified read HEL-143 calls for.
- Expensive-path flags. The transport does not mark its requests as
  disallowing expensive or constrained networks; the metered cap is applied at
  negotiation (HEL-108), as before, and the cache's proactive fills keep their
  own flags.

## Recommendation

Go. The transport is at parity on the one workload that exercises it
end-to-end, the network stack and its licence baggage are gone, the invariant
is pinned by a test, and the two failures the unit tests could not see were
found by the bench and fixed with a nine-line patch and one option. Both fixture lanes
pass. Merge, then run the device-acceptance evening against this build.
