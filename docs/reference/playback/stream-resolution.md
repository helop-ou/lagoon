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
[network transport](transport.md#network-transport).

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

### When the container describes no bitstream

Matroska and MP4 are supposed to carry HEVC's VPS/SPS/PPS in the
`CodecPrivate`/`hvcC` record, and `SampleBufferFactory.videoFormatDescription`
builds the format description from it. hev1-style muxing is legal and does not:
it leaves `numOfArrays = 0` and repeats the parameter sets in-band instead.
Found on a 4K WEBDL whose entire `hvcC` was 23 bytes of header.

Nothing complains at the time. `CMVideoFormatDescriptionCreate` builds a
description around the empty record and returns `noErr`; the refusal arrives
later, from `VTDecompressionSessionCreate`, as -4 — while the same file's
in-band parameter sets yield a working 3840x2160 session. So it reads as a
hardware fault and is a container one, which is how it was first misread, and
every other tool disagrees for the same reason: ffprobe, Jellyfin's probe and
libavcodec all parse parameter sets in-band. The file looks healthy everywhere
except the one place the client trusts the container.

`FFmpegDemuxer` therefore checks the record before building anything
(`SampleBufferFactory.hevcExtradataCarriesParameterSets`) and, when it
describes nothing, harvests VPS/SPS/PPS from the opening NALs of the first
video packet and builds through
`CMVideoFormatDescriptionCreateFromHEVCParameterSets`. Notes worth keeping:

- **The header stays valid even with no arrays behind it**, so
  `lengthSizeMinusOne` still describes the packets correctly and the harvest
  can walk them. Parameter sets normally precede the IDR slices in the first
  packet, so the read-ahead ends there; it is bounded at 64 packets regardless.
- **The context is rewound afterwards.** `open()` runs before the demux loop,
  which still owes the renderers every packet from the beginning. A failed
  rewind costs the opening packets and is deliberately not fatal: that is worth
  less than the decoder the harvest buys.
- **Dolby Vision atoms are not attached on this path.** A container that failed
  to describe its own bitstream has not earned trust in its DoVi signalling
  either, and the base layer still presents as HDR10 off the colour tags, which
  is already the documented ceiling for the dual-layer profiles.
- A remux does **not** repair such a file: `ffmpeg -c copy` carries the empty
  record straight over. Rebuilding it needs the video pushed through annex-B.
- **The same refusal has a second cause**, from the opposite direction: a
  container whose record is not a configuration record at all. See *Disc
  images* below, where MPEG-TS hands over Annex-B in the field an `hvcC`
  arrives in.

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

#### A seek that lands in an open GOP

An H.264 High 1080p mkv direct-played for minutes and then fell to a transcode
on the first **seek** — a scrub, an embedded subtitle switch (which re-seeks to
the same position), or simply opening the title at a resume point.

`avformat_seek_file` lands on a Matroska block flagged `AV_PKT_FLAG_KEY`
carrying its own SPS and PPS, a recovery-point SEI, and slices of NAL type
**1**, a coded slice of a *non-IDR* picture. That is an **open GOP**, and the
flag means only that the muxer is willing to seek there. Nothing is missing and
that picture decodes; what fails is one of the two *leading pictures* that
follow the seek point in decode order and are presented before it. They
reference the GOP the renderer's `flush()` has just destroyed. libavcodec
tolerates that and lets a few frames come out wrong; VideoToolbox does not, and
`AVSampleBufferVideoRenderer` answers with `didFailToDecodeNotification`
(-11800 / -12350), which is `.undecodable`, which is the bottom rung — a whole
film re-encoded because two frames nobody was ever going to see could not be
decoded.

So the demuxer drops them. `VideoRandomAccessPoint` (pure, unit-tested)
classifies the first video packet after every seek: an IDR for H.264, the IRAP
range 16–21 for HEVC. When it *is* one — closed-GOP content, which is nearly
everything — nothing changes. When it is a keyframe that is not one, the
following packets presented before it are dropped until decode order passes it,
bounded at 32 packets. Everything dropped sits before the point the seek landed
on, at or before the position the viewer asked for, so none of it was ever
going to be shown; on the file above that is two packets per seek
(`SeekLeadingPictures dropped=2` under `-debug.decodeTrace YES`).

The ladder also got tolerant of this shape of failure, because the next
container to invent one should cost a hiccup rather than a film.
`PlaybackRestartPointPolicy`: a decode failure within the first three video
samples after a flush earns **one** in-place recovery — flush, re-seek to the
same position through the ordinary seek path — before `.undecodable` is
reported. The retry is recorded against the playback generation the re-seek
starts, so a second failure at the same position descends the ladder exactly as
before, one seek later, and a later seek earns its own retry. It cannot loop.

Worth knowing when this comes back: only the compressed path reaches
`AVSampleBufferVideoRenderer`, so a software-decoded stream never showed this,
and neither does any HLS rung — Jellyfin's fMP4 segments start on IDRs, which
is why the transcode the ladder fell to always played. It is decoder-dependent
too: the A15 played the same seek clean before the fix and only the simulator
refused the leading pictures, so the drop is what keeps the simulator lane
honest on open-GOP encodes.

#### A decode session the system took back

Three TestFlight reports on builds 99–100, on both an Apple TV and an iPhone,
descended to transcode on a VideoToolbox status that was never about the
bitstream. `-12903` is `kVTInvalidSessionErr`: the decode *session* is gone and
needs remaking. `failVideoDecode` flattened every decoder error to
`.undecodable`, on the reasonable-sounding assumption that redelivering the
same bitstream cannot help — true of a frame the decoder refused, false of a
session that no longer exists.

The renderer path had been hardened for exactly this twice, and the decoder
path neither time. `recoverVideoRendererIfRequired` and
`handleVideoRendererFailure` both bail while `videoOutputSuspended`;
`failVideoDecode` had no such check. The in-place retry above had exactly
one caller, the renderer failure path, so direct-play HEVC and AV1 — which run
through `VideoToolboxDecoder` and never reach a renderer failure — had no retry
at all and were terminal on the first fault. `VideoToolboxDecoder.reset()`
already recreated a session and was called only from the seek branch, never
from an error path.

The two reported shapes need different halves of the fix:

- `LAGOON-G`, an iPhone, `appState: background`, DoVi direct play, 39 s in.
  Background playback deliberately leaves the VT session alive, because
  making a new one in the background can be refused. But
  `setVideoOutputSuspended(true)` only sets a flag on the main actor: the demux
  loop applies the discard at the top of its *next* iteration, and
  `deliverVideo`/`admitVideo`/`drainVideoIntake` gate only on `cancelled`, so a
  sample in flight can still reach a session iOS has already torn down. The
  fallback then tried to reload a film into the foreground of an app that was
  not in the foreground — `outcome: cancelled`, as it had to be. **This race is
  reasoned from the code, not reproduced.** The misclassification it exposes is
  plain from the funnel regardless of how the session was lost.
- `LAGOON-A`, an Apple TV, `appState: **active**`, `sinceSeekMs: 178`,
  reported as `sessionCreation`. Not the background race at all: the seek
  branch's own `videoDecoder?.reset()` failed to build a session, on a stream
  that had been playing.

So `VideoToolboxDecoder.isSessionFault` names the three statuses that mean the
decoder was taken away rather than the samples refused: `kVTInvalidSessionErr`,
`kVTVideoDecoderMalfunctionErr`, `kVTVideoDecoderNotAvailableNowErr`.
`PlaybackDecodeSessionPolicy` decides what to do, bounded exactly as
`PlaybackRestartPointPolicy` is and for the same reason: one rebuild per
playback generation, recorded against the generation the re-seek starts. A
session that genuinely cannot be made descends the ladder one seek later and
cannot loop. Suspended video ignores the fault outright — there is nothing to
rebuild for, and the resume seek makes a fresh session anyway.

**A rebuild is a seek, and a seek needs a demux loop still running to apply
it.** That is the whole trap in this fix, and it is worth stating before the
call sites, because absorbing a fault on a path that is about to stop the loop
does not save the playback — it replaces a reported failure with a spinner that
never resolves and never errors, which is strictly worse than the transcode the
bug caused. So absorption is opt-out, `allowSessionRecovery: false`, wherever
the caller is about to stop the loop or has never started one:

- **Decoder construction at open** (before the loop is entered, and it
  `return`s instead of entering it). A decoder the system will not hand out at
  open is what the transcode rung is for.
- **The seek branch**, where returning false `break`s the loop. It retries
  `reset()` in place instead and only descends if the second attempt fails too.
- **Cancelled playback**, via the policy's `tooLate`: the samples draining out
  of a decoder being torn down all report the session going with it.

`finishVideoInput` is the one absorbing path that keeps going: at EOF a dead
session costs the last frames it was holding, and both descending the ladder
and seeking to rebuild would be worse than losing them, so it records and falls
through to the finish boundary.

`alreadyRecovering` is deliberately not recorded. A decoder can hold dozens of
samples and each reports the same dead session on its way out; a breadcrumb
apiece would evict the history that explains the incident. The rebuild they are
all waiting on is recorded, on the main actor, once it is known which of the
two outcomes it was. The near-the-end branch that declines to seek spends the
generation's rebuild anyway. Otherwise every remaining sample would ask for
another one.

Both outcomes report on the renderer-recovery channel they mirror, as
`recovery: decodeSessionRebuilt` and `decodeSessionIgnored`; only the rebuild
is reported as an incident, because the ignored ones are expected and would be
noise. The `rendererRecoveries` counter is built from engine counters, not from
these events, so the degradation thresholds are unaffected.

Still owed: a hardware run. Nothing here has been seen to recover on a device —
the classification is verified by unit tests and the builds are green, but
"a rebuilt session actually resumes playback on an Apple TV" is a device check,
and the background race above wants a reproduction before anyone trusts the
account of it. `LAGOON-B` (`-12909`, bad data, one access unit mid-film) is a
different mechanism — per-frame tolerance with a budget — and is deliberately
left alone here.

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

**An image is read here.** `UDFVolume` resolves a name to its extents and
`DiscStreamMap` presents a title's extents to the demuxer as one linear stream,
through the byte-range AVIO the playback cache already provided; mounting a
Blu-ray costs about 15 range requests and under a megabyte. Because the reader
lives behind the cache session, a disc keeps its session even once the image
is completely cached: an ordinary complete file plays straight from disk
without one, but a disc handed to libavformat as a plain file is the raw
image again and fell to the server remux (`PlaybackBufferPolicy
.engineUsesCacheSession`). Four things about that were not obvious:

- **UDF 2.50 hides every file entry inside a metadata partition** — a file in
  the physical partition that the volume then addresses as a partition of its
  own — while the data those entries describe stays outside it. A reader that
  resolves every allocation descriptor in the entry's own partition finds empty
  directories, which is exactly what the first draft did.
- **A DVD image needs no second filesystem.** It is UDF 1.02, the same reader
  minus the metadata partition, and it mounted an authored image unchanged. No
  ISO9660 reader was written.
- **The longest playlist is usually a menu loop.** WALL·E's `00020.mpls` plays
  two clips 303 times and reports 323 minutes, more film than the image
  physically holds; counting each clip once collapses it to 2 minutes. Four real
  candidates then sit within half a minute of each other, and the only thing
  separating them is the runtime the server already probed — a signal only a
  client talking to a media server has. Ties break by name so the choice cannot
  wobble between mounts.
- **A title is not one file.** Seamless branching splits WALL·E's into 42 clips
  and the filesystem fragments some of those again, 71 extents in all. A DVD
  title is its largest title set's VOBs in numeric order, part 0 excluded
  because that is the menu.

The concatenated title's duration agrees with Jellyfin's probed runtime to
within a third of a second, so the presentation timeline stays continuous across
every clip boundary.

#### What MPEG-TS breaks that no probe reports

ffprobe, Jellyfin and libavcodec handle both of the following without comment;
only Apple's decoder and Lagoon's own timeline cared.

**MPEG-TS is Annex-B; every other container Lagoon plays is length-prefixed.** A
correctly mounted disc failed at `VTDecompressionSessionCreate` with "could not
create a hardware decoder". libavformat synthesises `extradata` for MPEG-TS out
of the in-band parameter sets and hands it over still in Annex-B; read as an
`hvcC` it describes a stream that does not exist, and the samples carry start
codes as well, which VideoToolbox cannot decode whatever the description says.
Confirmed against Apple's decoder with the disc's own record: read as an `hvcC`
the session is refused with -4, built from the parameter sets read out of it it
is created at 3840x2160. `AnnexBStream` reads those parameter sets out of a
start-code record and rewrites every payload with four-byte lengths, for H.264
as well as HEVC; the enhancement-layer filter runs after that conversion so it
and VideoToolbox see one framing. This is the same failure reached from the
other side: a description that builds successfully and a decoder that refuses it.

**A container's clock is not the film's clock.** The same disc then played but
opened reading 1:10:00 with a scrubber that would not move. MPEG-TS starts at
whatever timestamp the muxer chose, and this disc's streams begin at
4198.333333 s (377850000 at 90 kHz). Every packet carried that origin into the
renderers, and every seek asked for a timestamp 70 minutes before the first
frame, which the demuxer clamped to the start. `ContainerTimeline` now removes
the format's origin from packets as they are read and adds it back onto seeks.
Measured origins, which is why this had never come up:

| path | origin |
| --- | --- |
| MKV direct play | 0 |
| Jellyfin HLS transcode | -0.042667 s (encoder delay, negative, ignored) |
| Jellyfin HLS remux | +0.005 s |
| DVD image | +0.54 s |
| Blu-ray image | +4198.33 s |

Taking the *format's* origin rather than each stream's own is deliberate: this
disc starts its video and first audio track together and a second audio track
two thirds of a second later, and that offset is content, not clock.

Neither disc path covers Dolby Vision profile 7: `DolbyVisionProfileConverter`
keys off a DoVi configuration record that MPEG-TS images do not carry, so
such a disc plays as HDR10 from the base layer. H.264 Blu-rays
(everything before 4K) and real DVD images are unexercised — the DVD path was
built against an image authored with `dvdauthor` for the purpose, because the
fixture server holds none.
