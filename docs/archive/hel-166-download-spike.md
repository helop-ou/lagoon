# Offline download spike (HEL-166)

**Date:** 2026-09-12. **Revision:** 0f992c2 (spike), fe5f50c (engine fix).
**Environment:** iPhone 17 Pro simulator, iOS 26, Debug build, public demo
server (`demo.jellyfin.org/stable`, user `demo`), Mac on a fast link.
**Status:** the spike's questions are answered; the code is Debug-only and
throwaway. The feature plan and acceptance live on HEL-166.

## Questions

1. Does a background `URLSession` carry an original-file download through
   suspension and termination, and does the engine play the result?
2. Can a server transcode be carried as one background transfer rather
   than a chain of HLS segment fetches, and does the engine play it?

## Method

`DownloadSpikeStore` (Debug, iOS) owns one background session
(`ee.helop.lagoon.downloads.spike`), a JSON manifest under
`Application Support/Lagoon/Downloads` (excluded from backup), and a
delegate that moves the finished file into place inside
`didFinishDownloadingTo`. Task descriptions carry the entry id and file name
so events for tasks that finished while the process was dead still route.
`-debug.downloadSpikeItemID <id> -debug.downloadSpikeKind original|transcode`
starts a download after sign-in; `PlaybackController` plays a completed
download from disk in place of the stream; the bench hook
(`-debug.benchSearchTerm`) then opens the title hands-off. The simulator was
driven with `simctl launch`, `simctl terminate` (SIGKILL) and a second app in
front for backgrounding; state was read from the manifest and the
`downloads.spike` log category.

## Results

| Run | Outcome |
| --- | --- |
| Night of the Living Dead, original, 597 MB | Complete at the declared size; plays from disk as DirectPlay with no cache lines and 0 dropped frames in 20 s |
| Dracula, original, 2.46 GB | Advanced 91 → 260 MB while another app was in front; 331 → 544 MB across a SIGKILL and relaunch (task re-adopted) |
| Sahara, original, 737 MB | SIGKILLed 10 s in; finished while the process was dead; the relaunched process received the completion and moved the file |
| Caminandes: Gran Dillama, progressive transcode (`stream.ts`, 8 Mbps, 1080p) | One response, 76 MB for 146 s (4.2 Mbps average) at the demo server's encode pace of roughly a third of real time; survived a SIGKILL mid-encode; plays from disk (H.264 high 1080p, AAC) with a clean picture |

Findings that change the plan or the code:

- **The demo user lacks `EnableContentDownloading`**, so
  `Items/{id}/Download` answers 403. The spike falls back to the static
  stream; the feature reads `Users/Me` and hides the control instead.
- **FFmpeg's file protocol does not percent-decode.** A file URL under
  "Application Support" reached libavformat as `Application%20Support` and
  failed with ENOENT. The engine now hands libavformat a plain path for
  file URLs (fe5f50c). The playback cache never hit this because Caches has
  no space in its path.
- **`playSessionId` must be unique per transcode request.** Without it a
  restarted request was handed an abandoned earlier job's output and the
  picture showed block corruption; with it the encode is fresh.
- **Audio reprimed twice in the first 20 s of the transcode playback** on the
  simulator (`Recovery: audio ×2`). This matches the simulator's known audio
  caveat; a device run decides whether the MPEG-TS path has an audio issue.
- **One transfer was lost** (Dracula at 2.07 of 2.46 GB) at a relaunch made
  before the delegate routed by task description, so its failure or
  completion was dropped unrouted. After that fix the Sahara run passed.
  Treat it as a spike bug, not a platform limit, and re-check in the MVP.
- The HUD's source facts still describe the server's media source, not the
  local file; the feature stores its own metadata snapshot, as planned.

## Not tested

A user force-quit from the app switcher (the simulator cannot), Wi-Fi to
cellular transitions, `allowsExpensiveNetworkAccess` behaviour, resume data
after a transport failure (only after an explicit pause), and any physical
device. The demo server's transcode speed is not representative of fixture.

## Consequence

Both kinds ride on background download tasks; the progressive single-response
transcode is the primary path and HLS batching is not needed for the MVP.
