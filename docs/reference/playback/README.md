# Playback engineering notes

**These are deep notes, not a document to read end to end.** Start with the
[playback guide](../../playback.md), which carries the rules that matter while
changing the player. Come here when you are working inside one of these areas
and need the reasoning or the measurements behind a particular decision.

They record why the code is shaped the way it is, including approaches that
were tried and abandoned. Treat a measurement as evidence for the decision it
justified, not as a current acceptance result.

**One engine for everything** — the maintainer's call. All playback runs
through the Lagoon sample-buffer engine. The AVPlayer and mpv players were
removed the same day the decision was made: no split paths, no per-container
routing.

The FFmpeg libraries come from the local `Packages/LagoonFFmpeg` package. It
pins three Libav\* static xcframeworks from MPVKit's 1.0.0 release — avcodec,
avutil and swresample, from FFmpeg 8.1.2 — plus dav1d, uavs3d and lcms2.
MPVKit itself, libmpv, MoltenVK and libplacebo are no longer in the project.

The archives are static, so the app binary links only the objects it
references and the bundle embeds 7 framework shells instead of 27. Lagoon
builds two of those seven itself: dav1d, for its arm64 assembly, and
libavformat, without a network stack.

| Topic | Notes |
| --- | --- |
| Input and negotiation | [Network transport](transport.md), [stream resolution and disc images](stream-resolution.md) |
| Decode and performance | [The engine](engine.md), [codec, timing and subtitle details](codecs-and-subtitles.md) |
| Rendering | [Queues and renderers](queues-and-renderers.md), [system media, display mode and HUD](system-integration.md) |
| Measurement and ownership | [Frame-loss bench and memory ceiling](frame-loss-bench.md), [cache and teardown](cache-and-teardown.md) |
| UI and server state | [Progress reporting and player controls](controls-and-reporting.md) |
| Group playback | [Watch Together](watch-together.md): opening, commands, drift, the sheet and panel |
| Failure reporting | [Diagnostic reporting](diagnostics.md): schema, detectors, limits, Sentry setup |
