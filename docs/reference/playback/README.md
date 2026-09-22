# Playback engineering notes

**Deep notes, not a document to read end to end.** Start with the [playback
guide](../../playback.md), which carries the rules. Come here for the
reasoning and measurements behind a decision in one area. A measurement is
evidence for the decision it justified, not a current acceptance result.

## The engine is not here

All playback runs through the `LagoonEngine` package in its own repository;
there is no AVPlayer or mpv path. Demux, decode, render, queues, the byte
cache, the FFmpeg build and per-codec behaviour are documented there:

- [The engine guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md):
  pipeline, transport, lifecycle, memory, failure verdicts
- [Engineering notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/README.md):
  decode, queues and renderers, cache and teardown, transport, codecs, stream
  recovery, system integration, memory ceilings

These notes cover this side of the boundary: what Lagoon negotiates with
Jellyfin, what it does with a verdict, how the player presents itself, and
what it reports.

| Topic | Notes |
| --- | --- |
| Negotiation | [Stream resolution and disc images](stream-resolution.md) |
| System and presentation | [System media, display mode and HUD](system-integration.md) |
| Measurement | [The frame-loss bench harness](frame-loss-bench.md) |
| UI and server state | [Progress reporting and player controls](controls-and-reporting.md) |
| Group playback | [Watch Together](watch-together.md): opening, commands, drift, the sheet and panel |
| Failure reporting | [Diagnostic reporting](diagnostics.md): schema, detectors, limits, Sentry setup |
