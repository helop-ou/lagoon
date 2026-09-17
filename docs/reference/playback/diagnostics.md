# Diagnostic reporting

Automatic, privacy-bounded reports catch playback and request failures, so the
developer finds intermittent problems instead of relying on tester reports.
This page covers the schema, detectors, limits, and Sentry setup. The
[playback guide](../../playback.md#diagnostic-reporting) has the rules that
matter while changing the player.

## Decision

Hosted Sentry receives the reports: organisation `helop-ou`, project `lagoon`,
EU ingest region, free Developer plan. The app skips the `sentry-cocoa` SDK,
building every byte itself and posting it to the [envelope
endpoint](https://develop.sentry.dev/sdk/data-model/envelopes/). Owning the
payload is the privacy guarantee, keeps the repo to one native dependency, and
will let the engine, once extracted, emit diagnostics without a hosted
service. GlitchTip speaks the same protocol, so swapping the backend only
takes a new DSN. Apple's crash reporting stays the crash path: no stacks or
dSYMs go out for nonfatal incidents.

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
Lagoon/Features/Playback/Diagnostics/PlaybackIncidentMonitor.swift
  PlaybackFreezeDetector, PlaybackDegradationPolicy, the per-attempt monitor
Lagoon/Shared/Networking/APIDiagnostics.swift  request/decode failure classification
```

`DiagnosticsHub.record` is a lock and an array append that any thread may
call. `setAmbientFields` publishes the playback attempt's identity and facts,
so every incident reported before the attempt ends inherits them: a stall the
engine reports carries the same codec and delivery tags as a failure the
controller reports. `report` validates fields, consults the suppressor,
snapshots the history, and hands the incident to the sink, which serialises it
and writes on its own utility queue. Nothing else runs on a playback path.

The engine records its own events — seek, track switch, stall begin/end,
renderer recovery, cache fallback, finish — and reports renderer recoveries,
stalls, and subtitle load failures. `PlaybackController` owns a
`PlaybackIncidentMonitor` per attempt and reports start failures, fallbacks,
terminal failures, handoff failures, frozen playback, and degraded sessions.
Both API clients call `APIDiagnostics` from their shared request path.

## What leaves the device

Only fields listed in `DiagnosticSchema.fields` can appear in an event or
incident. Every key has a kind: `int`, `double`, `bool`, a closed `choice`, a
`token`, or a `route` template of letters and `{id}`. A token matches
`[A-Za-z0-9._,-]`, holds at most 48 bytes, and is refused when it looks like a
hostname or IPv4 address. A value that does not fit is dropped and counted in
`schemaRejected`, so a mistake at a call site is visible, not silently
shipped.

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
and headers, search terms, subtitle text, `localizedDescription` or `userInfo`
of any error, screenshots, or a `user` object. Reports count occurrences, not
affected testers. Sentry can still see the submitting IP at the edge, so the
project setting *Prevent Storing of IP Addresses* must stay on.

`DiagnosticPrivacyTests` drives the real assembly with synthetic sensitive
values — hostname, token, user id, item id, title, cookie name, prose — and
asserts none appear in the envelope bytes.

## Codes

`DiagnosticEventCode` names the history events: `playback.start`, `.ready`,
`.play`, `.pause`, `.seek`, `.track`, `.subtitleLoadFailed`, `.stallBegin`,
`.stallEnd`, `.rendererRecovery`, `.cacheFallback`, `.sample`, `.fallback`,
`.handoffBegin`, `.handoffEnd`, `.finished`, `.stop`, `.failure`;
`audio.interruption`, `audio.route`; `api.failure`, `api.sessionExpired`;
`app.memoryWarning`, `app.thermal`, `app.foreground`, `app.background`.

`DiagnosticIncidentCode` names the reports and their fingerprints:

| Code | Level | Fingerprint variant | Fires when |
| --- | --- | --- | --- |
| `playback.startFailed` | error | stage, error domain, code | negotiation or engine start threw; not when the viewer left (`CancellationError`, or URLSession's `-999` while the start task or controller was cancelled) |
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

Sentry groups on the fingerprint verbatim: `[code] + variant`. The build is a
tag and part of the release identity, not the fingerprint. Numbers that vary
per occurrence, such as positions or durations, never enter a fingerprint.

## Detectors and thresholds

- **Freeze** (`PlaybackFreezeDetector`): every 2 s the monitor samples the
  engine. Progress is expected when not paused, not buffering, rate > 0, the
  app active, no seek in the last 3 s, and more than 2 s remain. If the
  position moves ≤ 0.05 s for 8 s under those conditions, one
  `playback.frozen` (`playhead`) is reported; if the position advances but the
  renderer's frame count does not for 8 s, one `playback.frozen` (`picture`)
  is reported. Matching progress resets it.
- **Stall**: the engine's own recovery records begin/end. A reprime — the
  clock held at 0 for `StallRecoveryPolicy.reprimeAfter`, 5 s — or a resume
  after ≥ 8 s reports `playback.stall`; three stalls within 60 s report once
  per attempt as `frequent`.
- **Degraded** (`PlaybackDegradationPolicy`, evaluated at stop for sessions
  that did not fail): requires ≥ 30 s played. Reasons are `droppedFrames` (≥
  60 dropped and ≥ 0.5 % of frames), `stalls` (≥ 3), `reprimes` (≥ 1),
  `audioStarvation` (≥ 5). Frozen and renderer-recovery counts ride along as
  fields. An attempt that started with reporting off, or opted out midway, has
  no degraded-session summary: its cumulative counters cannot be judged
  against only the observed playing time. Healthy sessions send nothing.
- **Samples**: every third tick (6 s) writes `playback.sample` with queue
  depths, audio lead, counters, memory, thermal and app state, so an
  incident's attachment shows roughly the last minute of the pipeline.
- **API**: expected conditions are recorded but not reported: cancellation,
  offline, lost connection, timeout, unreachable host and DNS failures; HTTP
  401, 403, 304. Everything else is an incident. A request whose failure is an
  answer rather than a fault — an optional plugin route such as
  `HomeScreen/Sections`, a newer-server endpoint such as `MediaSegments` —
  passes `probe: true` to `JellyfinClient.get` and is never reported.

## Limits

- History: 240 events, trimmed to the 90 s before the incident.
- Suppression (`IncidentSuppressor.Limits.standard`): 3 reports per
  fingerprint per hour, 30 per hour in total, 120 per process. Suppressed
  repeats fold into `occurrences` on the next report of that fingerprint.
- Transport (`SentryTransportPolicy.standard`): at most 20 envelopes pending
  on disk (oldest dropped), 256 KiB per envelope, one upload in flight,
  backoff 30 s doubling to 1 h on transport or 5xx failures,
  `X-Sentry-Rate-Limits` honoured on every status including 200, `429` falling
  back to `Retry-After`, 4xx envelopes discarded. Pending envelopes live in
  Caches/`Diagnostics/pending` and retry on the next submit, on foreground, or
  when the backoff timer fires. Turning reporting off discards the pending
  queue and stops uploads; nothing recorded before the switch leaves the
  device after it.

## Tester controls and disclosure

Settings → Advanced → Diagnostic Reports → *Send Diagnostic Reports* controls
`diagnostics.reportingEnabled`. Off means off: history stops recording, the
playback sampler stops, and the pending queue is discarded. Changing the
switch mid-playback cancels the sampler's timer; turning it back on resumes
sampling the same attempt with fresh freeze and frequent-stall windows. An
in-flight renderer metrics request may finish; none start while opted out.
HUD, decode-trace, and benchmark sampling have their own controls. While
reports are on, the renderer metrics load runs every two seconds,
asynchronously, adding no SwiftUI body reads. It made no measurable difference
in frame delivery on the Apple TV; see the reporting on/off comparison under
[physical device verification](#physical-device-verification-2026-09-11).
Release builds default on; Debug builds default off so development never
spends quota, with `-diagnostics.reportingEnabled YES` turning a debug run on.
The footer under the toggle states what a report contains.
`PrivacyInfo.xcprivacy` declares *Other Diagnostic Data* and *Performance
Data*, not linked, not used for tracking — App Store Connect's privacy answers
must match. Retention is the Developer plan's 30-day lookback, checked on
sentry.io/pricing on 2026-09-11; the Settings footer states the same number
and must track it.

## Sentry setup

- Organisation `helop-ou`, project `lagoon`, EU region, fixed at creation. The
  DSN is a client key that can submit to that project and nothing else. It is
  injected at build time, not tracked in source: the `LAGOON_SENTRY_DSN` build
  setting lands in the app's Info.plist, and `DiagnosticsConfiguration` reads
  it back, with `-diagnostics.sentryDSN` still overriding it for a capture
  run. A build with no DSN — every ordinary checkout — configures no sink and
  reports nothing, keeping a contributor's Release build off quota.
  `scripts/upload-testflight.sh` requires the variable.
- Project → Settings → Security & Privacy: *Prevent Storing of IP Addresses*
  is on. No data-scrubbing rules are relied on; the app never sends the fields
  they would scrub, and it sends no `user` or `request` object. Until
  2026-09-12 the event declared `platform: cocoa`; for that platform Sentry's
  ingest fills `user.ip_address` from the connection and derives a location
  from it unless this setting is on. On 2026-09-11 the dashboard showed an IP
  and geography for a device report, so the setting was off at that point. The
  event now declares `platform: native`, which Sentry does not infer an
  address for, so the project setting is a second line, not the only one.
  `SentryEnvelopeTests` pins the platform.
- Quota: Developer plan, 5,000 errors per month, one dashboard seat. Check
  Settings → Subscription monthly; the client-side limits above bound a worst
  case at a few dozen reports per process.
- Finding reports: Issues, filtered by `release`, `build`, `videoCodec`,
  `delivery`, `stage`, `route`. Each event carries `extra` with every field
  and a `history.json` attachment with the timeline (`t` in seconds relative
  to the incident, negative before it).
- No `sentry-cli`, no dSYM upload, no source maps. A stack trace for some
  failure class would need its own decision.

## Verifying

Unit tests: `DiagnosticSchemaTests`, `DiagnosticHistoryTests`,
`IncidentSuppressorTests`, `DiagnosticsHubTests`,
`DiagnosticRouteTemplateTests`, `SentryEnvelopeTests`,
`SentryTransportPolicyTests`, `PlaybackFreezeDetectorTests`,
`PlaybackDegradationPolicyTests`, `PlaybackIncidentMonitorTests`,
`PlaybackFailureDetailTests`, `DiagnosticPrivacyTests`.

Payload inspection without touching Sentry:

```sh
scripts/diagnostics-capture-server.py --port 8765 --out /tmp/lagoon-diagnostics
xcrun simctl launch <udid> ee.helop.lagoon \
  -diagnostics.reportingEnabled YES \
  -diagnostics.sentryDSN http://key@127.0.0.1:8765/1 \
  -debug.regressionFailFirstDelivery delivery
```

On a paired Apple TV the same capture works over the LAN: start the server
with `--bind 0.0.0.0`, point the DSN override at the Mac's address (the app's
`NSAllowsLocalNetworking` permits plain HTTP there), and launch a Debug build
with `xcrun devicectl device process launch --console --terminate-existing
ee.helop.lagoon -- <arguments>`. `-debug.playerRegression YES
-debug.regressionBootstrapPublicDemo YES -debug.regressionFindPlayable YES`
signs into the demo in memory and picks a title. The injection hooks are
Debug-only, so a Release build can only send what really happens:
`-debug.regressionFailFirstDelivery delivery|undecodable`, and
`-debug.simulateDeliveryStall YES` with
`-debug.starvationInjectionDelaySeconds` and
`-debug.starvationInjectionDurationSeconds`. The transport's outcome logs are
`os_log` and do not reach the devicectl console. `devicectl device copy from
--domain-type appDataContainer --domain-identifier ee.helop.lagoon --source
Library/Caches/Diagnostics` shows whether the pending queue drained.

### Physical device verification (2026-09-11)

Living Room Apple TV 4K (3rd generation), tvOS 26.6, Debug build of main at
`056ff87` (build 96), reporting on, DSN pointed at the capture server on the
Mac. Each scenario ran hands-off against the public demo, with the app running
throughout. Envelopes were read from the capture server's files and scanned
for the demo host, the Mac's address and port, the synthetic server name, both
item ids, both titles, the account name, `Authorization`, `MediaBrowser`,
`localizedDescription`, and the private server's name: no hits in any
envelope.

| Scenario | Injection | Result |
| --- | --- | --- |
| Healthy session | 70 s window, bench auto-exit | no envelope |
| Recovered fallback | `regressionFailFirstDelivery delivery` | `playback.fallback` (`delivery`), `outcome=recovered`, `elapsedMs=4304`, `to` remux |
| Undecodable fallback | `regressionFailFirstDelivery undecodable` | `playback.fallback` (`undecodable`), `outcome=recovered`, reloaded on the transcode rung in 6.8 s |
| 12 s delivery suspension | `simulateDeliveryStall`, 4 s audio lead | ~6 s stall, no reprime: no envelope (below the 8 s and reprime thresholds, as designed) |
| 30 s delivery suspension | same, 30 s | `playback.stall` (`reprime`, `video`), `elapsedMs=5214`; then at auto-exit `playback.degraded` (`reprimes`), `outcome=stopped`, `reprimes=1 stalls=1` |
| API failure | synthetic server: probe 200, `POST /Users/AuthenticateByName` and `GET /QuickConnect/Enabled` 500 | `api.requestFailed` (`jellyfin`, `QuickConnect.Enabled`, `status500`), route `QuickConnect/Enabled`, `elapsedMs=21` |

Every event carried `release ee.helop.lagoon@0.1+96`, `dist 96`, `environment
debug`, device `AppleTV14,1` / Apple TV, `simulator false`, `tvOS 26.6`,
`engine lavf62.12.102`, the codec/container/ delivery tags, a `history.json`
attachment (0.4–7.8 KB), and no `user` object. The authentication 500 was
classified as a lost connection, because the synthetic server closed the
socket without reading the request body; the quick-connect probe that followed
was the one reported. An exhausted recovery ladder could not be forced against
the demo, which serves every rung.

A final recovered-fallback run with the production DSN drained the device's
`Caches/Diagnostics/pending` queue within 40 s of the incident. Sentry's edge
answers 200 to any key, so acceptance is confirmed only by the event appearing
under Issues — it did: fingerprint `playback.fallback delivery unknown`, about
13:15 EEST on 2026-09-11, with Sentry-inferred IP and location attached (see
Sentry setup above). Not yet verified: a physical iPhone, and a Release build
sending a naturally occurring incident.

Reporting on versus off, for criterion 6, ran on a Release build of the same
commit: "The Creator" at 600 s, 4K Dolby Vision profile 8 over VideoToolbox,
HUD and decode trace off, subtitles off, interleaved, cool-downs of five
minutes then one; the third pair was dropped at the developer's request:

| run | reporting | dropped/frames | stalls | footprint start → peak (MB) |
| --- | --- | --- | --- | --- |
| 1 | on | 0 / 1462 | 0 | 724.5 → 726.2 |
| 1 | off | 0 / 1462 | 0 | 723.9 → 724.4 |
| 2 | on | 0 / 1439 | 0 | 723.9 → 725.3 |
| 2 | off | 0 / 1463 | 0 | 724.5 → 725.5 |

No frame was dropped in either arm, and the footprint differs by under 2 MB.
The bench itself reads renderer metrics, so this measures the incremental cost
of the sampler over an already instrumented run; CPU and energy with the bench
disabled were not observed.

Playing any direct-play title exercises the flow: four seconds in, the
regression hook injects a delivery failure, the ladder falls to the remux
rung, and a `playback.fallback` envelope lands in the output directory as
`*.event.json` and `*.history.json`. Closing the player after thirty seconds
exercises the stop path; `--status 429` and `--status 500` exercise rate
limiting and backoff. Read the JSON for anything that should not be there.

Physical-device acceptance for criteria 1, 2, and 6 is still owed; that
evidence belongs wherever the work is tracked, with the revision, device,
and fixture.
