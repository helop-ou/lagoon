# Network transport

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [current playback guide](../../playback.md) and the
[notes index](README.md).

## Network transport

libavformat's own network stack is gone. The owned build
(`scripts/build-ffmpeg-format.py`) passes `--disable-network
--disable-protocols --enable-protocol=file --enable-protocol=data`, so the
library that used to speak HTTP/HTTPS/TLS itself now opens only local files
and `data:` URIs — there is nothing left inside FFmpeg for a certificate to
fool. That also dropped the GnuTLS/GMP/nettle/hogweed static libraries and
the `--enable-version3` GnuTLS's license required, so libavformat's build
is plain LGPL-2.1-or-later, and the xcframework shrank from 19 MB to 15 MB
(libavcodec, libavutil and libswresample are still MPVKit's binaries, built
upstream with version3 on). One patch remains,
`Patches/0001-hls-scheme-without-network-protocols.patch`:
hls.c refuses any child URL whose scheme has no registered protocol, which
without a network stack is every http(s) URL, so the patch lets it classify
the scheme from the URL text and hand the open to `io_open`. Without it a
transcode fails to open with "Invalid data found when processing input"
before the transport is ever asked.

`FFmpegNetworkTransport` installs on every `AVFormatContext` the demuxer
opens and owns `io_open`/`io_close2`. Every http/https open the demuxer
makes — the top-level URL, every HLS child playlist, segment and key —
becomes a `URLSessionByteSource` behind the existing `FFmpegCachedIO`
bridge: a ranged GET streamed with backpressure (suspended above 8 MiB
buffered, resumed below 2 MiB), a 206 at the requested offset or a 200 at
offset 0 (or with a bounded discard up to 4 MiB) both accepted, any other
status is an I/O error and never reported as EOF, transient errors retry
from the current position up to 3 times (0.25/0.5/1 s) while 4xx never
retries, a 15 s idle timeout applies, and the demuxer's interrupt callback is
polled every 100 ms.

`crypto+https://…` opens — hls.c's own scheme for AES-128 segments — can't
sit on custom I/O, so they don't go through FFmpeg's crypto protocol at all:
`AES128CBCByteSource` fetches and decrypts them in Swift with CommonCrypto
instead. `file:` and `data:` opens still go straight to `avio_open2`, since
neither carries a network trust decision.

The credential travels as a header, never in the URL. CFNetwork writes a
failed task's full URL into the unified log, so a query token would have
leaked into diagnostics on every failed segment fetch; a header never does.
`MediaRequestAuthorization` (built by
`JellyfinClient.mediaRequestAuthorization()`, handed from the playback
controller through `prepare` and the demuxer to the transport) sets the
`Authorization: MediaBrowser … Token="…"` header on every same-origin
request instead, and strips `ApiKey`/`api_key` from a URL that already
carries one — a server-supplied `TranscodingUrl` can still arrive with
either spelling — before issuing it; requests to any other origin are left
exactly as given, and the session delegate drops the header on a
cross-origin redirect. The playback cache
(`URLSessionPlaybackRangeLoader`/`PlaybackRangeRequest` in
`Lagoon/Views/Player/PlaybackCache.swift`) applies the same authorization to
every ranged request it makes, including HLS child playlists and segments
whose server-generated URLs may still carry `api_key`. No first-party media
request built by this app carries the token in its URL any more.

Certificate trust is now whatever URLSession enforces: ordinary system trust
evaluation, which rejects self-signed, expired and wrong-host peers and
requires a private CA to be installed on the device rather than trusted by
the app. The experimental HLS cache still leases immutable segments when
enabled, on the same transport. FFmpeg's raw stderr logging is still
disabled, because its HLS errors print complete token-bearing URLs; that
suppression now lives in the transport, alongside Lagoon's error-code and
playback diagnostics.

The demuxer (`FFmpegDemuxer.swift`) no longer sets `tls_verify`,
`rw_timeout` or any `reconnect*` option, and no longer calls
`avformat_network_init` — none of it means anything to a build with no
network protocols. It does still set `http_persistent` to 0: hls.c's
keepalive reuses a segment's connection only through FFmpeg's own HTTP
protocol, and left on it falls back to `io_open` for every segment while
keeping the previous context alive, one leaked `AVIOContext` per segment.
Off, each segment closes through `io_close2` as it finishes.

Rebuild with `scripts/build-ffmpeg-format.py`, verify with
`--verify-only` (checksums, absent http/https/tls/tcp/udp protocol symbols,
no gnutls/nettle/gmp references, `CONFIG_NETWORK 0`, `CONFIG_HLS_DEMUXER 1` —
read from both `config.h` and `config_components.h`, since FFmpeg 8 split
component flags into a second header), and run the controlled simulator
certificate matrix with `scripts/test-ffmpeg-tls.py --all-unit-tests`, which
drives its 32 cases through `FFmpegNetworkTransport` instead of libavformat's
own TLS. `LagoonTests/URLSessionByteSourceTests.swift` covers the transport
against a scripted `URLProtocol` stub (streaming, seek restart, non-ranged
servers, retried and non-retried failures, dropped connections, interrupts,
AES-128 decryption, close/closeAll), and `LagoonTests/FFmpegTransportTests.swift`
checks that network is compiled out of libavformat, that an interrupted open
returns `AVERROR_EXIT`, and runs the same certificate matrix through the
transport.

Build provenance, exact behavior and prerequisites are documented in
[`Libavformat.README.md`](../../../Packages/LagoonFFmpeg/Artifacts/Libavformat.README.md).

## Malformed discs and expired sessions (HEL-142)

UDF mounting and Blu-ray/DVD title selection share a cancellable work budget:
64 KiB per metadata read, 32 MiB requested in total, 2,048 reads, 100,000 checked
operations and a 30-second deadline checked between synchronous reads and in
parser loops. Partition/image bounds, exact reads, descriptor and playlist
sections, continuation cycles and cumulative extent arithmetic are validated.
Metadata cache reads bypass streaming read-ahead; ordinary playback retains it.
Unsupported or malformed discs follow the existing server-delivery fallback.
The demuxer owns its native context from allocation, so setup failures release
it even before `avformat_open_input` runs.

Authenticated API 401s expire only the request's captured account session.
The app dismisses playback and opens sign-in for that server, retaining its
username, remembered identity and preferences. Reauthentication replaces the
rejected token. Progress reporting also uses this path, so remote revocation
while buffered media plays is detected on the next authenticated report;
there is no new expiry polling or startup network probe. Outages and 403s
preserve credentials; late responses cannot expire a newer session.

`python3 scripts/test-session-recovery.py` exercises direct and native HLS
playback, remote revocation and sign-in against a loopback synthetic server;
the [HEL-142 validation record](../../archive/hel-142-native-tls-validation.md)
documents the bounds and regression coverage behind both sections.
