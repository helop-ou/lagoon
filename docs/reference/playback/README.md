# Playback engineering notes

Implementation rationale and measurements behind the [current playback guide](../../playback.md),
retained during the September 10, 2026 documentation cleanup and split by topic.
Dated experiments describe their recorded revision; they are not a release
checklist or proof of current hardware acceptance.

**One engine for everything** (the maintainer's call, 2026-08-16, HEL-48): all
playback runs through the Lagoon sample-buffer engine. The AVPlayer and mpv
players were removed the same day the decision was made — no split paths, no
per-container routing. Since 2026-08-17 (M6) the FFmpeg libraries come from
the local `Packages/LagoonFFmpeg` package, which pins three Libav* static
xcframeworks from MPVKit's 1.0.0 release (FFmpeg 8.1.2: avcodec, avutil,
swresample) plus dav1d, uavs3d and lcms2 — MPVKit itself, libmpv, MoltenVK,
and libplacebo are no longer in the project. The archives are static: the app
binary links only referenced objects, and the bundle embeds 7 framework shells
instead of 27. Lagoon builds two of those seven itself: dav1d for its arm64
assembly (HEL-137), and libavformat without a network stack (HEL-142).

| Topic | Notes |
| --- | --- |
| Input and negotiation | [Network transport](transport.md), [stream resolution and disc images](stream-resolution.md) |
| Decode and performance | [The engine](engine.md), [codec, timing and subtitle details](codecs-and-subtitles.md) |
| Rendering | [Queues and renderers](queues-and-renderers.md), [system media, display mode and HUD](system-integration.md) |
| Measurement and ownership | [Frame-loss bench and memory ceiling](frame-loss-bench.md), [cache and teardown](cache-and-teardown.md) |
| UI and server state | [Progress reporting and player controls](controls-and-reporting.md) |
| Failure reporting | [Diagnostic reporting](diagnostics.md): schema, detectors, limits, Sentry setup |
