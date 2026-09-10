# Server address handling: audit A13

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

Implemented September 7, 2026, against app version `0.1 (90)`.

## Behavior

Jellyfin and Seerr share `ServerAddress`, a parser that constructs candidates
with `URLComponents`. Fallback ports now precede reverse-proxy paths. For
example, `media.example/jellyfin` produces
`http://media.example:8096/jellyfin` as the default-port candidate. Seerr uses
5055 and removes a terminal `/api/v1` from user input without decoding escaped
path separators. Configuration, restoration, and client snapshots treat the
result as a service root and do not strip the suffix again. This preserves a
proxy whose own root ends in `/api/v1`.

Explicit HTTP/HTTPS addresses probe only the selected URL. Schemeless addresses
retain the existing discovery order; explicit ports, IPv6 brackets/scopes,
internationalized hostnames, and encoded proxy segments are preserved.
Malformed addresses, embedded credentials, queries, and fragments are rejected
before any discovery request. Surrounding whitespace and trailing literal path
slashes are normalized.

The sign-in screen and Seerr settings show the selected full URL and an HTTP
warning before password and Quick Connect controls. Existing interrupted or
expired sign-ins get the same disclosure. Legacy URL display strips embedded
credentials, queries, and fragments. Saved account identities are unchanged.

## Automated and visual evidence

The focused suites `ServerAddressTests`, `SeerrClientTests`, and
`LocalNetworkAccessTests` pass on iOS 26.5 and tvOS 26.5: 24 test functions in
three suites on each platform, including parameterized address cases.
Coverage includes:

- Correct fallback ports and paths through both actual session stores.
- Explicit HTTPS failure without probing HTTP; malformed input without a
  network request; confirmed local-network denial stopping discovery.
- IPv4, bracketed/scoped IPv6, explicit ports, uppercase schemes and `.local`,
  internationalized names, encoded spaces/slashes/delimiters, and API suffixes.
- Persisting the successful Seerr root, restoring it, and copying the client
  without stripping a proxy segment; keeping discovery free of cookies.
- Rejecting unsupported schemes, URL credentials, queries/fragments, empty or
  invalid ports, invalid IP literals, malformed escapes, and internal whitespace.

Focused result bundles:

```text
/private/tmp/lagoon-a13-focused-ios.xcresult
/private/tmp/lagoon-a13-focused-tvos.xcresult
```

The repeatable UI lane uses fresh, disposable simulators and synthetic accounts:

```sh
python3 scripts/test-session-recovery.py --server-address
```

The fixture rejects API requests without `/services/jellyfin` or
`/services/seerr`. The harness checks the request log for successful Jellyfin
discovery/authentication and both Seerr discovery endpoints, preventing a
skipped or incomplete journey from looking successful.

iOS types an invalid address, corrects it, connects through a proxy, signs in,
and configures Seerr using an address ending in `/api/v1/`. tvOS checks restored
sign-in, password/change-server remote focus, and a restored Seerr pairing after
synthetic Jellyfin authentication. Both check full addresses, HTTP warnings,
and absence of that warning for a restored HTTPS address.

The iPhone and Apple TV journeys passed. Exported screenshots were visually
reviewed for readable URLs, warning placement, and access to sign-in controls,
including the tvOS password and Seerr authentication focus states:

```text
/private/tmp/lagoon-hel142-validation/20260907-234704/iOS/Recovery.xcresult
/private/tmp/lagoon-hel142-validation/20260907-234704/iOS/screenshots/
/private/tmp/lagoon-hel142-validation/20260907-234940/tvOS/Recovery.xcresult
/private/tmp/lagoon-hel142-validation/20260907-234940/tvOS/screenshots/
```

The existing iPhone denial/Settings/retry journey also passes after these UI
changes, including a restored Seerr connection:

```text
/private/tmp/lagoon-hel142-validation/20260907-235008/iOS/Recovery.xcresult
```

The initial tvOS UI build exposed an existing iOS-only helper in
`LocalNetworkUITests` that was outside its platform guard. The helper now
compiles only for iOS. A first complete iOS unit run used
`test-without-building` after switching to the UI scheme, which had removed the
hosted unit bundle; the complete rerun rebuilds the unit-test scheme.
The tvOS UI result also contains a UIKit `_UIReplicantView` hierarchy warning;
the test has zero failures and its captured focus states render correctly.

Final complete suites, including the additional Seerr restoration/snapshot
case, pass: **538 iOS tests in 60 suites** and **562 tvOS tests in 62 suites**,
with zero failures. The existing opt-in native TLS and allocation stress cases
remain disabled in these ordinary runs; their separate evidence is unchanged.
Both unsigned device Release builds pass. No new warnings point to the changed
production files; existing player/concurrency warnings remain a separate audit
item.

```text
/private/tmp/lagoon-a13-final-ios.xcresult
/private/tmp/lagoon-a13-final-tvos.xcresult
/private/tmp/lagoon-a13-final-release-ios.log
/private/tmp/lagoon-a13-final-release-tvos.log
```

The complete suites were run with `xcodebuild test -scheme Lagoon` on the
respective iOS/tvOS simulator destinations. Device builds used `xcodebuild
build -scheme Lagoon -configuration Release` with `generic/platform=iOS` or
`generic/platform=tvOS` and `CODE_SIGNING_ALLOWED=NO`. Python syntax and
`git diff --check` also pass.

## Limits and remaining release work

This change does not establish acceptance on a physical IPv6-only/DNS64/NAT64
network or with a production reverse proxy. Those network/device checks remain
part of HEL-144. The HTTPS screenshot checks disclosure for a restored URL;
TLS verification evidence remains in the separate
[native TLS validation record](hel-142-native-tls-validation.md).

ATS policy, remembered account identities, and native playback are unchanged.
HTTP disclosure is an inline warning; it is not a new consent dialog or an
exception to platform transport policy. The local-network simulator lane
checks the response to a simulated denial diagnosis; real iPhone/iPad permission
acceptance remains pending.

Audit A14 (watched/favourite reconciliation) and the public website/legal/device
release gates remain open. A15 was addressed in the subsequent September 8
[download hardening follow-up](download-hardening-validation.md).
