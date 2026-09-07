# Lagoon's libavformat build (HEL-142)

`Libavformat.xcframework` is FFmpeg **n8.1.2 / libavformat 62.12.102**, built
by `scripts/build-ffmpeg-format.py` with
`../Patches/0001-apple-tls-verification.patch`. Only libavformat is replaced;
the codec, utility, resampler and GnuTLS dependency pins remain unchanged.

The upstream binary defaults `tls_verify` to zero. Enabling it alone is
insufficient: GnuTLS 3.8.11 does not load system roots on iOS/tvOS. Furthermore,
FFmpeg HLS does not copy `tls_verify` from the master request to every child.

The patch enables verification by default and validates GnuTLS's actual peer
chain with the public Apple Security APIs `SecPolicyCreateSSL`,
`SecTrustCreateWithCertificates` and `SecTrustEvaluateWithError`. The server
policy checks the destination hostname and certificate validity against system
and explicitly installed trust roots. Server-supplied certificates are never
installed as trust anchors. Allocation, decoding and evaluation failures fail
closed, before any HTTP request or token is sent to that peer. GnuTLS continues
to perform the handshake and encrypted transport, including TLS 1.3.

Trust evaluation disables additional network fetches. Servers must supply
their intermediate certificates; this avoids an independent certificate fetch
outside FFmpeg's network timeout and interrupt handling. There is no bundled
CA list, certificate pinning, trust-all fallback or private Apple API. An
explicit FFmpeg `ca_file` retains upstream GnuTLS custom-CA behavior; Lagoon
does not supply this option. Plain HTTP remains available for existing server
configurations and is outside certificate verification.

`FFmpegNetworkPolicy` also enforces verification at application native opens,
preserving parent cancellation and protocol restrictions. Mutable cached-HLS
manifests and cache fallbacks use the same policy. The binary default protects
lower-level protocol opens and reconnects. Native HLS connection reuse stays
enabled; the experimental cached-segment path keeps its existing setting.
The application suppresses FFmpeg's raw stderr logger, which otherwise prints
token-bearing URLs on HLS failures. Lagoon's error codes and playback
diagnostics remain available; the fixture harness checks for token exposure.

## Rebuild and verify

Requires Xcode, Python 3.12+ and pkg-config. All compiler roles explicitly use
Apple Clang, including FFmpeg's host tools. No GCC installation is needed.

```sh
python3 scripts/build-ffmpeg-format.py --work /private/tmp/lagoon-libavformat-build
python3 scripts/build-ffmpeg-format.py --verify-only Packages/LagoonFFmpeg/Artifacts/Libavformat.xcframework
```

The script downloads checksum-pinned sources and dependency archives. It
retains upstream's selected demuxers/muxers, builds only libavformat, and
packages iOS/tvOS arm64 devices, arm64/x86_64 simulators, and arm64/x86_64 macOS.
Actual deployment targets are iOS/tvOS 26 and macOS 14. Static framework
metadata follows the repository's existing dav1d packaging convention.
`--groups` and `--output` allow temporary development builds; commit all five
platform groups. Configurations, Xcode version, source/patch hashes and file
checksums are recorded in `BUILD.json`. Absolute toolchain paths are recorded
for provenance; byte-identical output across Xcode versions is not promised.

Source: https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.1.2

Source SHA-256: `9fd092511605bbebafe095ea6d38d9e40f34d12f7386e1258372df8be0576eb7`.

FFmpeg's license notices accompany the artifact. This build reports LGPL
version 3 or later, as did the replaced artifact. The broader distribution,
relinking-material and encryption-export assessment remains **HEL-143**.

## Runtime regression checks

```sh
python3 scripts/test-ffmpeg-tls.py --all-unit-tests --work /private/tmp/lagoon-tls-validation
```

Requires Xcode, command-line ffmpeg/openssl, and Python's `cryptography` package
for disposable test certificates. The harness creates its own iOS/tvOS
simulators and trusts its temporary root only on those devices. It never edits
the Mac's trust store or an existing simulator's keychain. It deletes its test
simulators on exit and retains logs, request records and `.xcresult` bundles.

The actual app-linked libraries exercise valid, self-signed, expired and
wrong-host certificates; direct opens with/without application enforcement;
HTTP; redirects; HLS variants, segments and AES keys; and reconnects which
switch certificates after a partial response. Server logs must show no HTTP
requests to rejected peers, including the synthetic query token. The ordinary
unit suite checks the linked binary's verification default and cancellation
without requiring the local fixture servers. Physical-device playback and
output-route acceptance remain separate release checks.
