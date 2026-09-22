# Playback engineering notes

**These are deep notes, not a document to read end to end.** Start with the
[playback guide](../../playback.md), which carries the rules that matter while
changing the player. Come here when you are working inside one of these areas
and need the reasoning or the measurements behind a particular decision.

They record why the code is shaped the way it is, including approaches that
were tried and abandoned. Treat a measurement as evidence for the decision it
justified, not as a current acceptance result.

## The engine is not here any more

All playback runs through the `LagoonEngine` package, which lives in its own
repository. The AVPlayer and mpv players were removed the day that decision
was made: no split paths, no per-container routing.

Demux, decode, render, queues, the byte-source cache, the FFmpeg build and the
codec-by-codec behaviour are documented with the engine, not here:

- [The engine guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md)
  — pipeline, transport, lifecycle, memory, failure verdicts
- [Engineering notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/README.md)
  — decode, queues and renderers, cache and teardown, transport, codecs,
  stream recovery, system integration, memory ceilings

What stays here is everything on this side of that boundary: what Lagoon
negotiates with a Jellyfin server, what it does with a verdict, how the player
presents itself, and what it reports.

| Topic | Notes |
| --- | --- |
| Negotiation | [Stream resolution and disc images](stream-resolution.md) |
| System and presentation | [System media, display mode and HUD](system-integration.md) |
| Measurement | [The frame-loss bench harness](frame-loss-bench.md) |
| UI and server state | [Progress reporting and player controls](controls-and-reporting.md) |
| Group playback | [Watch Together](watch-together.md): opening, commands, drift, the sheet and panel |
| Failure reporting | [Diagnostic reporting](diagnostics.md): schema, detectors, limits, Sentry setup |
