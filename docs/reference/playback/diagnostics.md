# Diagnostic reporting (HEL-159)

Automatic, privacy-bounded reports of playback and request failures, so
intermittent problems are discovered by the developer rather than only through
tester descriptions. This is the reference for the schema, the detectors, the
limits, and the Sentry setup. The [playback guide](../../playback.md#diagnostic-reporting)
carries the rules that matter while changing the player.

## Decision

Hosted Sentry (organisation `helop-ou`, project `lagoon`, EU ingest region,
free Developer plan) receives the reports. The `sentry-cocoa` SDK is not
used: the app builds every byte itself and posts it to the documented
[envelope endpoint](https://develop.sentry.dev/sdk/data-model/envelopes/).
Owning the payload is the privacy guarantee, keeps the repo's single native
dependency, and lets the extracted engine (HEL-156) emit diagnostics without a
hosted service. GlitchTip speaks the same protocol, so the backend is a DSN
away from being swapped. Apple's crash reporting stays the crash path; no
stacks or dSYMs are sent for nonfatal incidents.

## Architecture

```text
Lagoon/Shared/Diagnostics/            vendor-neutral core
  DiagnosticSchema      allowlisted field keys and kinds; validation
  DiagnosticEvent       history entry: code, uptime, validated fields
  DiagnosticHistory     bounded ring buffer (240 events, 90 s window)
  DiagnosticIncident    a report: code, fingerprint, fields, history snapshot
  IncidentSuppressor    client-side limits per fingerprint, per hour, per process
  DiagnosticsHub        record/report; lock-protected; DiagnosticSink protocol
  DiagnosticContext     build, OS, device model, environment
  DiagnosticRouteTemplate / DiagnosticNetworkClassifier
Lagoon/Shared/Diagnostics/Sentry/     app-owned adapter
  SentryDSN, SentryEnvelope, SentryTransportPolicy, SentryTransport
  DiagnosticsConfiguration            DSN and launch wiring
Lagoon/Views/Player/PlaybackIncidentMonitor.swift
  PlaybackFreezeDetector, PlaybackDegradationPolicy, the per-attempt monitor
Lagoon/Networking/APIDiagnostics.swift  request/decode failure classification
```

`DiagnosticsHub.record` is a lock and an array append and may be called from
any thread. `setAmbientFields` publishes the playback attempt's identity and
facts so every incident reported until the attempt ends inherits them, which
is how a stall the engine reports carries the same codec and delivery tags
as a failure the controller reports. `report` validates fields, consults the suppressor, snapshots the
history, and hands the incident to the sink, which serialises and writes on
its own utility queue. Nothing runs on a playback path beyond those calls.

The engine records its own events (seek, track switch, stall begin/end,
renderer recovery, cache fallback, finish) and reports renderer recoveries,
stalls, and subtitle load failures. `PlaybackController` owns a
`PlaybackIncidentMonitor` per attempt and reports start failures, fallbacks,
terminal failures, handoff failures, frozen playback, and degraded sessions.
Both API clients call `APIDiagnostics` from their shared request path.

## What leaves the device

Only fields in `DiagnosticSchema.fields` can appear in an event or incident.
Every key has a kind: `int`, `double`, `bool`, a closed `choice`, a `token`
(`[A-Za-z0-9._,-]`, at most 48 bytes, refused when it looks like a hostname or
IPv4 address), or a `route` template of letters and `{id}`. A value that
does not fit is dropped and counted in `schemaRejected`, so a mistake at a
call site is visible in the report rather than silently shipped.

Sent: app build and version, engine (`lavf` version), OS name and version,
device model class, simulator flag, distribution environment, delivery rung,
play method, container, codec names, profile, range, dimensions, bit depth,
frame rate, bitrate, output paths, position and rate, queue depths, audio
lead, stall and starvation counters, dropped and corrupted frame counts,
memory footprint and headroom, thermal state, app state, error domain and
code, HTTP status and method, route template, stage, cause, recovery reason,
outcome, and relative timings.

Never sent: account or user identifiers, install identifiers, media titles or
item identifiers, server addresses, credentials, request or response bodies
and headers, search terms, subtitle text, `localizedDescription` or
`userInfo` of any error, screenshots, or a `user` object. Reports therefore
count occurrences, not affected testers. Sentry can still see the submitting
IP address at the edge; the project setting *Prevent Storing of IP Addresses*
must stay on.

`DiagnosticPrivacyTests` drives the real assembly with synthetic sensitive
values (hostname, token, user id, item id, title, cookie name, prose) and
asserts none of them appear in the envelope bytes.

## Codes

Events (`DiagnosticEventCode`, the history): `playback.start`, `.ready`,
`.play`, `.pause`, `.seek`, `.track`, `.subtitleLoadFailed`, `.stallBegin`,
`.stallEnd`, `.rendererRecovery`, `.cacheFallback`, `.sample`, `.fallback`,
`.handoffBegin`, `.handoffEnd`, `.finished`, `.stop`, `.failure`;
`audio.interruption`, `audio.route`; `api.failure`, `api.sessionExpired`;
`app.memoryWarning`, `app.thermal`, `app.foreground`, `app.background`.

Incidents (`DiagnosticIncidentCode`, the reports) and their fingerprints:

| Code | Level | Fingerprint variant | Fires when |
| --- | --- | --- | --- |
| `playback.startFailed` | error | stage, error domain, code | negotiation or engine start threw |
| `playback.fallback` | warning / error | cause, stage, domain, code, `afterTrackSwitch` | reported once the next rung has a verdict: `recovered` (warning, with the reload time in `elapsedMs`), `failed`, or `cancelled` by the viewer |
| `playback.failed` | error | same as fallback | the ladder is spent |
| `playback.rendererRecovery` | warning | reason, domain, code | audio renderer replaced, video renderer flushed, restart-point retry |
| `playback.stall` | warning | `reprime`/`sustained`/`frequent`, cause | a stall reprimed, lasted ≥ 8 s, or three stalls inside 60 s |
| `playback.frozen` | error | `playhead` / `picture` | playhead unchanged ≥ 8 s, or frames not presented ≥ 8 s while the clock runs |
| `playback.degraded` | warning | sorted reasons | session ended over thresholds |
| `playback.subtitleLoadFailed` | warning | stage, domain, code | an external subtitle did not load |
| `playback.handoffFailed` | error | none | next-episode handoff outcome `failed` |
| `api.requestFailed` | warning (5xx) / error | client, route token, status or domain+code | non-2xx, or a transport error that is not expected |
| `api.decodeFailed` | error | client, route token, kind, key | a 2xx body the app could not decode |

Sentry groups on the fingerprint verbatim (`[code] + variant`); the build is
a tag and the release identity, not part of the fingerprint. Numbers that vary
per occurrence (positions, durations) never enter a fingerprint.

## Detectors and thresholds

- **Freeze** (`PlaybackFreezeDetector`): every 2 s the monitor samples the
  engine. Progress is expected when not paused, not buffering, rate > 0, the
  app is active, no seek in the last 3 s, and more than 2 s remain. If the
  position moves by ≤ 0.05 s for 8 s under those conditions, one
  `playback.frozen` (`playhead`) is reported; if the position advances but
  the renderer's frame count does not for 8 s, one `playback.frozen`
  (`picture`) is reported. Progress of the respective kind resets it.
- **Stall**: the engine's own recovery records begin/end. A reprime (the
  clock held at 0 for `StallRecoveryPolicy.reprimeAfter`, 5 s) or a resume
  after ≥ 8 s reports `playback.stall`; three stalls within 60 s report once
  per attempt as `frequent`.
- **Degraded** (`PlaybackDegradationPolicy`, evaluated at stop for
  sessions that did not fail): requires ≥ 30 s played; reasons are
  `droppedFrames` (≥ 60 dropped and ≥ 0.5 % of frames), `stalls` (≥ 3),
  `reprimes` (≥ 1), `audioStarvation` (≥ 5). Frozen and renderer-recovery
  counts ride along as fields. Healthy sessions send nothing.
- **Samples**: every third tick (6 s) writes `playback.sample` with queue
  depths, audio lead, counters, memory, thermal and app state, so an
  incident's attachment shows roughly the last minute of the pipeline.
- **API**: expected conditions are recorded but not reported: cancellation,
  offline, lost connection, timeout, unreachable host and DNS failures;
  HTTP 401, 403, 304. Everything else is an incident. A request whose
  failure is an answer rather than a fault (an optional plugin route such as
  `HomeScreen/Sections`, a newer-server endpoint such as `MediaSegments`)
  passes `probe: true` to `JellyfinClient.get` and is never reported.

## Limits

- History: 240 events, trimmed to the 90 s before the incident.
- Suppression (`IncidentSuppressor.Limits.standard`): 3 reports per
  fingerprint per hour, 30 per hour in total, 120 per process. Suppressed
  repeats fold into `occurrences` on the next report of that fingerprint.
- Transport (`SentryTransportPolicy.standard`): at most 20 envelopes pending
  on disk (oldest dropped), 256 KiB per envelope, one upload in flight,
  backoff 30 s doubling to 1 h on transport or 5xx failures,
  `X-Sentry-Rate-Limits` honoured on every status including 200, `429`
  falling back to `Retry-After`, 4xx envelopes discarded. Pending envelopes
  live in Caches/`Diagnostics/pending` and are retried on the next submit,
  on foreground, or when the backoff timer fires. Turning reporting off
  discards the pending queue and stops uploads; nothing recorded before
  the switch leaves the device after it.

## Tester controls and disclosure

Settings → Advanced → Diagnostic Reports → *Send Diagnostic Reports*
(`diagnostics.reportingEnabled`). Release builds default on; Debug builds
default off so development never spends quota, and a run turns it on with
`-diagnostics.reportingEnabled YES`. The footer under the toggle states what
a report contains. `PrivacyInfo.xcprivacy` declares *Other Diagnostic Data*
and *Performance Data*, not linked, not used for tracking; App Store Connect's
privacy answers must say the same. Retention is the Developer plan's
30-day lookback (checked on sentry.io/pricing, 2026-09-11); the Settings
footer states the same number and must change with it.

## Sentry setup

- Organisation `helop-ou`, project `lagoon`, EU region (fixed at creation).
  The DSN in `DiagnosticsConfiguration` is a client key; it can submit to
  that project and nothing else.
- Project → Settings → Security & Privacy: *Prevent Storing of IP Addresses*
  on. No data scrubbing rules are relied on; the app never sends the fields
  they would scrub.
- Quota: Developer plan, 5,000 errors per month, one dashboard seat. Check
  Settings → Subscription monthly; the client-side limits above bound a
  worst case at a few dozen reports per process.
- Finding reports: Issues, filtered by `release`, `build`, `videoCodec`,
  `delivery`, `stage`, `route`. Each event carries `extra` with every field
  and a `history.json` attachment with the timeline (`t` in seconds relative
  to the incident, negative before it).
- No `sentry-cli`, no dSYM upload, no source maps. If a stack becomes
  necessary for a class of failure, that is a new decision on HEL-159.

## Verifying

Unit tests: `DiagnosticSchemaTests`, `DiagnosticHistoryTests`,
`IncidentSuppressorTests`, `DiagnosticsHubTests`,
`DiagnosticRouteTemplateTests`, `SentryEnvelopeTests`,
`SentryTransportPolicyTests`, `PlaybackFreezeDetectorTests`,
`PlaybackDegradationPolicyTests`, `PlaybackFailureDetailTests`,
`DiagnosticPrivacyTests`.

Payload inspection without touching Sentry:

```sh
scripts/diagnostics-capture-server.py --port 8765 --out /tmp/lagoon-diagnostics
xcrun simctl launch <udid> ee.helop.lagoon \
  -diagnostics.reportingEnabled YES \
  -diagnostics.sentryDSN http://key@127.0.0.1:8765/1 \
  -debug.regressionFailFirstDelivery delivery
```

Play any direct-play title: four seconds in, the regression hook injects a
delivery failure, the ladder falls to the remux rung, and a
`playback.fallback` envelope lands in the output directory as
`*.event.json` and `*.history.json`. Closing the player after thirty seconds
of playback exercises the stop path; `--status 429` and `--status 500`
exercise rate limiting and backoff. Read the JSON for anything that should
not be there.

Physical-device acceptance (criteria 1, 2, 6 of HEL-159) is still owed and
belongs in the archive with the revision, device, and fixture.
