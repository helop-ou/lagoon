# Stream resolution

The reasoning behind negotiation and the delivery ladder in the [playback
guide](../../playback.md). See also the [notes index](README.md).

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.lagoon`, which
   mirrors exactly what the engine can play. Its fMP4 HLS transcoding profile
   lands back inside the same envelope, so a fallback is never answered with
   something undecodable. The literal in `DeviceProfile.swift` is the
   authority on codecs; the server decides.
2. Take the first `MediaSource` and resolve a URL with
   `JellyfinClient.streamURL`:
   - `SupportsDirectPlay` → `Videos/{id}/stream?static=true&mediaSourceId=…`
     (+ `deviceId`, `Tag`), PlayMethod `DirectPlay`.
   - else `SupportsDirectStream` → `Videos/{id}/stream.{container}` with the
     same query, PlayMethod `DirectStream`. The container can be an ffprobe
     list; take the first entry.
   - else the server's `TranscodingUrl`, PlayMethod `Transcode`. It is
     server-relative with its own query: resolve it against the server URL,
     never rebuild it. libavformat's HLS demuxer reads the fMP4 playlist; the
     video-copy variant is listed first.
3. The engine plays it. Jellyfin's HLS playlists cover the full duration, so
   resume is the same initial seek as direct play, and reported positions stay
   absolute for every method.

None of these URLs carries the token; see [Auth](../../jellyfin-api.md#auth)
for how returned URLs are sanitized.

### What this device is offered

`DeviceProfile.everything` is the engine's envelope. `DeviceProfile.lagoon`
is that envelope minus what the running hardware cannot decode, and is what
gets sent. The subtraction is a short transform over the literal, not a second
literal, so the envelope stays the single statement of support.

Only two hardware checks, for specific reasons:

- **HEVC.** `VideoToolboxDecoder` requires a hardware decoder
  (`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`), so
  without one HEVC fails outright with -12906.
- **AV1.** Takes the same compressed path with hardware, and a bounded
  libdav1d software path without.

Everything else survives without hardware: H.264 goes to
`AVSampleBufferVideoRenderer` compressed and may decode in software; VP9 and
legacy codecs use libavcodec.

**Do not gate anything else on `VTIsHardwareDecodeSupported`.** It reports
hardware alone, and on the tvOS simulator it says false for every codec,
including the H.264 the simulator plays.

Removing HEVC touches three places, and missing one undoes the others:

- the direct-play codec list
- the `hevc` codec profile (or the server sees conditions for a codec not
  offered)
- the **transcoding** profile. Left as `hevc,h264`, the server can answer a
  fallback with HEVC, and every rung fails with -12906.

H.264 is capped at 1080p in the reduced profile. Without the cap a 4K HEVC
film would be requested as H.264 _at 4K_, a huge transcode the device cannot
decode anyway (observed: the player stuck at 0 s with empty queues). This is a
heuristic; VideoToolbox answers per codec, not per resolution. On Jellyfin
10.11 a 4K HEVC/DoVi source direct-plays under the full profile and returns as
`VideoCodec=h264 MaxWidth=1920 MaxHeight=1080` under the reduced one.

All targeted hardware has HEVC, so today this matters on the simulator. The
real payoff is AV1: A17/M3-class devices use hardware, older ones stay inside
the same honest envelope through software.

### What a metered path is offered

`NetworkPathObserver` watches `NWPathMonitor`, and `cappedForMeteredPath`
bounds the profile when the path is expensive (cellular, personal hotspot) or
constrained (Low Data Mode). Without it an 89 Mbps remux was offered as direct
play over cellular; with it that source becomes a 720p 2.5 Mbps offer with
direct play refused. (The playback cache already skipped proactive fills on
such paths.)

- **iOS only.** Apple has no reason to call an Apple TV's path expensive.
  Widening it is a one-line change.
- **`maxStaticBitrate` comes down with `maxStreamingBitrate`.** The server
  checks the static ceiling before offering the original file, so capping
  only streaming would still direct-play the remux.
- **A resolution ceiling comes too.** Bitrate alone leaves `MaxWidth` unset,
  and the server answers a 4K source with a 4K re-encode at 3 Mbps.
- **The viewer can override it** (Settings → Playback → Cellular). Apple says
  a path is expensive, never that it is slow; fast tethered 5G and a
  throttled hotspot look the same.

Known limits, both deliberate:

- The profile is built per `PlaybackInfo` call, so a path change mid-title
  does not re-negotiate a working stream.
- Until `NWPathMonitor` reports, the observer says "unrestricted", so a cold
  launch on cellular can miss the cap once.

`boundedTo(_:width:height:)` **tightens** rather than skips when two bounds
apply (fallback 1080p, metered 720p), so the smaller ceiling always wins.

### When playback fails: the delivery ladder

Negotiation happens once, before the first frame. When the engine cannot
handle what was negotiated, the controller re-negotiates one rung lower and
resumes at the interrupted position. The viewer sees a reload, not an error.

| rung | PlaybackInfo flags | what the server does |
| --- | --- | --- |
| `negotiated` | all four true (Jellyfin's defaults) | direct play: the original file, no server work |
| `remux` | `EnableDirectPlay=false` | HLS fMP4, video **stream-copied**: a container rewrite, no encoder |
| `transcode` | also `EnableDirectStream=false`, `AllowVideoStreamCopy=false` | HLS fMP4, video re-encoded |

**The middle rung is not `SupportsDirectStream`.** Withdrawing direct play
returns both flags false and a `TranscodingUrl` either way. On 10.11 the remux
and transcode URLs differ only by `allowVideoStreamCopy=false`. That flag is
the difference between a container rewrite and minutes of server CPU per
viewer.

The next rung depends on `PlaybackEngineFailure.Cause`, i.e. whether
redelivering the same samples could help:

- `.delivery` (container, transport or an AVFoundation object failed): a
  server rewrite routinely fixes it, so go to the cheap rung.
- `.undecodable` (codec outside the envelope, VideoToolbox declined, decode
  failed): a stream copy returns the same bitstream, so **skip remux** and go
  straight to the re-encode.

Both lower rungs are HLS, which loses the embedded subtitle track (the engine
cannot demux subtitles from a Jellyfin transcode). Another reason the ladder
descends only after a real failure.

**Only the bottom rung is bounded to HD** (`DeviceProfile.lagoon(for:)` →
`boundedForRealtimeTranscode`): `MaxWidth=1920 MaxHeight=1080` and a 20 Mbps
ceiling. Unbounded, it asked the server to re-encode at the source's shape
(`VideoBitrate=119360000`, no size limits: 4K HEVC at 120 Mbps), which a
server without a hardware encoder produced at 9.5 fps for a 30 fps source. The
bound never applies to `remux`, where a resolution condition would force the
re-encode remux exists to avoid. Negotiated and remux rungs send the full
envelope, so 4K direct play is untouched.

Mechanics:

- The retry reuses the episode-handoff teardown
  (`preservingPlayerSurface: true`), so the viewer keeps the last frame while
  the next rung negotiates.
- The ladder belongs to one item and resets for the next.
- `next` only moves down, so a stream that fails every way ends in the error
  overlay, not a restart loop.
- A failure while the next attempt is still starting takes the terminal path
  rather than tearing down an engine mid-flight.
- `debug.regressionFailFirstDelivery` (`delivery` or `undecodable`) fails the
  first attempt on purpose, since this path only runs when something is
  broken.
- `failure.message` reaches `errorMessage` only when the ladder runs out, so
  the HUD shows `Rung:` / `Fell n:` / `Why n:` once a rung has been descended.
  Otherwise a successful fallback would leave only a signpost.

### Disc images

A disc image is a filesystem, not a stream. Jellyfin reports `VideoType` `Iso`,
a `Container` probed _inside_ the disc (`ts` for Blu-ray), and still
`SupportsDirectPlay` true. Trusting that delivers the raw image, which
libavformat cannot open (`ffprobe` fails with `Invalid data found when
processing input`). So `MediaSource` decodes `VideoType`/`IsoType`, and
`PlaybackSourceLayout` classifies the source: a file, a Blu-ray image, a DVD
image, an untyped image, or a folder rip.

**No client can read a folder rip.** Jellyfin returns the folder, and
`MediaSourceInfo` names none of the files inside it. A rip therefore goes
straight to the server remux, chosen deliberately rather than after a failed
open.

How the engine reads disc images, and the container, seek and decode-session
failures behind the verdicts, are in its [stream recovery
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/stream-recovery.md).
