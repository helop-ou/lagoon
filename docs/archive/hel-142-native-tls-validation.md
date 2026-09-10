# HEL-142: transport, malformed-media and session-recovery validation

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

**Superseded, September 8, 2026:** the GnuTLS-based `tls_verify`
verification this record documents was replaced on the `spike/urlsession-transport`
branch by `FFmpegNetworkTransport`, which moves every HTTP open onto
URLSession and removes libavformat's network stack (and GnuTLS with it) —
see "Network transport" in [`playback.md`](../reference/playback/README.md). The 32-case
certificate fixture matrix below is unchanged and remains the acceptance
test, now run through the new transport instead of libavformat's own TLS.
This document otherwise stands as the historical record of the GnuTLS-based
implementation.

Implemented and validated September 7, 2026, against FFmpeg n8.1.2 and Xcode
26.6 (17F113), with iOS/tvOS 26.5 simulator runtimes. App version remains
0.1 (90); this work does not cut or upload a release.

Implementation is complete for [HEL-142](https://helop-ou.atlassian.net/browse/HEL-142):
native TLS trust, bounded disc parsing, early native-context cleanup, and
account-specific recovery after authenticated 401 responses. Physical-device
runtime acceptance remains pending; simulator and build evidence cannot
substitute for it.

## Reproduction and change

The original app-linked iOS **and** tvOS simulator binaries accepted
self-signed, expired and wrong-host certificates with native defaults. Local
server request logs recorded the synthetic query token at all three invalid
peers. Enabling `tls_verify=1` with the old binary rejected the valid fixture
too, despite its root being installed in that simulator: GnuTLS 3.8.11 does
not load the iOS/tvOS system trust store.

Lagoon now builds libavformat from the same source release, enabling
verification by default and evaluating the actual GnuTLS peer chain and
hostname with Apple's public Security APIs. The application enforces this at
native opens, including HLS cache fallbacks, and preserves parent interruption
and protocol restrictions. Native HLS persistence and reconnect behavior stay
enabled. The raw FFmpeg stderr logger is suppressed because HLS error messages
otherwise print complete credential-bearing URLs; Lagoon's error-code and
playback diagnostics remain available.

The exact trust behavior, source checksum, patch, rebuild command, notices and
artifact provenance are in
[`Libavformat.README.md`](../../Packages/LagoonFFmpeg/Artifacts/Libavformat.README.md).
Apple system and installed roots apply. Network fetching during trust
evaluation is disabled, so servers must send their intermediate certificates.
There is no trust-all fallback, private API or additional app dependency.
All compiler roles explicitly use Apple Clang, including host tools.

## Automated evidence

| Check | Result |
| --- | --- |
| Original iOS and tvOS binary reproduction | Both failed the verification-default and controlled-certificate tests; invalid peers received the synthetic token |
| Complete iOS unit suite after parser, cache and recovery changes | 497 tests / 55 suites passed, including all 32 TLS cases |
| Complete tvOS unit suite after parser, cache and recovery changes | 521 tests / 57 suites passed, including all 32 TLS cases |
| Failed-open native allocation stress, iOS simulator | 2,000 disc-setup failures: −400 live heap bytes; 2,000 custom-I/O failures: −116,864 bytes |
| iOS and tvOS actual app recovery, direct and native HLS | Four journeys passed: play, revoke, sign in, resume; touch/remote controls and screenshots checked |
| Final unsigned iOS device Release build | Passed |
| Final unsigned tvOS device Release build | Passed |
| Vendored artifact verification | Patch/file checksums and Apple trust calls verified across all 8 architectures in 5 platform groups |
| Upstream versus rebuilt libavformat capability inventory | All 119 demuxer/muxer/read-protocol/write-protocol entries identical; none removed or added |
| Public system-trust smoke check | Patched macOS arm64 native probe accepted Jellyfin's public demo HTTPS endpoint |

Both complete suites include native logging suppression and the parser, cache,
context-ownership and session-recovery changes. Opt-in native allocation stress
runs separately to avoid unrelated concurrent test allocations. Test counts
include gated tests: the TLS matrix was explicitly enabled on both platforms,
and the allocation stress was explicitly enabled in its separate run. Release
builds pass with existing concurrency diagnostics; this ticket does not claim
a warning-clean Swift 6 migration.

Each platform's 32-case matrix covers:

- Direct native requests with default settings and application enforcement:
  trusted, self-signed, expired, wrong-host, and plain HTTP endpoints.
- A trusted HTTPS redirect to each of four certificate classes.
- HLS variant playlists, segments, a later segment after playback starts,
  and AES-128 key requests targeting each certificate class. Valid streams
  read three segments with native persistent connections enabled.
- Successful reconnection after a partial response, and rejection when the
  next handshake presents an invalid certificate.

The suite also checks the actual linked TLS AVOption default and parent
cancellation. The servers record requests independently of FFmpeg's return
values. No HTTP request may reach an invalid peer, including during a failed
reconnect. The harness fails if the matrix is skipped or its synthetic token
appears in the final test log. Test roots were installed only on newly created
disposable simulators; those simulators were deleted after each run.

Reproduce with:

```sh
python3 scripts/build-ffmpeg-format.py --verify-only Packages/LagoonFFmpeg/Artifacts/Libavformat.xcframework
python3 scripts/test-ffmpeg-tls.py --all-unit-tests --work /private/tmp/lagoon-tls-validation
```

Local evidence from this session (temporary, not committed):

| Evidence | Location |
| --- | --- |
| Original iOS baseline | `/private/tmp/lagoon-hel142-baseline/iOS/TLS.xcresult` and `requests.json` |
| Original tvOS baseline | `/private/tmp/lagoon-hel142-baseline/tvOS/TLS.xcresult` and `requests.json` |
| Complete iOS suite + TLS | `/private/tmp/lagoon-hel142-validation/iOS/20260907-210712/TLS.xcresult` |
| Complete tvOS suite + TLS | `/private/tmp/lagoon-hel142-validation/tvOS/20260907-210756/TLS.xcresult` |
| Native allocation stress | `/private/tmp/lagoon-hel142-lifetime-stress-2.xcresult` and `.log` |
| Final iOS/tvOS UI recovery runs + screenshots | `/private/tmp/lagoon-hel142-validation/20260907-211559/{iOS,tvOS}/Recovery.xcresult` and `screenshots/` |
| Final Release logs | `/private/tmp/lagoon-hel142-release-ios-complete.log`, `/private/tmp/lagoon-hel142-release-tvos-complete.log` |
| Native source/build logs | `/private/tmp/lagoon-hel142-build/` |
| Capability comparison | `/private/tmp/lagoon-hel142-capabilities-upstream.txt`, `/private/tmp/lagoon-hel142-capabilities-patched.txt` |

## Bounded malformed-media handling

`DiscReadBudget` is shared from UDF mounting through Blu-ray/DVD title selection.
It permits at most 64 KiB in one metadata read, 32 MiB of requested metadata,
2,048 reads and 100,000 checked operations, with a 30-second monotonic deadline.
Cancellation and deadline checks run before/after reads and inside parser loops;
they do not preempt a currently blocked synchronous transport call. The range
loader retains its own timeout and cancellation behavior. Metadata cache reads
fetch only the requested range so streaming read-ahead cannot amplify this
budget. Ordinary media streaming resumes its existing read-ahead behavior.

Descriptors are bounded before allocation or I/O. Physical and metadata extents
must fit their partitions and the known image size; unknown-length sources must
still return the exact requested bytes. Partition maps, descriptor sections,
directory records and allocation continuations reject truncation, invalid
references and cycles. Per-file limits remain: 8,192 extents, 64 continuations,
4 MiB directories and 16,384 directory entries. Title streams cap at 65,536
extents, with checked cumulative offsets and lengths. Blu-ray selection caps
512 attempted playlists (including malformed ones), 1 MiB per playlist and
4,096 play items. DVD parts must have valid numeric names, no duplicates and
no missing part in the chosen title set.

Regression coverage includes the original 30-bit oversized ICB request (rejected
before touching the source), truncated unknown-length images, out-of-image and
out-of-metadata-partition extents, arithmetic overflow, continuation cycles,
aggregate budgets, cancellation, and 128 deterministic descriptor mutations.
Existing valid UDF 2.50 Blu-ray and UDF 1.02 DVD fixtures still pass. This is
bounded mutation coverage, not a claim of exhaustive fuzzing or universal disc
compatibility. Unsupported/malformed disc errors retain the existing bounded
server-delivery fallback. Existing Blu-ray clip trimming and DVD title-selection
limitations are unchanged.

`FFmpegDemuxer` owns the format context immediately after allocation. A single
failure cleanup path covers both pre-open disc/custom-I/O setup and failures
inside `avformat_open_input`, which updates the same owned pointer. Repeated
failed opens no longer require the caller to close between attempts. The
separate allocation test measures live allocator bytes after warm-up rather
than RSS. Cached AVIO also rejects overflowing seeks/cursors and oversized
source responses before copying into the native buffer.

## Account-specific expired-session recovery

Every authenticated API request captures the active session generation, server
and user before suspension. An authenticated 401 from that same session removes
the rejected credential, persists an expired-account marker, clears active
access and presents sign-in for the retained server and username. Identity,
account preferences and other accounts remain. The persisted marker prevents a
Keychain deletion failure from restoring a rejected token on relaunch; it clears
only after the replacement token is saved and read back successfully.

Login rejection remains a credential-entry error. Pre-authentication and Quick
Connect initiation/polling omit an existing token. A 403, other server error,
timeout or offline condition does not invalidate the session, and restore does
not add a network probe. Late responses from an old session are cancelled, so
an old 401 or logout cannot sign out another account or a replacement token.

Tests cover browse, PlaybackInfo and progress-report 401s; preserved preferences
and other credentials; relaunch with a stale token reintroduced into Keychain;
reauthentication and subsequent restore; login rejection; 403/404/500/503;
timeouts/offline failures; account switches; same-account token replacement;
and late logout. Actual iOS and tvOS direct/HLS playback was revoked through a synthetic
server, dismissed to sign-in and restored with a second token. HLS crossed media
segment boundaries; ordinary local HTTP continued to work. These UI tests use
an ephemeral bootstrap identity, while normal persistence and multiple-account
behavior are exercised through `SessionStore` tests.

Reproduce the controlled UI journeys with:

```sh
python3 scripts/test-session-recovery.py --work /private/tmp/lagoon-session-validation
```

The fixture binds only loopback, generates synthetic 90-second H.264/AAC media
with an installed ffmpeg CLI, and never revokes a real Jellyfin account. The
harness creates and deletes its own simulators and exports screenshots. Its
iOS build excludes the existing tvOS-only remote suites through build arguments;
the checked-in UI target's general platform configuration remains unchanged.
The iOS player exposes its state only in a debug, explicitly enabled UI probe.

## Remaining release acceptance

Real iPhone/iPad and Apple TV playback acceptance has **not** been performed
for this change. On September 7 the paired iPhone 16 Pro Max (iOS 26.6.1) became
visible, but CoreDevice could not establish its tunnel; a second connection
attempt timed out. No validation app was installed on it. No Apple TV was
connected. Connect/unlock the iPhone over USB and provide an Apple TV to finish
this acceptance step; HEL-142 remains In Testing, not Done. Device slices compile and link successfully, but the runtime
certificate matrix above uses simulator slices. Before release, verify real
server playback and interruption/seek/reconnect behavior on the target devices,
including correctly installed private roots where supported. A self-signed
server without established trust will now fail instead of silently bypassing
verification.

The certificate suite is transport/demux validation, not visual playback,
codec-output, HDR/audio-route or performance acceptance. Those remain HEL-144.
The broader static-library distribution and encryption-export assessment
remains HEL-143; rebuilding libavformat does not resolve it.
