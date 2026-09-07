# Subtitle and artwork download hardening — audit A15

Implementation date: September 8, 2026. App version remains `0.1 (90)`.

This addresses [A15 in the release audit](1.0-release-readiness-and-app-store-audit.md#a15--p2-external-subtitle-and-artwork-downloads-need-bounded-explicit-failure-handling).
It does not close A14's watched/favourite reconciliation, A16's OpenSubtitles
account/consumer readiness, or the physical-device acceptance matrix.

## Viewer behavior

Choosing an external subtitle keeps the working track selected and its captions
visible while the new file downloads and parses. Only a usable replacement is
committed. Failure leaves the existing captions and video playing, shows the
failed track and an explanation in Subtitles, and offers **Retry Subtitle**.
A notice over the video directs the viewer back to Subtitles when the panel is
closed. Choosing Off clears the captions and error immediately.

HTTP access failures, unavailable files, server errors, invalid content, size
limits and connection failures have distinct explanations. An external CDN's
401 is an access error for that file; it does not falsely sign the viewer out
of Jellyfin. Authenticated Jellyfin provider requests retain the client's
account-specific expiry behavior and reject responses from an older session.

Artwork failures keep the normal placeholder. Invalid or incomplete images are
not cached as successes. Cancelling one view's image request does not cancel a
shared request still needed by another view; the last cancellation stops it.

## Bounds and ownership

| Resource | Response bound | Additional checks |
| --- | --- | --- |
| External subtitle sidecar | 8 MiB | HTTP 200, content validation, readable cues before replacement |
| Jellyfin provider file | 8 MiB | Existing authentication/session checks; validate before insertion/upload |
| Direct OpenSubtitles file | 8 MiB | Temporary file URL receives no provider API key or bearer token; validate before disk caching |
| Artwork, Top Shelf source, Now Playing art, trickplay sheet | 16 MiB | HTTP/content validation and complete ImageIO source before thumbnail decoding |
| Moviehash first/last range | 64 KiB each | HTTP 206 and exact byte count; ignored Range cannot download the whole movie |
| HTTP error body | At most 16 KiB | 401/403/429 finish at the response header without waiting for a body |

These are binary limits (1 MiB = 1,048,576 bytes); subtitle UI uses the familiar
“8 MB” wording. They are Lagoon's defensive limits, not requirements imposed by
Apple or Jellyfin. A legitimate larger file is rejected and another track or
smaller image is needed.

`BoundedDownload` receives URLSession delegate chunks and checks remaining
capacity before appending each one. Declared Content-Length can reject early
but is not trusted to enforce the limit: absent or understated lengths and
decompressed bytes remain bounded. Uncompressed declared-length mismatches are
rejected. HTML/JSON success MIME types are rejected for subtitle/image content;
parsing also checks subtitle content and valid finite cue times. ImageIO must
report a complete source and first image before decoding a bounded thumbnail.
Apple documents the delegate's incremental delivery in [Fetching website data
into memory](https://developer.apple.com/documentation/foundation/fetching-website-data-into-memory).

The download session bypasses URL caches and cookies, uses platform TLS trust,
and rejects HTTPS-to-HTTP redirects. Per-resource work has a 90-second timeout;
the existing shorter request timeouts still apply. Successful subtitle parsing
runs off the main actor with cancellation checks. A newer track selection or
engine shutdown cancels the old transfer and invalidates its generation; a late
provider result also checks the engine's selection revision before insertion.
Embedded cue writes and external replacement commits use the same engine lock.

Direct-provider cache reads stop at the subtitle cap plus one byte. New files
are saved only after parsing; an invalid cached file is removed so a later
explicit retry can download fresh bytes. HTML and oversized responses do not
invoke Jellyfin's compatibility fallback or an automatic provider retry.

Decoded artwork budgets remain explicit: Now Playing uses 1024 pixels; Top
Shelf composition sources use 3840 for backdrops and 1920 for logos; normal
cards retain `ArtworkSizing`. Trickplay keeps two decoded sheets and at most
32 MiB of compressed sheets, with a 3200-pixel thumbnail ceiling and obsolete
transfers cancelled when a new uncached sheet is requested. The ordinary image
cache remains 200 images / 50 MiB of decoded cost. The caps bound each response;
they are not a global process-memory budget or a measured hardware peak.

## Regression coverage

`DownloadHardeningTests` drives the real downloader, image cache, Jellyfin client,
subtitle coordinator and sample-buffer engine with controlled URLProtocol
responses. Cases cover HTTP 401/403/404/500; declared and streamed oversize;
absent, false and compressed-length metadata; exact limits; truncated responses;
HTML; invalid cue times; pre-cancellation and active cancellation; shared image
waiters; malformed images and successful retry; ignored movie ranges; provider
errors and account-generation races; retained captions through failed/retried
replacement; superseded choices, Off, provider results and shutdown.
`SubtitleProviderTests` also exercises the actual OpenSubtitles file-download
limit and verifies that the signed file request carries no provider credentials.

The `--subtitle-downloads` lane in `scripts/test-session-recovery.py` builds and
runs `SubtitleDownloadUITests` on disposable iPhone and Apple TV simulators.
Its loopback fixture serves synthetic H.264/AAC playback plus a working track,
a track that returns 500 until explicitly recovered, and a small gzip response
that expands to 8 MiB + 1 byte. The UI journey selects those tracks, retries,
checks retained/recovered captions and advancing video time, then selects Off.
The runner verifies fixture request counts so a skipped or simulated UI result
cannot pass. Real credentials, library writes and provider quota are not used.

## Validation evidence

All commands use Xcode's Apple Swift/Clang toolchain. No GCC compiler or native
artifact rebuild is involved. Simulator runtime versions are iOS 26.5 and
tvOS 26.5.

- Complete iOS unit suite: **552 tests in 61 suites passed**,
  `/private/tmp/lagoon-a15-full-ios-final.xcresult` and the adjacent `.log`.
- Complete tvOS unit suite: **576 tests in 63 suites passed**,
  `/private/tmp/lagoon-a15-full-tvos-final.xcresult` and the adjacent `.log`.
- iPhone UI journey: **1 test passed**, with screenshots and fixture request
  assertions in `/private/tmp/lagoon-hel142-validation/20260908-004329/iOS/`.
- Apple TV UI journey: **1 test passed**, with screenshots and fixture request
  assertions in `/private/tmp/lagoon-hel142-validation/20260908-010229/tvOS/`.
- Unsigned iOS and tvOS device Release builds: **passed**;
  `/private/tmp/lagoon-a15-release-ios-accepted.log` and
  `/private/tmp/lagoon-a15-release-tvos-accepted.log`.

The iPhone run verifies that Retry does not also trigger a provider search:
the button uses an independent action inside the shared Form row. Screenshots
show the server error, size-limit message, selected previous track, retained
captions, recovered captions and Off. The fixture's compressed oversize case
exercises actual Foundation gzip decompression, separately from the unit
fixtures that control delivered chunks and length metadata.

On tvOS, XCTest's `hasFocus` reports false for the conditionally inserted Retry
button even when the player's `FocusState` reports `track-subtitle-retry`.
The test uses the existing, observation-only playback probe for that one
control, then presses the real remote Select button and checks caption recovery
and the fixture's exact request count. It also waits for the actual panel-open
state, because the mounted but hidden panel still exposes accessibility nodes.
No test hook selects a track or invokes Retry directly.
The final tvOS journey also checks that the normal “Swipe down for Info” hint
is absent while the subtitle error notice occupies that space. Screenshots on
both platforms were reviewed for the error, retained caption and retry states.

The complete suite intentionally skips its two opt-in native TLS/allocation
stress functions. Those are not claimed as rerun here. An initial iOS unit
launch hit a simulator cold-start/preflight failure before executing tests;
fully booting the simulator resolved it. UI development also corrected test
taps on partly clipped iPhone rows by expanding the native sheet first.

Reproduce the UI lane with:

```sh
python3 scripts/test-session-recovery.py --work /private/tmp/lagoon-hel142-validation --subtitle-downloads
```

Run the complete hosted unit suites with `xcodebuild test -scheme Lagoon
-only-testing:LagoonTests`, an iOS/tvOS simulator destination and the platform's
DerivedData directory. After building `LagoonHardwareRegression`, use `test`
to rebuild the unit-test host; that UI scheme does not retain the hosted
`LagoonTests.xctest` bundle for `test-without-building`.

## Remaining acceptance

Physical iPhone, iPad and Apple TV testing still belongs to HEL-144: poor Wi-Fi,
server/proxy variations, memory pressure, large track lists, VoiceOver/Dynamic
Type, actual remote handling and long playback. Simulator assertions and
unsigned Release compilation do not certify those behaviors. Native TLS and
allocation stress lanes are separate opt-in checks; this change does not alter
the native artifacts. Existing unrelated build warnings remain tracked by the
audit's warning/concurrency findings.
