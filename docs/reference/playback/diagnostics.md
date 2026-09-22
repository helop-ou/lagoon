# Diagnostic reporting

Automatic, privacy-bounded reports of playback and request failures, so
intermittent problems surface without tester reports. The rules for changing
the player are in the [playback
guide](../../playback.md#diagnostic-reporting); this page covers the schema,
detectors, limits and Sentry setup.

## Decision

- Reports go to hosted Sentry: organisation `helop-ou`, project `lagoon`, EU
  ingest, free Developer plan.
- No `sentry-cocoa` SDK. The app builds every byte and posts it to the
  [envelope endpoint](https://develop.sentry.dev/sdk/data-model/envelopes/).
  Owning the payload is the privacy guarantee and keeps the dependency count
  at one. GlitchTip speaks the same protocol, so switching is a new DSN.
- Apple's crash reporting stays the crash path. No stacks or dSYMs go out for
  nonfatal incidents.

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

- `DiagnosticsHub.record` is a lock and an array append, callable from any
  thread.
- `setAmbientFields` publishes the playback attempt's identity and facts, so
  every incident before the attempt ends carries the same codec and delivery
  tags, whether the engine or the controller reports it.
- `report` validates fields, checks the suppressor, snapshots history and
  hands the incident to the sink, which serialises and writes on its own
  utility queue. Nothing else runs on a playback path.
- The engine records seek, track switch, stall begin/end, renderer recovery,
  cache fallback and finish, and reports renderer recoveries, stalls and
  subtitle load failures.
- `PlaybackController` owns a `PlaybackIncidentMonitor` per attempt and
  reports start failures, fallbacks, terminal failures, handoff failures,
  frozen playback and degraded sessions.
- Both API clients call `APIDiagnostics` from their shared request path.

## What leaves the device

Only fields in `DiagnosticSchema.fields` can appear. Each key has a kind:
`int`, `double`, `bool`, a closed `choice`, a `token`, or a `route` template
of letters and `{id}`. A token matches `[A-Za-z0-9._,-]`, is at most 48 bytes,
and is refused if it looks like a hostname or IPv4 address. A value that does
not fit is dropped and counted in `schemaRejected`, so a call-site mistake is
visible rather than shipped.

**Sent:** app build and version, engine (`lavf` version), OS name and version,
device model class, simulator flag, distribution environment, delivery rung,
play method, container, codec names, profile, range, dimensions, bit depth,
frame rate, bitrate, output paths, position and rate, queue depths, audio
lead, stall and starvation counters, dropped and corrupted frame counts,
memory footprint and headroom, thermal state, app state, error domain and
code, HTTP status and method, route template, stage, cause, recovery reason,
outcome, and relative timings.

**Never sent:** account or user identifiers, install identifiers, media titles
or item identifiers, server addresses, credentials, request or response bodies
and headers, search terms, subtitle text, `localizedDescription` or `userInfo`
of any error, screenshots, or a `user` object. Reports count occurrences, not
affected testers. Sentry still sees the submitting IP at the edge, so the
project setting *Prevent Storing of IP Addresses* must stay on.

`DiagnosticPrivacyTests` runs the real assembly with synthetic sensitive
values (hostname, token, user id, item id, title, cookie name, prose) and
asserts none reach the envelope bytes.

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
tag and part of the release, not the fingerprint. Values that vary per
occurrence (positions, durations) never enter a fingerprint.

## Detectors and thresholds

- **Freeze** (`PlaybackFreezeDetector`), sampled every 2 s. Progress is
  expected when not paused, not buffering, rate > 0, app active, no seek in
  the last 3 s, and more than 2 s remaining. Under those conditions:
  - position moves ≤ 0.05 s for 8 s → one `playback.frozen` (`playhead`)
  - position advances but the renderer's frame count does not for 8 s → one
    `playback.frozen` (`picture`)
  Matching progress resets it.
- **Stall**: the engine records begin/end. A reprime (clock held at 0 for
  `StallRecoveryPolicy.reprimeAfter`, 5 s) or a resume after ≥ 8 s reports
  `playback.stall`. Three stalls within 60 s report once per attempt as
  `frequent`.
- **Degraded** (`PlaybackDegradationPolicy`, at stop, for sessions that did
  not fail, with ≥ 30 s played). Reasons: `droppedFrames` (≥ 60 dropped and
  ≥ 0.5% of frames), `stalls` (≥ 3), `reprimes` (≥ 1), `audioStarvation`
  (≥ 5). Frozen and renderer-recovery counts ride along as fields. An attempt
  that started with reporting off, or opted out midway, gets no summary,
  since its counters cannot be judged against partial playing time. Healthy
  sessions send nothing.
- **Samples**: every third tick (6 s) writes `playback.sample` with queue
  depths, audio lead, counters, memory, thermal and app state, so an
  incident's attachment covers about the last minute.
- **API**: expected conditions are recorded, not reported: cancellation,
  offline, lost connection, timeout, unreachable host, DNS failure; HTTP 401,
  403, 304. Everything else is an incident. A request whose failure is an
  answer (an optional plugin route like `HomeScreen/Sections`, a newer-server
  endpoint like `MediaSegments`) passes `probe: true` to `JellyfinClient.get`
  and is never reported.

## Limits

- History: 240 events, trimmed to the 90 s before the incident.
- Suppression (`IncidentSuppressor.Limits.standard`): 3 reports per
  fingerprint per hour, 30 per hour in total, 120 per process. Suppressed
  repeats fold into `occurrences` on the next report of that fingerprint.
- Transport (`SentryTransportPolicy.standard`):
  - at most 20 envelopes pending on disk (oldest dropped), 256 KiB each, one
    upload in flight
  - backoff 30 s, doubling to 1 h, on transport or 5xx failures
  - `X-Sentry-Rate-Limits` honoured on every status including 200; `429`
    falls back to `Retry-After`; other 4xx envelopes are discarded
  - pending envelopes live in Caches/`Diagnostics/pending` and retry on the
    next submit, on foreground, or when the backoff timer fires
  - turning reporting off discards the queue and stops uploads; nothing
    recorded before the switch leaves the device after it

## Tester controls and disclosure

Settings → Advanced → Diagnostic Reports → *Send Diagnostic Reports* controls
`diagnostics.reportingEnabled`.

- **Off means off:** history stops, the playback sampler stops, and the
  pending queue is discarded. Switching off mid-playback cancels the sampler's
  timer; switching back on resumes the same attempt with fresh freeze and
  frequent-stall windows. An in-flight renderer metrics request may finish;
  none start while opted out.
- HUD, decode trace and benchmark sampling have their own controls.
- While on, the renderer metrics load runs every two seconds, asynchronously,
  with no SwiftUI body reads. It had no measurable effect on frame delivery on
  Apple TV (see [physical device
  verification](#physical-device-verification)).
- Release builds default on. Debug builds default off so development never
  spends quota; `-diagnostics.reportingEnabled YES` turns a debug run on.
- The footer under the toggle states what a report contains.
- `PrivacyInfo.xcprivacy` declares *Other Diagnostic Data* and *Performance
  Data*, not linked and not used for tracking. App Store Connect's privacy
  answers must match.
- Retention is the Developer plan's 30-day lookback (per sentry.io/pricing).
  The Settings footer states the same number and must track it.

## Sentry setup

- **DSN.** A client key that can only submit to this project. It is injected
  at build time, never tracked: the `LAGOON_SENTRY_DSN` build setting lands in
  Info.plist and `DiagnosticsConfiguration` reads it back;
  `-diagnostics.sentryDSN` overrides it for a capture run. A build with no DSN
  (every ordinary checkout) has no sink and reports nothing.
  `scripts/upload-testflight.sh` requires the variable.
- **IP addresses.** Project → Settings → Security & Privacy → *Prevent
  Storing of IP Addresses* is on. No scrubbing rules are relied on; the app
  never sends the fields they would scrub, nor a `user` or `request` object.
  Events declare `platform: native`, because for `platform: cocoa` Sentry
  fills `user.ip_address` from the connection and derives a location (this
  happened while the setting was off). So the setting is a second line of
  defence. `SentryEnvelopeTests` pins the platform.
- **Quota.** Developer plan, 5,000 errors a month, one seat. Check Settings →
  Subscription monthly. The client-side limits cap a worst case at a few dozen
  reports per process.
- **Finding reports.** Issues, filtered by `release`, `build`, `videoCodec`,
  `delivery`, `stage`, `route`. Each event has `extra` with every field and a
  `history.json` attachment (`t` in seconds relative to the incident,
  negative before it).
- No `sentry-cli`, dSYM upload or source maps. Stack traces for any failure
  class would need their own decision.

## Verifying

Unit tests: `DiagnosticSchemaTests`, `DiagnosticHistoryTests`,
`IncidentSuppressorTests`, `DiagnosticsHubTests`,
`DiagnosticRouteTemplateTests`, `SentryEnvelopeTests`,
`SentryTransportPolicyTests`, `PlaybackFreezeDetectorTests`,
`PlaybackDegradationPolicyTests`, `PlaybackIncidentMonitorTests`,
`PlaybackFailureDetailTests`, `DiagnosticPrivacyTests`.

Inspect payloads without touching Sentry:

```sh
scripts/diagnostics-capture-server.py --port 8765 --out /tmp/lagoon-diagnostics
xcrun simctl launch <udid> ee.helop.lagoon \
  -diagnostics.reportingEnabled YES \
  -diagnostics.sentryDSN http://key@127.0.0.1:8765/1 \
  -debug.regressionFailFirstDelivery delivery
```

Play any direct-play title: four seconds in, the hook injects a delivery
failure, the ladder falls to remux, and a `playback.fallback` envelope lands
in the output directory as `*.event.json` and `*.history.json`. Closing the
player after thirty seconds exercises the stop path; `--status 429` and
`--status 500` exercise rate limiting and backoff. Read the JSON for anything
that should not be there.

On a paired Apple TV:

- Start the server with `--bind 0.0.0.0` and point the DSN override at the
  Mac's address (`NSAllowsLocalNetworking` permits plain HTTP).
- Launch a Debug build with `xcrun devicectl device process launch --console
  --terminate-existing ee.helop.lagoon -- <arguments>`.
  `-debug.playerRegression YES -debug.regressionBootstrapPublicDemo YES
  -debug.regressionFindPlayable YES` signs into the demo in memory and picks a
  title.
- Injection hooks are Debug-only (a Release build can only send real
  incidents): `-debug.regressionFailFirstDelivery delivery|undecodable`, and
  `-debug.simulateDeliveryStall YES` with
  `-debug.starvationInjectionDelaySeconds` and
  `-debug.starvationInjectionDurationSeconds`.
- Transport logs are `os_log` and do not reach the devicectl console. `xcrun
  devicectl device copy from --domain-type appDataContainer
  --domain-identifier ee.helop.lagoon --source Library/Caches/Diagnostics`
  shows whether the pending queue drained.
- Sentry's edge answers 200 to any key, so acceptance means the event appears
  under Issues.

### Physical device verification

Apple TV 4K (3rd generation), tvOS 26.6, Debug build, capture server on the
Mac, public demo. No envelope contained the demo host, the Mac's address,
server names, item ids, titles, the account name, `Authorization`,
`MediaBrowser` or `localizedDescription`.

| Scenario | Injection | Result |
| --- | --- | --- |
| Healthy session | 70 s window | no envelope |
| Recovered fallback | `regressionFailFirstDelivery delivery` | `playback.fallback` (`delivery`), `outcome=recovered`, `elapsedMs=4304`, to remux |
| Undecodable fallback | `regressionFailFirstDelivery undecodable` | `playback.fallback` (`undecodable`), `outcome=recovered`, transcode rung in 6.8 s |
| 12 s delivery suspension | `simulateDeliveryStall`, 4 s audio lead | ~6 s stall, no reprime: no envelope (below thresholds, as designed) |
| 30 s delivery suspension | same, 30 s | `playback.stall` (`reprime`, `video`), then at exit `playback.degraded` (`reprimes`) |
| API failure | synthetic server returning 500 | `api.requestFailed` (`jellyfin`, `QuickConnect.Enabled`, `status500`) |

An exhausted ladder could not be forced against the demo, which serves every
rung. A production-DSN run drained the pending queue within 40 s and the event
appeared under Issues.

**Reporting on vs off** (Release, 4K Dolby Vision profile 8, 600 s in, two
interleaved pairs): 0 dropped frames in every run, footprint within 2 MB. This
is the sampler's cost over an already instrumented run; CPU and energy with
the bench off were not measured.

Not yet verified: a physical iPhone, and a Release build sending a naturally
occurring incident.
