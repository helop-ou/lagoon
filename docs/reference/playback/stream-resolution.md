# Stream resolution

Playback engineering notes retained during the September 10, 2026 documentation
cleanup. Start with the [current playback guide](../../playback.md) and the
[notes index](README.md).

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.lagoon`, a
   capability profile mirroring exactly what the engine can play — including
   an fMP4 HLS transcoding profile whose output lands back inside the same
   envelope, so a fallback cannot be answered with something undecodable. The
   literal in `DeviceProfile.swift` is the authority on the codec list; the
   server does the deciding.
2. Pick the first `MediaSource` and resolve a URL via
   `JellyfinClient.streamURL`:
   - `SupportsDirectPlay` → `Videos/{id}/stream?static=true&mediaSourceId=…`
     (+ `deviceId`, `Tag`), PlayMethod `DirectPlay`.
   - else `SupportsDirectStream` → `Videos/{id}/stream.{container}` with the
     same static query, PlayMethod `DirectStream` (server-must-proxy case;
     container can arrive as an ffprobe list — take the first entry).
   - else the server-provided `TranscodingUrl` (server-relative with its own
     query string — resolve against the server URL, don't rebuild it),
     PlayMethod `Transcode`. libavformat's HLS demuxer reads the fMP4
     playlist; the video-copy variant is listed first in the master.
3. The engine plays it. Jellyfin's HLS playlists cover the full duration, so
   resume is the same initial demuxer seek as direct play and position
   reporting stays absolute in every play method.

None of those URLs carries the token. A server-issued `TranscodingUrl` or
subtitle `DeliveryUrl` can arrive with one as `ApiKey` or the deprecated
lowercase `api_key`, which Jellyfin 12 disables by default;
`MediaRequestAuthorization` strips either spelling on the Jellyfin origin and
sends the header instead — see
[network transport](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/transport.md).

### What this device is offered

`DeviceProfile.everything` is the envelope the engine can play;
`DeviceProfile.lagoon` is that envelope minus whatever the running hardware
cannot decode, and it is what gets sent. The subtraction is deliberately a
short transform over the literal rather than a second literal, so the envelope
stays the single statement of what the engine supports.

Two hardware capabilities are consulted, for specific reasons.
`VideoToolboxDecoder` creates its session with
`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`, so
without a hardware decoder HEVC does not degrade — it fails outright with
-12906. AV1 uses that same compressed path when hardware support is present
but, unlike HEVC, has a bounded libdav1d software path when it is not.
Everything else survives a missing hardware decoder: H.264 reaches
`AVSampleBufferVideoRenderer` compressed and may be decoded in software, VP9
and the legacy codecs are libavcodec on the CPU.

**Do not gate more on `VTIsHardwareDecodeSupported` than those two routing
decisions.** It reports hardware alone: on the tvOS simulator it answers false
for *every* codec, including the H.264 the simulator plainly plays, so gating
wholesale would strip the profile to nothing.

Removing HEVC touches three places, and missing any one undoes the other two:
the direct-play codec list, the obvious one; the `hevc` codec profile, or the
server sees conditions for a codec it is not being offered; and the
**transcoding** profile, which is the one that bites. Left listing `hevc,h264`,
the transcoding profile lets the server answer a fallback request with an
HEVC rendition — exactly the format the device just said it cannot decode.
That is how a simulator run of the delivery ladder failed every rung with
-12906.

H.264 is also capped at 1080p in the reduced profile. Without that cap the
subtraction makes things worse: a 4K HEVC film stops direct playing and the
server is asked for H.264 *at 4K*, an enormous transcode for a device with no
chance of decoding it — observed doing exactly that, the player sitting at 0 s
with empty queues. Hardware that cannot decode HEVC will not manage 4K H.264
either. It is a heuristic, not a measurement: VideoToolbox answers per codec,
never per resolution. On Jellyfin 10.11 a 4K HEVC/DoVi source direct-plays
under the full profile and comes back as
`VideoCodec=h264 MaxWidth=1920 MaxHeight=1080` under the reduced one.

Targeted hardware has HEVC everywhere, so this is defensive rather than
load-bearing; it shows today on the simulator, which negotiates H.264 on its
own. Its real payoff is AV1: A17/M3-class devices take the compressed hardware
path while older ones stay inside the same honest envelope through software.

### What a metered path is offered

`DeviceProfile` advertised 120 Mbps on every device and every network path, so
an 89 Mbps remux was offered as **direct play over cellular** — unwatchable and
expensive at once. The playback cache already drew this distinction one layer
down (proactive range fills set `allowsExpensiveNetworkAccess` and
`allowsConstrainedNetworkAccess` false); the profile simply never asked.
`NetworkPathObserver` watches `NWPathMonitor` and `cappedForMeteredPath` bounds
the profile when the path is expensive (cellular, personal hotspot) or
constrained (Low Data Mode), which turns that source into a 720p 2.5 Mbps
offer with direct play refused.

Four things are deliberate:

- **iOS only.** An Apple TV is a wired or strong-Wi-Fi appliance Apple has no
  reason to call expensive, so applying it there would be dead code that could
  only ever surprise. Widening it is a one-line change.
- **`maxStaticBitrate` comes down with `maxStreamingBitrate`.** The static
  ceiling is the one the server checks before offering the original file, so
  capping only the streaming figure would let the remux direct-play anyway.
- **A resolution ceiling rides along**, which measurement argued for but
  was not originally requested: capping bitrate alone leaves `MaxWidth`
  absent, so the server answers a 4K source with a 4K re-encode at 3 Mbps —
  minutes of server CPU for a picture nobody wants on a phone that cannot
  show it.
- **The viewer can override it** (Settings → Playback → Cellular). Apple
  reports that a path is *expensive*, never that it is *slow*, and a fast
  tethered 5G connection is indistinguishable from a throttled hotspot from
  inside the app.

Two known limits, both deliberate. The profile is built once per `PlaybackInfo`
call, so a path changing mid-title does not re-negotiate — the alternative is
tearing down a working stream because a phone moved between access points. And
until `NWPathMonitor` has reported, the observer answers "unrestricted", so a
first negotiation on a cold launch over cellular can miss the cap once; that
errs toward the behaviour that existed before.

`boundedTo(_:width:height:)` resolves two geometry bounds by **tightening**
rather than by skipping, because two transforms now ask for one and no longer
ask for the same number: the fallback bound is 1080p, the metered cap 720p.
Whichever applies second, the smaller ceiling survives.

### When playback fails: the delivery ladder

Negotiation happens once, before the first frame, so a direct play the engine
cannot actually handle used to end the film: the error overlay's only control
is **Back**. The controller re-negotiates instead, descending one rung at a
time and resuming at the position the failure interrupted. The viewer sees the
player reload, not an error.

| rung | PlaybackInfo flags | what the server does |
| --- | --- | --- |
| `negotiated` | all four true (Jellyfin's own defaults) | direct play — the original file, no server work |
| `remux` | `EnableDirectPlay=false` | HLS fMP4, video **stream-copied**: a container rewrite, no encoder |
| `transcode` | also `EnableDirectStream=false`, `AllowVideoStreamCopy=false` | HLS fMP4, video re-encoded |

**The middle rung is not `SupportsDirectStream`.** Jellyfin couples the two:
withdrawing direct play returns both flags false and hands back a
`TranscodingUrl` regardless. Against 10.11 the remux and transcode rungs return
URLs differing by exactly one parameter, `allowVideoStreamCopy=false`. That
single flag is the whole distinction, and it is why the two rungs are worth
keeping apart: a remux costs the server a container rewrite, a transcode costs
it minutes of CPU per viewer.

Which rung comes next depends on whether redelivering the same samples could
possibly help, which is what `PlaybackEngineFailure.Cause` records.
`.delivery` — the container, the transport, or an AVFoundation object failed —
is routinely fixed by a server-side rewrite, so the next rung is the cheap one.
`.undecodable` — a codec outside the envelope, a VideoToolbox session the
hardware declined, a decode that failed — would get the same bitstream back
from a stream copy, so the remux rung is **skipped**: straight to the re-encode.
Both lower rungs arrive as HLS, which costs the embedded subtitle track (the
engine cannot demux subtitles out of a Jellyfin transcode), a further reason
the ladder is only ever descended after a real failure, never pre-emptively.

**The bottom rung is bounded to HD, and only the bottom rung**
(`DeviceProfile.lagoon(for:)` → `boundedForRealtimeTranscode`). Left alone it
inherited the direct-play envelope and asked the server to re-encode at the
source's own shape: measured against the fixture server,
`VideoBitrate=119360000` with no `MaxWidth`/`MaxHeight` at all, i.e. 4K HEVC at
120 Mbps. That figure only ever meant "the bitrate of an untouched file this
device will pull" and is meaningless as an instruction to an encoder; a server
without a hardware encoder answers it at **9.5 fps for a 30 fps source**, so
the rung meant to rescue playback stalls worse than the failure that triggered
it. The bound sends `MaxWidth=1920 MaxHeight=1080` and a 20 Mbps ceiling
instead. It deliberately does **not** apply to `remux`: that rung stream-copies
the video, and a resolution condition there would force exactly the re-encode
it exists to avoid. The negotiated and remux rungs still send the full
envelope, so 4K direct play is untouched.

The retry reuses the episode-handoff teardown (`preservingPlayerSurface: true`)
rather than a full one: the viewer keeps the last frame instead of a black
screen while the next rung negotiates, and it is the path autoplay has
hardened. It also sidesteps the retirement timeout that made every early
fallback fail — which was the engine-revival bug, not, as first recorded
here, a `removeRenderer` completion lost when SwiftUI destroyed the layer;
a healthy engine dismissed with the surface torn down detaches perfectly.

Bounds worth knowing: the ladder belongs to one item and resets for the next;
`next` only ever moves downward, so a stream that fails every way ends in the
overlay rather than a restart loop; and a failure arriving while the next
attempt is *still starting* takes the terminal path rather than tearing down an
engine mid-flight. `debug.regressionFailFirstDelivery` (`delivery` or
`undecodable`) fails the first negotiated attempt on purpose, since this path
only ever runs when something is already broken.

**A fallback that succeeds used to erase its own explanation.**
`failure.message` carries the detail that is the whole reason the ladder ran
— the VideoToolbox status, the renderer error. But it only reaches
`errorMessage` when the ladder runs *out* of rungs, so a descent that then
played left a signpost as its only trace. That trace is readable through
Instruments, and therefore only on a pairable device. The playback HUD
carries it (`Rung:` / `Fell n:` / `Why n:`), appearing only once a rung has
been descended.

### Disc images

A disc image is a filesystem, not a stream, and Jellyfin describes one
accurately and then contradicts itself: `VideoType` says `Iso`, `Container`
reports the format probed *inside* the disc (`ts` for a Blu-ray), and
`SupportsDirectPlay` still comes back true. Take the last at face value and the
static stream delivers the image itself, which libavformat cannot open — stock
`ffprobe` fails on the same URL with `Invalid data found when processing
input`. `MediaSource` therefore decodes `VideoType`/`IsoType`, and
`PlaybackSourceLayout` turns them into what the ladder needs: a file, a Blu-ray
image, a DVD image, an image the server did not type, or a folder rip.

**A folder rip cannot be read by any client.** Jellyfin's `Video.cs` returns the
*folder* for a disc, and `MediaSourceInfo` exposes no property naming the files
inside one — Emby's `PlayableStreamFileNames` is gone. A rip's honest outcome is
therefore the server remux, chosen deliberately rather than discovered through a
failed open. Infuse handles rips because it is usually reading SMB/NFS rather
than Jellyfin.

The mechanism behind each of those — a container that describes no bitstream,
a seek that lands in an open GOP, a decode session the system reclaimed, how a
disc image is actually read, and what MPEG-TS breaks that no probe reports —
belongs to the engine now, and is in its [stream recovery
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/stream-recovery.md).
