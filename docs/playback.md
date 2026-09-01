# Playback

**One engine for everything** (Jaagop's call, 2026-08-16, HEL-48): all
playback runs through the Lagoon sample-buffer engine. The AVPlayer and mpv
players were removed the same day the decision was made — no split paths,
no per-container routing. Since 2026-08-17 (M6) the FFmpeg libraries come
from the local `Packages/LagoonFFmpeg` package, which pins the four
Libav* static xcframeworks from MPVKit's 1.0.0 release (FFmpeg 8.1.2)
plus the static libs FFmpeg's build references (gnutls/nettle/hogweed/gmp
for TLS, dav1d, uavs3d, lcms2) — MPVKit itself, libmpv, MoltenVK, and
libplacebo are no longer in the project. The archives are static: the app
binary links only referenced objects, and the bundle embeds 11 framework
shells instead of 27.

## Stream resolution

`PlaybackController.start` runs the standard Jellyfin negotiation:

1. `POST Items/{id}/PlaybackInfo?UserId=` with `DeviceProfile.lagoon` — a
   capability profile mirroring exactly what the engine can play: h264/hevc,
   capability-routed AV1, and progressive VP9 plus SDR 8-bit VC-1, MPEG-4
   Part 2, and MPEG-2 up to 1080p,
   square or anamorphic, with
   aac/mp3/ac3/eac3 (passthrough) plus dts/truehd/flac/opus/
   vorbis/PCM (libavcodec-decoded, M4) audio in mkv/webm/mp4/m4v/mov/avi,
   embedded text/PGS/VobSub/DVB subtitles and external vtt (M5), plus an fMP4
   HLS transcoding
   profile whose output (hevc/h264 + eac3,ac3,aac) lands back inside the
   same envelope. The server does the deciding.
2. Pick the first `MediaSource` and resolve a URL via
   `JellyfinClient.streamURL`:
   - `SupportsDirectPlay` → `Videos/{id}/stream?static=true&mediaSourceId=…`
     (+ `api_key`, `deviceId`, `Tag`), PlayMethod `DirectPlay`.
   - else `SupportsDirectStream` → `Videos/{id}/stream.{container}` with the
     same static query, PlayMethod `DirectStream` (server-must-proxy case;
     container can arrive as an ffprobe list — take the first entry).
   - else the server-provided `TranscodingUrl` (server-relative with its own
     query string — resolve against the server URL, don't rebuild it),
     PlayMethod `Transcode`. libavformat's HLS demuxer reads the fMP4
     playlist; the video-copy variant is listed first in the master.
3. The engine plays it. Jellyfin's HLS playlists cover the full duration,
   so resume is handled the same way as direct play: an initial demuxer
   seek, keeping position reporting absolute in every play method.

### What this device is offered (HEL-102)

`DeviceProfile.everything` is the envelope the engine can play;
`DeviceProfile.lagoon` is that envelope minus whatever the running hardware
cannot decode, and it is what gets sent. The subtraction is deliberately a
short transform over the literal rather than a second literal, so the envelope
stays the single statement of what the engine supports.

Two hardware capabilities are consulted, and the reasons are specific:
`VideoToolboxDecoder` creates its session with
`kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`, so
without a hardware decoder HEVC does not degrade — it fails outright with
-12906. AV1 uses that same compressed VideoToolbox path when hardware support
is present, but unlike HEVC it has a bounded libdav1d software path when it is
not. Everything else in the envelope survives a missing hardware decoder:
H.264 reaches `AVSampleBufferVideoRenderer` compressed and may be decoded in
software, while VP9 and the legacy codecs are libavcodec on the CPU.

**Do not gate more on `VTIsHardwareDecodeSupported` than those routing
decisions.** It reports
hardware alone: on the tvOS simulator it answers false for *every* codec,
including the H.264 the simulator plainly plays. Gating wholesale would strip
the profile to nothing.

Removing HEVC touches three places, and missing any one of them undoes the
other two:

- the direct-play codec list, the obvious one;
- the `hevc` codec profile, or the server sees conditions for a codec it is
  not being offered;
- the **transcoding** profile, which is the one that bites. Left listing
  `hevc,h264` it lets the server answer a fallback request with an HEVC
  rendition — the exact format the device just said it cannot decode. That is
  how a simulator run of the delivery ladder failed every rung with -12906.

H.264 is also capped at 1080p in the reduced profile. Without it the
subtraction makes things worse rather than better: a 4K HEVC film stops direct
playing and the server is asked for H.264 *at 4K*, an enormous transcode for a
device with no chance of decoding it — observed doing exactly that, the player
sitting at 0 s with empty queues. Hardware that cannot decode HEVC will not
manage 4K H.264 either. It is a heuristic, not a measurement: VideoToolbox
answers per codec and never per resolution.

Verified against Jellyfin 10.11 with a 4K HEVC/DoVi source: the full profile
direct-plays it, the reduced profile refuses direct play and returns
`VideoCodec=h264 MaxWidth=1920 MaxHeight=1080`, and an H.264 source
direct-plays under both.

On the hardware Lagoon targets (tvOS 26 / iOS 26) HEVC decoders are expected
everywhere, so this is defensive rather than load-bearing today; where it
already shows is the simulator, which now negotiates H.264 on its own. Its
real payoff is AV1: A17/M3-class devices can take the compressed hardware path,
while older devices remain inside the same honest direct-play envelope through
the software fallback.

### What a metered path is offered (HEL-108)

`DeviceProfile` advertised 120 Mbps on every device and every network path,
so an 89 Mbps remux was offered as **direct play over cellular** — unwatchable
and expensive at once. The playback cache already drew this distinction one
layer down (proactive range fills set `allowsExpensiveNetworkAccess` and
`allowsConstrainedNetworkAccess` false); the profile simply never asked.

`NetworkPathObserver` watches `NWPathMonitor` and `cappedForMeteredPath`
bounds the profile when the path is expensive (cellular, personal hotspot) or
constrained (Low Data Mode). Verified against 10.11 with an 89.1 Mbps 4K
source: unmetered direct-plays, metered returns
`MaxWidth=1280 MaxHeight=720 VideoBitrate=2552000` with direct play refused.

Four things are deliberate:

- **iOS only.** An Apple TV is a wired or strong-Wi-Fi appliance that Apple
  has no reason to call expensive, so applying it there would be dead code
  that could only ever surprise. Widening it is a one-line change if a tvOS
  device on a hotspot ever turns out to matter.
- **`maxStaticBitrate` comes down with `maxStreamingBitrate`.** The static
  ceiling is the one the server checks before offering the original file, so
  capping only the streaming figure would let the remux direct-play anyway.
- **A resolution ceiling rides along**, which the ticket did not ask for and
  measurement argued for: capping bitrate alone leaves `MaxWidth` absent, so
  the server answers a 4K source with a 4K re-encode at 3 Mbps — a picture
  nobody wants, minutes of server CPU to make it, on a phone that cannot show
  it. 720p is the conventional cellular rendition and makes the encode cheap.
- **The viewer can override it** (Settings → Cellular → Full Quality on
  Cellular). Apple reports that a path is *expensive*, never that it is
  *slow*, and a fast tethered 5G connection is indistinguishable from a
  throttled hotspot from inside the app.

Two known limits, both deliberate. The profile is built once per
`PlaybackInfo` call, so a path changing mid-title does not re-negotiate —
the alternative is tearing down a working stream because a phone moved
between access points. And until `NWPathMonitor` has reported, the observer
answers "unrestricted", so a first negotiation on a cold launch over cellular
can miss the cap once; that errs toward the behaviour that existed before.

`boundedTo(_:width:height:)` resolves two geometry bounds by **tightening**
rather than by skipping, because there are now two transforms that ask for one
and they no longer ask for the same number: the fallback bounds are 1080p and
the metered cap is 720p. Whichever applies second, the smaller ceiling
survives.

### When the container describes no bitstream (HEL-131)

Matroska and MP4 are supposed to carry HEVC's VPS/SPS/PPS in the
`CodecPrivate`/`hvcC` record, and `SampleBufferFactory.videoFormatDescription`
builds the format description from it. hev1-style muxing is legal and does
not: it leaves `numOfArrays = 0` and repeats the parameter sets in-band
instead. Found on a 4K WEBDL whose entire `hvcC` was 23 bytes of header.

Nothing complains at the time. `CMVideoFormatDescriptionCreate` builds a
description around the empty record and returns `noErr`; the refusal arrives
later, from `VTDecompressionSessionCreate`, as -4. Verified against Apple's
decoder with Lagoon's own construction:

| built from | description | session |
| --- | --- | --- |
| container `hvcC`, `numOfArrays = 0` | `noErr` | **-4** |
| the bitstream's own VPS/SPS/PPS | `noErr`, 3840x2160 | `noErr` |

So it reads as a hardware fault and is a container one, which is exactly how
it was first misread. Every other tool disagrees for the same reason: ffprobe,
Jellyfin's probe and libavcodec all parse parameter sets in-band, so the file
looks healthy everywhere except the one place the client trusts the container.

`FFmpegDemuxer` therefore checks the record before building anything
(`SampleBufferFactory.hevcExtradataCarriesParameterSets`) and, when it
describes nothing, harvests VPS/SPS/PPS from the opening NALs of the first
video packet and builds through
`CMVideoFormatDescriptionCreateFromHEVCParameterSets`. Notes worth keeping:

- **The header stays valid even with no arrays behind it**, so
  `lengthSizeMinusOne` still describes the packets correctly and the harvest
  can walk them. On the file this was found with, the first video packet is
  AUD, VPS, SPS, PPS, SEI, then the IDR slices, so the read-ahead ends on
  packet one; it is bounded at 64 regardless.
- **The context is rewound afterwards.** `open()` runs before the demux loop,
  which still owes the renderers every packet from the beginning. A failed
  rewind costs the opening packets and is deliberately not fatal, because that
  is worth less than the decoder the harvest buys.
- **Dolby Vision atoms are not attached on this path.** A container that
  failed to describe its own bitstream has not earned trust in its DoVi
  signalling either, and the base layer still presents as HDR10 off the colour
  tags, which is already the documented ceiling for the dual-layer profiles.
- A remux does **not** repair such a file: `ffmpeg -c copy` carries the empty
  record straight over. Rebuilding it needs the video pushed through annex-B
  and re-muxed.
- **The same refusal has a second cause**, found later and from the opposite
  direction: a container whose record is not a configuration record at all.
  See *Disc images* below, where MPEG-TS hands over Annex-B in the field an
  `hvcC` arrives in.

### When playback fails: the delivery ladder (HEL-100)

Negotiation happens once, before the first frame, so a direct play that the
engine cannot actually handle used to end the film: the error overlay's only
control is **Back**. The controller now re-negotiates instead, descending one
rung at a time and resuming at the position the failure interrupted. The
viewer sees the player reload, not an error.

| rung | PlaybackInfo flags | what the server does |
| --- | --- | --- |
| `negotiated` | all four true (Jellyfin's own defaults) | direct play — the original file, no server work |
| `remux` | `EnableDirectPlay=false` | HLS fMP4, video **stream-copied**: a container rewrite, no encoder |
| `transcode` | also `EnableDirectStream=false`, `AllowVideoStreamCopy=false` | HLS fMP4, video re-encoded |

**The middle rung is not `SupportsDirectStream`.** Jellyfin couples the two:
withdrawing direct play returns both flags false and hands back a
`TranscodingUrl` regardless. Verified against 10.11 — the remux and transcode
rungs return URLs differing by exactly one parameter, `allowVideoStreamCopy=false`.
That single flag is the whole distinction between a remux and a transcode, and
it is why the two rungs are worth keeping apart: a remux costs the server a
container rewrite, a transcode costs it minutes of CPU per viewer.

Which rung comes next depends on whether redelivering the same samples could
possibly help, which is what `PlaybackEngineFailure.Cause` records:

- `.delivery` — the container, the transport, or an AVFoundation object
  failed. A server-side rewrite routinely fixes these, so the next rung is
  the cheap one.
- `.undecodable` — a codec outside the envelope, a VideoToolbox session the
  hardware declined, a decode that failed. A stream copy hands the decoder the
  same bitstream, so the remux rung is **skipped**: straight to the re-encode.

Both lower rungs arrive as HLS, which costs the embedded subtitle track (the
engine cannot demux subtitles out of a Jellyfin transcode). That is a further
reason the ladder is only ever descended after a real failure, never
pre-emptively.

**The bottom rung is bounded to HD, and only the bottom rung**
(`DeviceProfile.lagoon(for:)` → `boundedForRealtimeTranscode`). Left alone it
inherited the direct-play envelope and asked the server to re-encode at the
source's own shape: measured against fixture, `VideoBitrate=119360000` with no
`MaxWidth`/`MaxHeight` at all, i.e. 4K HEVC at 120 Mbps. That is a figure that
only ever meant "the bitrate of an untouched file this device will pull", and
it is meaningless as an instruction to an encoder. A server without a hardware
encoder answers it at **9.5 fps for a 30 fps source** — the rung meant to
rescue playback stalls worse than the failure that triggered it. The bound
sends `MaxWidth=1920 MaxHeight=1080` and a 20 Mbps ceiling instead (verified
against 10.11: same request, `VideoBitrate=19360000`).

It deliberately does **not** apply to `remux`. That rung stream-copies the
video, and a resolution condition there would force exactly the re-encode it
exists to avoid — the negotiated and remux rungs still send the full envelope,
so 4K direct play is untouched.

The retry reuses the episode-handoff teardown (`preservingPlayerSurface: true`)
rather than a full one: the viewer keeps the last frame instead of a black
screen while the next rung negotiates, and it is the path autoplay has hardened.
It also sidestepped the retirement timeout that made every early fallback fail
— though **not for the reason first recorded here**. That was blamed on
`removeRenderer`'s completion going missing once SwiftUI destroyed the layer,
which a later trace disproved: a healthy engine dismissed with the surface torn
down detaches perfectly (`renderers-detached` fires, counters reach zero). The
real cause was the revival bug below (HEL-110), now fixed.

Bounds worth knowing: the ladder belongs to one item and resets for the next;
`next` only ever moves downward, so a stream that fails every way still ends in
the overlay rather than a restart loop; and a failure arriving while the next
attempt is *still starting* takes the terminal path rather than tearing down an
engine mid-flight — today's behaviour for a rare race, never worse than it.

`debug.regressionFailFirstDelivery` (`delivery` or `undecodable`) fails the
first negotiated attempt on purpose, since this path only ever runs when
something is already broken. Verified on the simulator against fixture: direct
play at 0:02 → injected failure at 2.1 s → remux rung playing at 0:23, queues
full, zero stalls.

**A fallback that succeeds used to erase its own explanation.**
`failure.message` carries the detail that is the whole reason the ladder ran —
the VideoToolbox status, the renderer error — but it only reaches
`errorMessage` when the ladder runs *out* of rungs. A descent that then plays
left a signpost as the only trace, which needs Instruments and therefore a
paired device; an Apple TV that cannot be paired (HDCP 2.2) could not be asked
what went wrong. The playback HUD now carries it (`Rung:` / `Fell n:` /
`Why n:`), appearing only once a rung has actually been descended.

### Disc images (HEL-133)

A disc image is a filesystem, not a stream, and Jellyfin describes one
accurately and then contradicts itself: `VideoType` says `Iso`, `Container`
reports the format probed *inside* the disc (`ts` for a Blu-ray), and
`SupportsDirectPlay` still comes back true. Take the last at face value and
the static stream delivers the image itself, which libavformat cannot open —
stock `ffprobe` fails on the same URL with `Invalid data found when
processing input`. `MediaSource` therefore decodes `VideoType`/`IsoType`, and
`PlaybackSourceLayout` turns them into what the ladder needs: a file, a
Blu-ray image, a DVD image, an image the server did not type, or a folder
rip.

**A folder rip cannot be read by any client.** Jellyfin's `Video.cs` returns
the *folder* for a disc, and `MediaSourceInfo` exposes no property naming the
files inside one — Emby's `PlayableStreamFileNames` is gone. A rip's honest
outcome is therefore the server remux, chosen deliberately rather than
discovered through a failed open. Infuse handles rips because it is usually
reading SMB/NFS rather than Jellyfin.

**An image is read here.** `UDFVolume` resolves a name to its extents and
`DiscStreamMap` presents a title's extents to the demuxer as one linear
stream, through the byte-range AVIO the playback cache already provided.
Mounting WALL·E costs 15 range requests and 960 KiB, in 0.17 s.

Four things about that were not obvious:

- **UDF 2.50 hides every file entry inside a metadata partition** — a file in
  the physical partition that the volume then addresses as a partition of its
  own — while the data those entries describe stays outside it. A reader that
  resolves every allocation descriptor in the entry's own partition finds
  empty directories, which is exactly what the first draft did.
- **A DVD image needs no second filesystem.** It is UDF 1.02, which is the
  same reader minus the metadata partition, and it mounted an authored image
  unchanged. No ISO9660 reader was written.
- **The longest playlist is usually a menu loop.** WALL·E's `00020.mpls`
  plays two clips 303 times and reports 323 minutes, more film than the image
  physically holds; counting each clip once collapses it to 2 minutes. Four
  real candidates then sit between 98.2 and 98.7 minutes, and the only thing
  separating them is the runtime the server already probed (98.11) — a signal
  only a client talking to a media server has. Ties break by name so the
  choice cannot wobble between mounts.
- **A title is not one file.** Seamless branching splits WALL·E's into 42
  clips and the filesystem fragments some of those again: 71 extents,
  44.53 GB. A DVD title is its largest title set's VOBs in numeric order,
  part 0 excluded because that is the menu.

The concatenated title's duration agrees with Jellyfin's probed runtime to
within a third of a second, so the presentation timeline stays continuous
across every clip boundary.

#### Two failures that cost a build each

Both looked like something they were not, and neither is visible to any tool
that probes the disc: ffprobe, Jellyfin and libavcodec all handle both
without comment. Only Apple's decoder and Lagoon's own timeline cared.

**MPEG-TS is Annex-B; every other container Lagoon plays is
length-prefixed.** 0.1 (69) mounted the disc correctly and then failed at
`VTDecompressionSessionCreate` with "could not create a hardware decoder".
libavformat synthesises `extradata` for MPEG-TS out of the in-band parameter
sets and hands it over still in Annex-B; read as an `hvcC` it describes a
stream that does not exist. The samples carry start codes as well, which
VideoToolbox cannot decode whatever the description says. Verified against
Apple's decoder with the disc's own 118 bytes:

| built from | session |
| --- | --- |
| the record, read as `hvcC` | refused, -4 |
| the parameter sets read out of it | created, 3840x2160 |

`AnnexBStream` reads the parameter sets out of a start-code record and
rewrites every payload with four-byte lengths, for H.264 as well as HEVC; the
enhancement-layer filter runs after that conversion so it and VideoToolbox
see one framing. This is HEL-131's failure reached from the other side: a
description that builds successfully and a decoder that refuses it.

**A container's clock is not the film's clock.** 0.1 (70) played but opened
reading 1:10:00 with a scrubber that would not move. MPEG-TS starts at
whatever timestamp the muxer chose, and this disc's streams begin at
4198.333333 s, which is 377850000 at 90 kHz. Every packet carried that origin
into the renderers, and every seek asked for a timestamp 70 minutes before
the first frame, which the demuxer clamped to the start. `ContainerTimeline`
now removes the format's origin from packets as they are read and adds it
back onto seeks. Measured origins, which is why this had never come up:

| path | origin |
| --- | --- |
| MKV direct play | 0 |
| Jellyfin HLS transcode | -0.042667 s (encoder delay, negative, ignored) |
| Jellyfin HLS remux | +0.005 s |
| DVD image | +0.54 s |
| Blu-ray image | +4198.33 s |

Taking the *format's* origin rather than each stream's own is deliberate:
this disc starts its video and first audio track together and a second audio
track two thirds of a second later, and that offset is content, not clock.

#### Untested

Dolby Vision profile 7 discs, where the enhancement-layer filter keys off a
DoVi record that may not survive MPEG-TS; H.264 Blu-rays, meaning everything
before 4K; and any real DVD image, since the DVD path is verified against a
disc authored with `dvdauthor` for the purpose and fixture holds none.

## The engine (`Lagoon/Views/Player/SampleBuffer/`)

libavformat demux → codec-specific stages → `AVSampleBufferDisplayLayer` +
`AVSampleBufferAudioRenderer` under one `AVSampleBufferRenderSynchronizer`.
This is the app's only player. H.264 and supported audio codecs stay
compressed; HEVC and hardware-supported AV1 are decoded ahead by a
hardware-only VideoToolbox session; AV1 without that capability, VP9, VC-1,
MPEG-4 Part 2, and MPEG-2 are software-decoded by libavcodec into
renderer-recommended NV12/P010 Core Video buffers, on a decode queue of their
own (see below);
unsupported compressed audio is decoded to LPCM by libavcodec. AVFoundation
still owns color management, presentation, synchronization, and audio output.

### Software decode runs off the demux queue (HEL-137)

Until 0.1 (73), `FFmpegDemuxer.readNext()` called
`softwareVideoDecoder.decode(packet:)` inline, and `readNext` runs on the
engine's demux queue. Every frame decoded was time the loop was not reading:
reading and decoding took turns, both queues drained while a frame was inside
libavcodec, and the loop only resumed reading once the frame was out.

It never mattered before. Every path with real per-frame decode cost went to
VideoToolbox, which is asynchronous. The software path's previous customers
were SD and HD MPEG-2, VC-1 and MPEG-4, cheap enough that serialising them cost
nothing visible. 4K AV1 is the first content expensive enough for the
serialisation itself to be the problem, and it arrived in 0.1 (72).

The decoder now lives in `SoftwareVideoDecodeStage`, on a queue of its own,
shaped like `VideoToolboxDecoder`: the demux loop submits and moves on, frames
arrive through an output handler, failures through an error handler. The
demuxer still *builds* the decoder, because that is where the codec parameters
are, and hands it over during open (`takeSoftwareVideoDecoder()`); it never
decodes video again. Three things follow from that and each is load-bearing:

- **Packets are detached, not copied.** `av_packet_clone` shares FFmpeg's
  reference-counted buffer, so handing a 4K access unit to another thread is an
  atomic increment. The demuxer's own packet is unref'd on the way out of
  `readNext` as it always was.
- **Backpressure counts both halves.** `DemuxBackpressurePolicy` is given
  `videoQueue.count + stage.pendingCount`: decoded frames and packets the stage
  still owes are both video already read and not yet shown. Counting only the
  first lets the loop read an entire decoder backlog ahead of itself the moment
  decode stops happening on its queue. `SampleBufferQueue.waitUntilBelow` takes
  an `alsoCounting` closure for the same reason, and the stage calls
  `signalWaiters()` when a packet leaves it.
- **Priming waits for frames, not for packets.** "Read enough" and "decoded
  enough" used to be the same moment and no longer are, so `primeAndStart`
  waits on `stage.waitUntilPendingBelow` rather than starting playback on an
  empty renderer.

Seeks go through `stage.reset()`, which bumps a generation, empties the
mailbox, and flushes libavcodec synchronously, so the demux loop can reset the
render queues behind it without racing a frame still in flight. EOF goes
through `stage.finish()`, because frame threading always leaves pictures inside
libavcodec and they are the end of the film. `FFmpegDemuxer` no longer flushes
or drains the software decoder at all; doing both would touch libavcodec from
two queues at once.

**Frames from the stage do not go through `acceptDecodedVideo`.** That gate
drops anything arriving while a seek is merely *pending*, which is right for
VideoToolbox and wrong here: the stage discards its own pre-seek work when the
demux loop resets it, and `videoQueue.reset()` clears whatever landed in
between, so both ends are already covered. Dropping there starves the renderer
exactly while stall recovery is re-priming, and re-priming *is* a seek every
couple of seconds, so the drop keeps the queue empty, which keeps the stall
going. Caught as 4 displayed frames against 2133 on the same title, position
and stall loop.

#### Where the time goes

The HUD's `SWdec:` line and the bench's `swdecode=` field separate the three
costs, cumulative since the last seek, which is also where the frame-loss bench
re-arms, so a bench window and the profile describe the same stretch:

```
SWdec:   38.4 ms/frame · budget 92% · 21.7 fps now (23.9 avg) · conv 0.8 ms · read 0% · pending 3
```

**Read `ms/frame` and `budget`, not the rate.** Once the queues fill,
backpressure holds the decoder at playback rate, so a decoder with headroom to
spare and one with none both settle at the frame rate of the content — the
rate is a property of the content, not of the device. Cost per frame does not
move when the decoder is throttled, and `budget` expresses it as a fraction of
one frame period (41.7 ms at 23.976 fps), so anything at or above 100% cannot
hold frame rate however healthy the queues look. Two builds of this ticket
were read wrongly before the line said this.

`fps now` is a two-second rolling window and `avg` is since the last seek. The
average has memory: a fast start while priming drags it up for minutes, so a
declining average is not by itself evidence of anything. `read` is still a
share of one core, on the demux queue. `decode` is libavcodec
(threaded, so on dav1d this is the wait, not the work). `convert` is everything
between a decoded AVFrame and a ready `CMSampleBuffer`: the Core Video
allocation, the 10-bit shift, the chroma interleave, the attachments. `read` is
`av_read_frame`, which is the cache or the network.

The conversion figure decided HEL-137's levers 3 and 4: measured at 2% on an
Apple TV, both are dead. For the record, what it would have meant otherwise: AV1 decodes
to `YUV420P10LE` and the renderer wants P010, so every frame is shifted from low
bits to high and its chroma interleaved: roughly 25 MB read and 25 MB written
per 4K frame, about 600 MB/s at 24 fps. If that share is large on the device,
the shift is a candidate for the GPU, or for driving dav1d's own picture
allocator directly (it is already linked in `Packages/LagoonFFmpeg`) to decode
into IOSurface-backed buffers.

**No number here has been measured on an Apple TV yet.** Per the bench rule
below, nothing else counts: same scene, same media-time window, three or more
runs, HUD off for the verdict.

#### Lagoon builds dav1d itself, because upstream's had no assembly

The pipeline change above was necessary and was not the fix. On an Apple TV
the split read: **decode 96-98%, convert 2%, read 0%**, at 11.4 fps against
the 23.976 a 4K HDR10+ AV1 episode needs. Conversion and delivery were never
close to being the constraint, which retired levers 3 and 4 of HEL-137
(GPU conversion, decoding into IOSurfaces) without having to try either.

The arithmetic pointed past threading. HEL-103 measured 720 frames in 1.66 s
on a 12-performance-core Mac, and 18.4 ms/frame single-threaded. The device
was taking 88 ms/frame — 4.8x slower than *one thread* on the Mac, which no
core-count or IPC difference explains. Bounding the count to the performance
cluster made it worse (9.1 fps), so it was not under-threading either.

It was the binary. `mpvkit/libdav1d-build`, where the artifact came from,
builds dav1d with:

```
"-Denable_asm=false",   // disable "No platform load command found" warning after xcode 15
```

Every AV1 frame Lagoon had ever decoded ran dav1d's portable C path. The
symbol counts say it plainly, against libavcodec from the same bundle:

| library | NEON symbols |
| --- | --- |
| Libavcodec (mpvkit) | 2402 |
| Libdav1d (mpvkit) | **0** |
| Libdav1d (`scripts/build-dav1d.sh`) | 2016 |

The warning upstream was silencing is real: meson assembles dav1d's `.S`
files with the C compiler, and without an explicit `-target` those objects
carry no platform load command. Passing `-target arm64-apple-tvos26.0` fixes
it properly and keeps the SIMD, which is what the script does. It also
retro-explains HEL-103's Mac number: 18x real time across twelve performance
cores is only 1.5x per core, which is what a C-path dav1d looks like. Twelve
fast cores hid it; two cannot.

`Packages/LagoonFFmpeg/Artifacts/Libdav1d.xcframework` is therefore the one
artifact Lagoon builds rather than fetches, vendored rather than hosted
because a URL that has to outlive the app is a worse dependency than eight
megabytes in the repository. It first shipped as dav1d 1.5.3, matching mpvkit's
version exactly so that nothing about the result could be attributed to a
version change rather than to the assembly.

**It is now 1.5.4**, taken once the assembly change had been measured on its
own. 1.5.4 carries "schedule tile tasks for all passes at once, improving
threading", which is the part of dav1d this ticket is still stuck on, plus
build-time quantization tables; its AArch64 work is 8-bit only and so does
nothing for 10-bit HDR. libavcodec links against it unchanged: same
`DAV1D_API_VERSION` 7.0.0, no public symbol removed, and the only header
difference in the whole upgrade is an OS/2 export macro.

Bumping it is `scripts/build-dav1d.sh --version <tag>` and a rebuild. Check
those three things afterwards, because libavcodec here is a binary compiled
against a particular dav1d and cannot be rebuilt alongside it.

**arm64 carries assembly; x86_64 deliberately does not.** The simulator and
macOS slices have to be fat, because a `generic/platform=tvOS Simulator`
build compiles both architectures and will not link against a slice carrying
one. x86 assembly comes from nasm, which cannot emit a platform load command,
so keeping it would print 46 warnings on every clean simulator link for code
that cannot run on a device and never runs on Apple silicon at all. That is
the same trade upstream made, and it is only defensible scoped to an
architecture that never ships.

**The framework Info.plists declare `MinimumOSVersion` 100.0**, which is not a
mistake and must not be "corrected" to the real deployment target. Xcode builds
a stub dylib per SwiftPM binary target using that value, and App Store
validation requires the app's minimum not to exceed the framework's. Declaring
the app's own minimum sits exactly on that boundary and is rejected:

```
ITMS-90208: Invalid Bundle - The bundle Lagoon.app/Frameworks/Libdav1d.framework
does not support the minimum OS Version specified in the Info.plist.
```

That is what happened to build 74. The value has no runtime meaning, because
the stub never loads: dav1d is a static archive linked into the app binary.
All ten mpvkit artifacts beside it declare the same thing, which is why they
have passed validation for seventy-odd builds, and it is the workaround
several vendors' SDKs use. The deployment targets still apply to the code
itself, through `-target`, which is the part that has to be right.

Re-check the committed artifact at any time:

```sh
scripts/build-dav1d.sh --verify-only Packages/LagoonFFmpeg/Artifacts/Libdav1d.xcframework
```

The build script runs that check itself and fails rather than emit a C-path
binary. **Never remove it.** A dav1d without its assembly decodes every file
correctly and merely slowly, so nothing fails, nothing looks wrong, and
nobody finds out until someone measures 4K on a device with two performance
cores. That is exactly how this shipped in the first place.

#### What was tried and retired

Everything below was measured on the Apple TV and is gone from the code rather
than left switched off, because a settings page full of levers that do nothing
is worse than no levers. The measurements are kept here so nobody re-derives
them.

| lever | result |
| --- | --- |
| Thread count | 5 by default on that device, 6 identical, 8 about 10% better cold and hotter for it |
| dav1d `max_frame_delay` | worse: 42.1 ms a frame against 33.8 ms cold |
| Decode queue at `userInteractive` | never the constraint once heat was |
| Film grain synthesis | **this stream carries none**, reported by the HUD in one playback |
| Apple's AV1 decoder | **does not exist on an A15**: -12906 with the hardware requirement already dropped |
| Playback HUD off | still lags |
| Decoded-frame queue | empty (`V 0`) with 1.2 GB free, so never the memory |

The AV1 one left something behind. `PlaybackCapabilities` used to route on
`VTIsHardwareDecodeSupported`, which reports silicon and nothing else, and went
straight to libdav1d on a false — never asking whether VideoToolbox had a
software decoder, which Apple does ship on some platforms. AV1 is now always
offered to VideoToolbox and `VideoToolboxDecoder.canDecode` settles it per
stream by trying to create a session. Where the answer is no, the engine
reopens on the software path rather than failing the title. That also covers
the hardware case Apple warns about, where a decoder "may not be available at
all times": until this, that would have stranded a title libdav1d could play.

#### Measuring on the device itself

An Apple TV can be paired after all, which changes what is knowable. With
`xcrun devicectl` the loop is build, install, launch with the regression
bootstrap, and read a console time series:

```sh
DEVICECTL_CHILD_LAGOON_REGRESSION_SERVER=... DEVICECTL_CHILD_LAGOON_REGRESSION_USER=... \
xcrun devicectl device process launch --device <udid> --console --terminate-existing \
  ee.helop.lagoon -- -debug.playerRegression YES -debug.regressionBootstrapPublicDemo YES \
  -debug.benchSearchTerm "<title>" -debug.decodeTrace YES
```

The `--` matters: devicectl's parser reads `-debug.x` as bundled short flags
without it. `-debug.decodeTrace YES` prints a `DecodeTrace` line every two
seconds with position, queue depths, footprint and the full decode profile.

Three rules came out of doing this badly first:

**Measure Release.** A Debug build compiles `LagoonPixelOps` at `-O0`, which
reported conversion at 28 ms a frame against Release's 4.8 ms and made decode
look cheap by comparison. Every conclusion drawn from that was wrong.

**Compare at a fixed playback position.** Decode cost on this content tracks
scene complexity: 14 ms a frame at the title, 40 ms in the scene at 40 s. A
cumulative average read at a different position compares scenes, not settings,
which invalidated an entire thread-count sweep and a frame-delay A/B.

**Use `convertMs` as the contamination detector.** It cannot depend on any
decoder setting, so when six back-to-back runs pushed it from 4.8 ms to 9.1 ms
that was the device degrading under continuous load, not the settings. Leave
five minutes between runs and discard any run where it is not near 4.8.

#### It is not thermal, and it is not arrangeable

Relaunching on a device hammered for ten minutes reproduced the cold curve
position for position (28.7 against 28.8 ms at 41.5 s, 34.2 against 34.7 at
45.5 s). Sustained *testing* contaminates, but playback itself does not
throttle its way out of budget.

And the work cannot be rearranged into fitting. Conversion used to run on the
decode queue, so a frame cost decode plus convert; moving it to its own queue
so a frame costs the larger of the two is the same structural fix that opened
this ticket, one stage later. Measured twice, it is *worse*: decode rose by
about what conversion stopped adding, and frames per second went from 22.2 to
21.2. The device is CPU-saturated, so a second thread takes from dav1d exactly
what it saves. **Only doing less work can help, not doing it elsewhere.**

Parallelising the conversion across rows was kept because it does less work in
the same place: 4.8 ms to 4.3 ms. Only that much because the copy is bounded by
memory bandwidth rather than cores.

#### Where this leaves the ticket

Measured on the device, Release, in the demanding scene: decode 39.6 ms,
conversion 4.3 ms, against a 41.7 ms budget. That is about 22 frames a second
where 23.976 are needed — **roughly 8% short**, not the factor of two this
ticket spent days chasing. dav1d is not underperforming; that is in line with
published figures for a 2+4 core A15.

Infuse plays the same file on the same device, direct play, confirmed in the
Jellyfin dashboard. So the headroom exists and Lagoon is spending it somewhere
Infuse is not. The open lead is HDR output: Firecore's own answer is that
"true HDR output is not available for AV1 videos on the Apple TV, so Infuse
will (correctly) set the output to SDR when playing these. Other apps may be
switching your TV to HDR (or Dolby Vision) mode, but this is not technically
correct." Lagoon is one of those other apps.

Measured: forcing SDR changes nothing about the timing, so HDR output is not
where the margin goes. Settings → Advanced → **Force SDR Output** remains,
because the correctness question stands on its own — if Firecore is right, we
are asking a television for a mode this pipeline cannot honestly deliver.

**The remaining lever is the conversion, on the GPU.** It is 4.3 ms of a
41.7 ms budget, or about 10%, and the shortfall is 8%. That is lever 3 of this
ticket, retired earlier on a reading of "2%" that turned out to be a Debug
build's arithmetic. The GPU is otherwise idle during playback, dav1d's planar
10-bit output would upload as textures, and a shader can write P010 into the
IOSurface the renderer already wants. Unlike every other lever tried, it
removes CPU work rather than moving it.

### Player panel performance

The Debug-only Player Panel component preview carries a deterministic 30-track
subtitle fixture. `PlayerRegressionUITests.testPlayerPanelPreviewPerformance`
sweeps Info → Subtitles → Info five times while XCTest records app CPU, retired
instructions, memory, wall-clock time, and animation hitches. It also walks
focus through every stress-fixture row, so lazy construction cannot silently
break Siri Remote navigation. A single six-tab sweep has a 1.75-second hard
ceiling, and the complete sweep plus 30-row walk may grow the app footprint by
at most 12 MB. These deterministic gates sit beside the CPU, memory, hitch,
and timing results Xcode stores with every benchmark run.

On the tvOS 26.5 simulator, the first optimization pass reduced average app
CPU time from 0.368 s to 0.299 s (19%), retired instructions from 3.12 billion
to 2.08 billion (33%), and peak physical memory from 80.0 MB to 72.7 MB (9%).
The 2026-08-19 feature-complete regression rerun (three fresh app processes,
five measured sweeps each) averaged 0.285 s CPU, 2.057 billion instructions,
and about 78 MB peak memory. CPU and instructions remain better than the
original optimized baseline; the roughly 7% footprint increase is stable
between processes and remains below XCTest's 10% regression tolerance.
A final run after the playback fix measured 0.295 s CPU, 2.090 billion
instructions, 1.318 s wall time, and 79.8 MB peak, still within that envelope.
The 2026-08-20 Liquid Glass panel pass measured two fresh processes and ten
tab sweeps before and after narrowing `GlassEffectContainer` from the entire
panel tree to the four sibling tab controls. Average app CPU fell from
0.263 s to 0.243 s (7.7%), retired instructions from 1.685 billion to
1.496 billion (11.2%), and peak physical memory from 64.5 MB to 64.1 MB.
Wall time remained remote-input-bound at 1.314 s versus 1.318 s. Both runs
passed the compact Audio geometry and complete 30-track focus walk.
Run the focused measurement with:

```sh
xcodebuild -project Lagoon.xcodeproj -scheme LagoonHardwareRegression \
  -destination 'platform=tvOS Simulator,name=Apple TV,OS=latest' \
  -only-testing:LagoonUITests/PlayerRegressionUITests/testPlayerPanelPreviewPerformance test
```

The public Jellyfin demo is sufficient for navigation, generic playback,
lifecycle, and panel tests, but currently exposes no subtitle, multi-audio,
chapter, or intro-segment fixture. Rich-media UI tests report an explicit skip
instead of timing out when those assets are absent. To run every fixture-backed
journey against a private regression library without committing credentials:

```sh
TEST_RUNNER_LAGOON_REGRESSION_SERVER='https://example.test' \
TEST_RUNNER_LAGOON_REGRESSION_USER='Regression' \
TEST_RUNNER_LAGOON_REGRESSION_PASS='…' \
xcodebuild test -project Lagoon.xcodeproj -scheme LagoonHardwareRegression \
  -destination 'platform=tvOS Simulator,name=Apple TV,OS=latest'
```

**The `TEST_RUNNER_` prefix is not decoration.** `xcodebuild` does not hand
its own environment to the XCTest runner process; it forwards exactly the
variables prefixed this way, stripping the prefix on the way in. Without it
the runner sees nothing, `launchPlayer` forwards nothing, and the app quietly
falls back to the public demo — so the fixture-backed tests run against a
server that has no fixtures and fail as though the player were broken. This
page documented the unprefixed form until 2026-08-26, which cost an afternoon
of chasing four "player" failures that were one missing prefix.

The runner passes these values to the DEBUG-only bootstrap through the app
launch environment; they are never persisted by Lagoon or compiled into a
Release build.

Release builds also emit a `Player Panel Reveal` interval in the existing
`ee.helop.lagoon/PlaybackPerformance` signpost category. Use that interval and
the Animation Hitches instrument for physical-Apple-TV validation, where GPU
composition cost is more representative than Simulator timing.

- **Why compressed packets stay zero-copy**: Matroska stores h264/hevc
  mp4-style (avcC/hvcC extradata + length-prefixed NALs), so demuxed
  packets wrap directly as compressed sample buffers. The display layer
  decodes H.264; the in-engine VideoToolbox stage decodes HEVC. CoreAudio
  likewise decodes compressed aac/mp3/ac3/eac3
  handed to the audio renderer (ac3/eac3 self-describing; aac needs its
  AudioSpecificConfig as the magic cookie; audio packet cadence prefers
  FFmpeg's parsed `frame_size`, with codec fallbacks including 576-frame
  MPEG-2/2.5 Layer III at 24 kHz and below).
  The CoreMedia block retains the packet's underlying `AVBufferRef` with
  `av_buffer_ref` and releases that reference after decode, avoiding both a
  packet-structure clone and a second allocation/full payload copy for every
  compressed packet. Packet pts/dts/duration are converted to `CMTime` in the
  stream's exact rational time base rather than round-tripping through
  floating point and a fixed 90 kHz scale.
- **Audio decode** (M4): codecs CoreAudio won't take compressed
  (DTS, TrueHD, FLAC, Opus, Vorbis — anything with an FFmpeg decoder)
  go through `AudioDecoder`: libavcodec → swresample → interleaved
  Float32 LPCM sample buffers, coalesced to ~2048-sample chunks because
  TrueHD frames are 40 samples each. swresample writes directly into the
  growable coalescing allocation, which is reused across chunks, so the
  per-decoded-frame temporary allocation and append copy are both gone; the
  chunk itself is then copied into a CoreMedia-owned block at emit (see
  "Do not make the LPCM emit zero-copy" below — the handoff that avoided
  this copy leaked the decoded stream).
  FFmpeg's native channel-bit order
  matches CoreAudio's channel bitmap bit-for-bit on the first 18
  positions, so a native layout mask maps straight across into the
  `AudioChannelLayout`. The E-AC3 (JOC/Atmos) path deliberately stays
  compressed passthrough. Platform limit stands: TrueHD Atmos objects
  are unpreservable — TrueHD plays as lossless multichannel LPCM.
- **Atmos from E-AC3 JOC — the recipe** (M2, settled on real hardware
  2026-08-17 after three failed attempts): when FFmpeg reports
  `AV_PROFILE_EAC3_DDP_ATMOS`, the format description must use the
  **`'ec+3'` media subtype** (Apple's "Enhanced AC-3 with JOC"; no
  public constant) with **`mChannelsPerFrame = 16`** (the HLS
  `CHANNELS="16/JOC"` presentation), plus the synthesized `dec3` box
  (ETSI TS 102 366 Annex F) as magic cookie + extension atom. Things
  that do NOT work: plain `ec-3` passthrough, an
  `kAudioChannelLayoutTag_Atmos_9_1_6` channel layout (alone or
  combined with `ec-3` + dec3) — those decode only the DD+ core and
  report "Multichannel". Verified: Samsung soundbar Atmos handshake +
  "Dolby Atmos" in the AirPods submenu.
  **Timing gotcha**: successive LPCM buffers anchor to the sample-exact
  end of the previous one (stamped at the stream's own sample rate) and
  re-anchor to container pts only on >50 ms jumps — Matroska stamps at
  1 ms precision (TrueHD frames are 0.83 ms) and 90 kHz can't represent
  48 kHz boundaries, and either mismatch renders as steady clicking.
- **Passthrough audio timing** (HEL-64): the same clicking mechanism hit
  the *compressed* path. An AAC frame is 1024 samples — 21.33 ms, not
  representable in Matroska's 1 ms stamps — so container pts jitter up to
  ~1.7 ms (measured deltas 21/22/23 ms, ~47 packets/s), each one a
  discontinuity the renderer renders as crackle; EAC3 (1536 samples =
  exactly 32 ms) was immune, which is why only AAC titles crackled on
  hardware. `PassthroughAudioTimeline` now chains pts sample-exactly from
  one container anchor. Forward gaps beyond **half a packet** re-anchor —
  tight enough that one *missing* packet cannot become a permanent A/V
  offset (the LPCM path's 50 ms tolerance would swallow that for every
  passthrough codec). Backward packets beyond that tolerance overlap audio
  already queued and are dropped until the container catches up. This handles
  the measured HLS AAC boundary sequence (four 1-sample packets followed by a
  short preroll packet) without pulling the renderer backward; explicit seeks
  reset the chain before the new anchor. The HUD's
  `aGaps` counter (audio timestamp discontinuities at enqueue) is the live
  check: it must read 0 during untouched playback.
- **Video frame-grid timing** (HEL-64): Matroska quantizes video PTS to 1 ms
  while a 23.976 fps frame lasts 41.708 ms. `VideoFrameTimeline` removes
  that jitter before the frame reaches either video path. Hardware A/Bs
  proved it was not the cause of the 10% loss—the failing title dropped at
  the same rate with exact and untouched container stamps—so this remains
  a scheduling-accuracy invariant, not the frame-loss fix.
  `VideoFrameTimeline` snaps each pts to the nearest whole-frame step
  from the previous snapped stamp (signed steps — packets arrive in
  decode order, so B-frame reordering walks backwards), exact integer
  arithmetic in the frame rate's own timescale; stamps beyond a 5 ms
  tolerance (VFR, broken mux) pass through untouched and re-anchor.
  Decode stamps stay the container's — they only order the decode. The
  HUD's `Vtime: grid N/D` line is the gate check.
- **HEVC decode-ahead and presentation order** (HEL-64): the frame loss was
  isolated to handing compressed full-raster 4K Main10 samples directly to
  the sample-buffer renderer. `VideoToolboxDecoder` now hardware-decodes
  HEVC ahead *inside the same Lagoon engine*, wraps its IOSurface-backed
  10-bit-capable pixel buffers as ready image sample buffers, and feeds the
  existing renderer/synchronizer. The VideoToolbox pool reconciles the
  renderer's tvOS 26 `recommendedPixelBufferAttributes` with Lagoon's
  IOSurface + Metal requirements; pixel format remains unconstrained so
  VideoToolbox preserves native bit depth and color attachments. Per-frame
  HDR/Dolby Vision display metadata propagates normally, with ambient viewing
  environment metadata explicitly restored on decoded output as a fallback.
  Decoder callbacks cannot be treated as a presentation-order contract: a
  bounded PTS queue keeps at least six frames (or the larger FFmpeg-reported
  codec delay, capped at 16) and emits strict display order. Seek recreates
  the decoder and discards the old callback generation; EOF explicitly
  finishes delayed frames before waiting. A seek-preroll
  `kVTVideoDecoderReferenceMissingErr` is scoped to that failed access unit:
  Lagoon drops that frame and lets the valid session recover at the next
  reference picture instead of aborting the entire player. The
  rendered-frame queue uses an
  18-frame high / 12-frame low watermark: a bounded 0.50–0.75 s cushion at
  23.976 fps for high-bitrate input jitter without unbounded 4K surfaces.
  On Apple TV 4K (3rd generation),
  the original 4K HDR10 failure went from ~10% loss to **0 / 1462 dropped**;
  the 4K HDR10 control remained **0 / 1439**, both with zero stalls and zero
  audio gaps. Snowden's documented 610 s stress scene exposed a separate
  input-starvation limit: with the old 12/8 watermark, three hardware runs
  lost 1.25–1.65% with 3–11 stalls and `minQ=0`. The bounded 18/12 cushion's
  immediate same-scene rerun was **0 / 1438**, zero stalls, `minQ=10`.
  Final normal-viewer confirmation (debug HUD off) repeated at
  **0 / 1462** and **0 / 1438**, with zero stalls/audio gaps and
  `minQ=9/11`. With the live SwiftUI HUD enabled the same build measured
  5 / 1445 and 4 / 1438 despite a healthy queue; the diagnostic overlay's
  compositing is measurement interference, not viewer-mode frame loss.
  Sustained repeated 91 Mbps pulls later slowed even format probing from a
  few seconds to 20–40 s and again emptied the queue; no finite sub-second
  decoded-frame cushion can turn an upstream feed running below real time
  into uninterrupted playback, so those cases correctly enter buffering.
- **VC-1 direct play**: Apple exposes no VC-1 VideoToolbox decoder on tvOS,
  but `AVSampleBufferVideoRenderer` accepts ready sample buffers containing
  Core Video image buffers. Lagoon therefore keeps the original MKV and
  audio stream, decodes progressive 8-bit VC-1 through its existing pinned
  libavcodec, copies planar 4:2:0 output into renderer-recommended IOSurface/
  Metal-compatible NV12 buffers, carries colorimetry and exact frame timing,
  and wraps each image with `CMSampleBufferCreateReadyWithImageBuffer` for the
  existing render synchronizer. The advertised profile is capped at 1080p
  and excludes interlaced video, which for every codec but MPEG-2 still goes
  to the server (HEL-127); anything outside that envelope still uses the
  server transcode fallback.
  Keeping eligible files in one original stream also removes the short HLS
  fragment boundary that caused the reported repeating audio cut-outs. The
  affected VC-1 + AC-3 pairing decodes AC-3 locally to LPCM before enqueueing
  it to Apple's audio renderer; this remains Jellyfin Direct Play and is
  deliberately narrow, so E-AC-3/Atmos and non-VC-1 AC-3 retain compressed
  passthrough. Planar 4:2:0 chroma interleaving uses an ARM NEON C primitive
  (with a scalar fallback) instead of a per-byte Swift loop, and software VC-1
  holds a bounded 30/24-frame decoded reserve with a 42-frame hard ceiling.
  Each packet iteration has its own autorelease pool: the demux worker is one
  long-lived dispatch item, so relying on its outer pool retained Core Media
  scratch allocations until dismissal even though the actual frame queues
  were bounded.
- **MPEG-4 Part 2 direct play**: the Xvid/DivX AVI envelope rides the exact
  same libavcodec → Core Video path VC-1 opened, so enabling it was
  `SoftwareVideoDecoder.supports` plus an `avi` container and a bounded
  `mpeg4` codec profile — no new engine machinery. Simple and Advanced
  Simple Profile are 8-bit 4:2:0 *by specification*, which is exactly the
  envelope the software decoder accepts, so the pixel-format gate cannot be
  surprised. AC-3 beside this video routes through the existing
  `AudioDecodePolicy.requiresLocalPCM` rule — it keys on
  `softwareVideoDecoded`, not on VC-1, so the pairing that made VC-1 stutter
  was already handled (HUD confirms `ac3 · 2ch · local LPCM`).
  **Packed bitstream** is the one real quirk. Old DivX/Xvid rips pack two
  VOPs into one AVI chunk and mark the gap with a 7-byte "VOP not coded"
  packet; libavcodec logs `Discarding excessive bitstream in packed xvid`
  and consumes them correctly. A decode sweep of all 197 AVI titles on
  fixture (5 s from the start plus 3 s after a mid-file seek) found 167
  clean, 29 packed-bitstream, and 1 genuinely damaged file
  (`illegal MB_type` / `ac-tex damaged` — the server transcode hits the same
  errors, so direct play does not make it worse). Frame accounting is exact
  either way: 120 s of a packed title decodes 2877 frames raw and 2878
  through `mpeg4_unpack_bframes`. Crucially there are **no zero-size
  packets** (minimum is 7 bytes) — a zero-size packet is libavcodec's drain
  signal and would have ended the stream mid-playback. The
  `mpeg4_unpack_bframes` BSF is present in the pinned build if a defect ever
  does surface; the demuxer has no bitstream-filter plumbing today, and
  adding it was deliberately not done on this evidence.
- **MPEG-2, PCM and DVB subtitles** (HEL-104): these already had decoders in
  the pinned FFmpeg build; the missing piece was the profile that allowed the
  server to send them. Progressive SDR MPEG-2 uses the bounded 8-bit 4:2:0
  software-video path at up to 1080p. Interlaced MPEG-2 direct-plays as well
  as of HEL-127, below. MPEG program/transport-stream and VOB
  containers are included so DVD and recorded-TV sources can actually reach
  that path. Integer/float PCM variants, Blu-ray LPCM, and DVD LPCM use the
  existing libavcodec → Float32 LPCM audio renderer path; DVB bitmap subtitles
  use the same paletted-rectangle decoder and overlay as PGS and VobSub.
- **Deinterlacing** (HEL-127): the software decode path makes an interlaced
  frame progressive before it copies it out, so MPEG-2 no longer has to be
  sent to the server to be made watchable. Written rather than linked:
  deinterlacing normally means libavfilter's yadif, and libavfilter is not
  among the pinned FFmpeg artifacts, so reaching for it is a dependency
  decision rather than a filter call. `Deinterlacer` does the useful half of
  yadif's spatial pass — predict along whichever direction the image runs,
  and keep the original sample wherever the two fields already agree. What it
  gives up is yadif's temporal half; the per-pixel agreement test stands in
  for it, so a still shot survives at full vertical resolution and only
  motion is interpolated. Measured against yadif on a real interlaced frame:
  0.34 levels per pixel apart out of 255, at 1.61 ms per frame at 720x576.
  Two things are deliberate. The frame is made writable first, because what
  the decoder hands over may still be a reference frame later pictures are
  predicted from. And only MPEG-2's `IsInterlaced` guard came out of the
  profile: every codec that decodes in hardware keeps it, since there is no
  stage there to hand a field pair to. That also turns out to be what makes a
  DVD image playable at all — with the guard in place Jellyfin answers an
  interlaced disc with a transcode and the image never reaches the client.
- **10-bit AV1 and VP9** (HEL-103): progressive AV1 Main and VP9 profiles 0/2
  direct-play at up to 10-bit. AV1 routing and negotiation are
  capability-aware:
  VideoToolbox receives compressed AV1 plus its `av1C` configuration on
  hardware that reports an AV1 decoder and retains the full-resolution
  profile; otherwise the pinned dav1d decoder is used, bounded at 3840×2160.
  That bound was 1920×1080 until the threading fix below, and the HD figure
  was quietly assuming a single core: 30 s of 4K HDR10+ AV1 decodes in 1.66 s
  threaded against 13.26 s on one. 8K stays out, unmeasured. VP9 always uses
  the software path and keeps the 1080p cap it was written with.
  FFmpeg's 8-bit planar/NV12 output becomes Core Video NV12. Its little-endian
  planar 10-bit output is shifted
  from low-bit words to P010's high-bit layout and U/V is interleaved by an
  ARM NEON primitive (with scalar fallback); native P010 output is copied
  stride-aware. Color primaries, transfer function, YCbCr matrix, range,
  chroma location, pixel aspect, and exact presentation timing propagate on
  both paths, as does HDR10 static metadata — the compressed path writes
  mastering display, content light level and `amve` into the format
  description directly, while the software path attaches the same three
  payloads to the pixel buffer, where
  `CMVideoFormatDescriptionCreateForImageBuffer` copies them into the
  description and the renderer sees them on every frame. Transfer function
  alone is what switches tvOS into HDR; without the rest the display
  tone-maps from its own defaults instead of the master's, which matters
  here because VP9 always takes the software path and AV1 takes it on every
  Apple TV shipping today. The software 1080p ceiling is intentional for the first release:
  widen it only after the physical-device frame-loss and memory benches show
  enough CPU and jetsam headroom.
- **Anamorphic / non-square pixels**: `SampleBufferFactory` attaches
  `kCMFormatDescriptionExtension_PixelAspectRatio` from the stream's
  `sample_aspect_ratio`, and `SoftwareVideoDecoder` attaches the matching
  `kCVImageBufferPixelAspectRatioKey` to its Core Video buffers (the
  prototype the format description is built from, and every frame), so both
  the compressed and software paths advertise the same geometry.
  `videoDimensions()` returns
  `CMVideoFormatDescriptionGetPresentationDimensions` rather than coded
  dimensions — `videoSize` positions the subtitle overlay, so an anamorphic
  stream would otherwise lay cues out against the wrong box.
  **The 1% tolerance is the load-bearing part.** `pixelAspectRatio` returns
  nil for square, unknown (libavformat's 0/1) *and anything within 1% of
  square*, so those format descriptions stay byte-identical — this code is
  on the path taken by every h264/hevc title, and the same description goes
  to `AVDisplayCriteria` and `VTDecompressionSessionCreate`. Real files are
  full of rounding artifacts: probing all 245 items Jellyfin flags
  `IsAnamorphic` on fixture found **203 with a genuine pixel aspect**
  (16:15 and 64:45 PAL, 4:3 HDV, 45:44, 8:9) and **42 that are artifacts**
  (1744:1745, 1279:1280, 180224:180219 — hundredths of a percent). Honouring
  those would have changed 42 descriptions to correct nothing visible.
  Every genuine case is h264 (200) or mpeg4 (3); all 27 hevc items in that
  set are artifacts, so **no VideoToolbox-decoded stream in this library
  carries a PAR extension** and whether VideoToolbox propagates the
  attachment onto its output buffers is untested — it would only matter for
  a genuinely anamorphic HEVC source.
  Verified in the simulator: 720x576 SAR 16:15 presents 768x576, SAR 64:45
  presents 1024x576 (filling the 16:9 frame instead of pillarboxed and
  squished), the software path's 710x480 SAR 8:9 presents 631x480, and a
  square 1920x1080 h264 still reports 1920x1080 with 0 dropped frames.
  The device profile no longer excludes `IsAnamorphic`, and no longer
  excludes interlaced MPEG-2 (HEL-127). Interlaced content in every codec
  that decodes in hardware still transcodes, because the deinterlacing stage
  lives on the software path.
- **Subtitles** (M5): rendered as a SwiftUI overlay, never through the
  renderers. Embedded streams decode via `avcodec_decode_subtitle2`
  (normalizes srt/ass/ssa/mov_text to ASS event payloads — text is
  everything past the 8th comma — and
  PGS/VobSub to paletted rects converted to CGImages, positioned on the
  codec's graphics plane). External Jellyfin streams (vtt delivery)
  download and parse into the same cue store. Every subtitle stream is
  listed even if undecodable so per-type ordinals stay aligned with the
  server's stream list; external tracks append after embedded ones and
  the controller maps `DefaultSubtitleStreamIndex` into that combined
  space. Selecting an embedded track re-demuxes from the current
  position (same trick as audio switching) so the active line appears
  immediately; PGS cues are open-ended and close on the next
  composition event. Server Forced/SDH/language metadata is merged into
  both embedded and sidecar tracks, exposed to Now Playing, and retained
  when a downloaded subtitle is inserted into the running engine. The
  player can search Jellyfin's configured providers by ordered preferred
  language, explicitly download a result, refresh PlaybackInfo, and
  side-load/select the authenticated external file without restarting the
  video. Not covered: an embedded subtitle rendition inside an HLS master
  (remote downloads arrive as external files and do work).
- **ASS/SSA authored placement** (HEL-107): `ASSSubtitleTextParser` keeps each
  decoded text composition separate rather than joining simultaneous speakers
  into one bottom-centre block. It reads `PlayResX/Y` from FFmpeg's subtitle
  header, normalizes `\pos(x,y)` onto the presentation rect, uses `\an1…9` as
  the authored anchor, and retains inline primary colour, bold and italic
  runs. All other override commands remain deliberately ignored: this is the
  useful signs/dialogue subset, not a libass replacement. A cue with none of
  those supported overrides takes the exact old `PlayerSubtitleText` path, so
  ordinary SRT/WebVTT and plain ASS dialogue keep the viewer's caption font,
  edge, background and vertical position unchanged.
- **Two subtitle sources** (HEL-92): Jellyfin's routes require the account's
  `EnableSubtitleManagement` permission, which is off by default for every
  non-administrator — the common case on a shared server. Those accounts fall
  back to OpenSubtitles fetched **straight into the player**: no library
  write, no server permission, and nothing about the provider account is
  disclosed to Jellyfin. `SubtitleSourcePolicy` prefers Jellyfin whenever it
  is available, because it persists the sidecar for every client and every
  other viewer, converts the file server-side, uses whatever providers the
  administrator configured, and costs the viewer none of their personal
  provider quota. An explicit choice in Settings is never silently
  overridden. Both sources produce `SubtitleCandidate`, so the UI privileges
  neither.
- **Matching and quota**: the direct provider is searched by OpenSubtitles'
  moviehash (file size plus the little-endian 64-bit word sums of the first
  and last 64 KiB) when the stream is range-readable, which identifies the
  exact release rather than the title; `imdb_id`/`tmdb_id` from Jellyfin's
  `ProviderIds` and a title/season/episode query are the fallbacks. Downloads
  are quota'd — five a day anonymously, twenty with a free account — so every
  fetched sidecar is kept under `Library/Caches/Lagoon/Subtitles` and a repeat
  watch is served from disk. The account prompt is deferred until the
  allowance actually runs out; searching needs no account at all. The download
  request asks for `sub_format=srt`, so the provider converts ASS/SSA on its
  side and Lagoon's `-->`-only parser never sees an authored format.
- **Text encoding**: `SubtitleTextDecoder` replaces a fallback chain that
  ended in `isoLatin1`, which cannot fail — it maps every byte — so a
  Windows-1251 file used to decode to mojibake and render as garbage with no
  error anywhere. Jellyfin converts to UTF-8 on its way out, which hid this;
  a provider fetched directly does not. Order is BOM, then strict UTF-8, then
  the codepage implied by the track's language (Cyrillic → 1251, Baltic →
  1257, and so on), then Windows-1252. **Known limitation**: with no language
  hint a legacy file still decodes to mojibake. Cyrillic bytes read as Latin-1
  become ordinary accented Latin letters, and separating that from real
  Western-European text needs statistical models — a cheap heuristic that
  guessed would mis-decode German as Cyrillic, which is worse than the status
  quo. Every path that fetches a subtitle therefore carries a language.
- **Threading**: the demux loop runs on a serial queue feeding two
  condition-protected sample-buffer queues; renderer pumps drain them via
  `requestMediaDataWhenReady`; state and transport live on the main actor.
  Independent video/audio high-water marks apply hysteretic backpressure and
  wake the producer when consumers cross their low-water marks, so a full
  queue blocks without polling or arbitrary sleeps. Every renderer data
  request is paired with `stopRequestingMediaData` before release. Teardown
  removes each renderer asynchronously at `.invalid` (Apple's immediate-
  removal sentinel) and waits for both completion callbacks before the next
  episode can attach a renderer set.
- **Seeks and clock starts** stop the clock, serialize renderer flushes with
  enqueueing, reset queues, use `avformat_seek_file` against the selected
  video stream (with `av_seek_frame` only as a demuxer compatibility
  fallback), then re-prime (~12 video
  buffers). Playback binds the first presentable media time to a near-future
  host-clock time with `setRate(_:time:atHostTime:)`, so audio and video start
  on one deadline. A generation token prevents an older priming callback from
  restarting after a newer seek. The engine observes
  `requiresFlushToResumeDecoding` and performs this same clean seek/flush
  recovery when AVFoundation requests it. Resume uses the same path.
- **Audio tracks**: listed from the demuxer (per-type 1-based ordinals —
  the same convention the server's `DefaultAudioStreamIndex` maps to);
  switching re-demuxes from the current position with the new stream
  selected and the rest discarded inside libavformat.
- **HDR/DoVi tagging** (M3): the video format description carries
  colorimetry extensions (primaries/transfer/matrix/range/chroma siting
  from codecpar) plus HDR10 static metadata (mdcv/clli payloads rebuilt
  big-endian from FFmpeg side data). H.274 ambient viewing environment side
  data is serialized into Apple's 8-byte `amve` format-description extension
  and, after HEVC decode-ahead, a propagating sample attachment. Those tags
  make the display pipeline engage and adapt HDR/EDR instead of rendering
  BT.2020+PQ as washed-out SDR. Dolby Vision: profile 5 becomes a `dvh1`
  sample entry with a
  `dvcC` atom (IPTPQc2 is unwatchable without the DoVi path), profile 8
  stays `hvc1` plus supplementary `dvvC` (non-DoVi displays fall back to
  the base layer's HDR10/HLG tags), dual-layer profiles 4/7 get no atom
  and play as HDR10 from the base layer. Profile 7
  (`DOVIWithEL`/`DOVIWithELHDR10Plus`) **direct-plays** on that basis:
  the BL is plain Main 10 HDR10(+), the EL NALs are unspecified types
  the decoder ignores, and tvOS can't reconstruct dual-layer DoVi anyway
  — same presentation as the server's strip-to-HDR10 transcode without
  the lossy re-encode. Hardware verification pending (the simulator has
  no HDR output; DoVi P5 may not decode in the sim at all).
  **EL strip experiment** (HEL-64, Settings → Debug → Strip DoVi
  Enhancement Layer, default off): P7's "ignored" EL/RPU NALs (unspec
  types 63/62) are not free — on Snowden they are 14.5% of an 86 Mbps
  bitstream (~11 Mbps, ~4 units per frame) of parse-and-skip work for the
  hardware decoder. The toggle drops them from each packet before wrapping
  (`HEVCEnhancementLayerFilter`; malformed payloads pass through
  untouched, stripped packets lose zero-copy). A same-scene hardware sample
  with stripping enabled was worse (3.14%, 13 stalls), not better; source
  throughput degraded across the repeated 91 Mbps pulls, so this is not a
  clean causal comparison and the experiment remains default-off. The HUD
  and benchmark stdout report `EL strip` state and removed units/bytes so
  future controlled A/Bs can prove the gate engaged.
- **Stall recovery** (M6): when the clock catches up to the last
  delivered video pts with a dry queue and the file isn't over, the
  engine holds the synchronizer (buffering spinner) and auto-resumes
  once ~12 buffers rebuild. `av_read_frame` distinguishes `AVERROR_EOF`
  from read failures — transient errors retry briefly, persistent ones
  surface as the error overlay instead of fake-finishing the file (which
  would have moved the server resume point). At real EOF the audio
  decoder drains its coalescing tail. In HLS masters the working set is
  restricted to the chosen video's program, so other variants never
  download segments or duplicate the track list.
  Completion is armed at the last observed audio/video sample end through
  the render synchronizer's boundary observer. It therefore waits for
  AVFoundation's internal queues and also completes streams whose container
  duration is unknown; it is not inferred early from app queue depth.
- **Starvation is a question about both queues, not just video** (HEL-123).
  Stall detection originally tested `videoQueue` alone. An audio queue at
  zero therefore produced no stall, no buffering state and no counter
  movement: the film played on with the picture running and no sound while
  every indicator read healthy — `AudDrop` absent, `aGaps` 0, `stalls` 0.
  Nothing was being discarded; nothing was arriving. Reported on hardware
  against a 64.5 Mbps source the server was transcoding, where both queues
  oscillated `V 30 A 0` to `V 0 A 0` and video survived only because the
  renderer coasts on frames it already holds.

  **The first attempt at this shipped in 0.1 (66) and was wrong.** It
  treated an empty audio queue as a stall and stopped the clock for it,
  which broke playback on every title with audio: Ted 2 and GTA VI both
  went from playing correctly to a continuous buffer/play/buffer cycle.
  Reverted in 67, and the reason is worth keeping:

  > **`audioQueue` depth is not a measure of audio starvation.**
  > `pumpAudio` drains it into `AVSampleBufferAudioRenderer` for as long as
  > the renderer reports `isReadyForMoreMediaData`, so the buffered seconds
  > live inside the renderer and Lagoon's queue sits near zero on a
  > perfectly healthy title.

  Switching the reading from packet count to buffered seconds does not
  rescue it, and that is the trap worth recording, because it looks like it
  should: the ticket's own text warns that a count near zero cannot
  distinguish a starved feed from one being drained as fast as it fills,
  and the seconds are that same queue in different units. Both are the
  wrong side of the pump. A real audio-starvation signal has to come from
  the renderer, and finding one is still open.

  What stands is the reporting, which is the minimum HEL-123 asked for.
  `PlaybackStarvationPolicy` answers `.none`/`.video`/`.audio` from a
  snapshot; `.video` confirms and stops the clock exactly as it always did,
  while `.audio` is counted per episode and shown in the HUD (`aDry`) and
  the bench (`aStalls`). `StallRecoveryPolicy` is video-only, and gating it
  on audio as well was the second half of the same mistake: it would have
  hung every video stall until `reprimeAfter`, since the cushion it waited
  for is not normally there. Both are pinned by tests so neither comes
  back.

  **The cutouts themselves were never Lagoon's**, confirmed on hardware in
  0.1 (71). The 64.5 Mbps source "the server was transcoding" was the server
  rebuilding a 64.8 GB Blu-ray image in real time, because Lagoon could not
  open the image itself. Reading the disc directly (HEL-133) removed the
  transcode and the audio drops with it: same Apple TV, same network, same
  cache, same title, no cutouts. The starvation was upstream delivery, and
  the `Buffer:`/`Cache:` reading nobody ever captured is moot for this title
  because there is no longer a cutout to capture it during.

  The defect is still open, and is worth keeping apart from the symptom. A
  genuinely starved audio path can still play on with the picture running and
  no sound while every counter reads healthy. What changed is that the only
  title anyone could reproduce it on no longer does, so verifying a fix will
  need a deliberately starved feed: a throttled connection, or a transcode
  paused server-side mid-playback.
- **A stream with no cache gets a bigger demux cushion** (HEL-130). The
  sparse AVIO cache is enabled for direct play and direct stream and off for
  a transcode, because a Jellyfin HLS transcode has mutable manifests and a
  byte-range cache over a playlist that changes underneath it is not
  something to ship. That reasoning is sound, but "no byte-range cache"
  became "no buffering of any kind": no sparse cache, no proactive range
  fill, no playhead prefetch, with the demux queues the only thing between
  the network and the renderers. A hitch in segment delivery therefore
  stalls the read directly, both queues drain, and audio goes silent at once.

  The queues are now asked to be a bigger cushion when there is no cache.
  Three things about that are deliberate:

  - **It keys on the cache, not the play method**, so the two compose: a
    transcode with `debug.experimentalPlaybackCache` on is not uncached, and
    a direct play that fell back to the native transport is.
  - **Only audio grows.** Video's queue holds decoded frames — 24.9 MB each
    at 4K 10-bit, which is why its hard limit is 30 and why HEL-126 exists —
    while audio holds compressed packets at roughly 80 KB a second. Doubling
    the audio cushion costs about 1.5 MB against a video queue already
    permitted 746 MB; the worst case, a locally decoded 8-channel track held
    as float LPCM, is about 26 MB. Audio is also the half with no cushion of
    its own, which is why a starved transcode reaches the viewer as silence
    over a moving picture rather than as a freeze.
  - **The safety margin grows too** (1.25 s to 3 s). That is the margin video
    must leave audio covered for before it may park on its own high water,
    and without a cache the drain it has to survive is a network round trip
    rather than a cache read. It is the half that actually keeps the loop
    reading for audio instead of parking on video.

  The HUD shows the depth being aimed for (`A 200/360`), so which profile is
  in force is visible rather than inferred from a missing line.

  This does not answer whether the HLS cache scope is sound enough to enable
  outside DEBUG. That still needs the hardware A/B the shipped switch exists
  for, and the two are independent: a cushion helps a stream that has no
  cache, and turning the cache on is what would stop it being one.
- **Audio delay** (M6): mpv convention, positive delays audio; applied
  by re-stamping buffers at enqueue (`CMSampleBufferCreateCopyWithNewTiming`)
  and re-demuxing from the current position on change. Lives in the
  Audio tab's OPTIONS column.
- **HEL-48 closed 2026-08-17**: all engine milestones (M1–M6)
  hardware-verified end-to-end — direct play, Atmos (recipe above),
  HDR/DoVi presentation, DTS/TrueHD multichannel, subtitles, Menu/panel
  policy. Accepted platform limits: TrueHD Atmos objects unpreservable
  on tvOS; no subtitles during HLS transcode. Transport UX work
  (scrubbing/trickplay/motion) continues on HEL-39.

## System media integration (HEL-41, HEL-80)

Lagoon owns the system behavior AVPlayer would otherwise supply; it does
not introduce a second player to get it:

- `PlaybackAudioSession` activates `.playback` / `.moviePlayback`, enables
  multichannel content, uses `.longFormVideo` on iOS, and deactivates with
  `notifyOthersOnDeactivation` when playback ends. Interruption callbacks
  are idempotent: resume only when the item was playing and the system sets
  `shouldResume`. Route changes pause when a personal output (wired,
  Bluetooth, or AirPlay) disappears, but not for tvOS HDMI mode changes.
  Media-services reset re-establishes the category and active session.
- **Audio spatialization** (HEL-105). Every audio renderer is built by one
  factory, `SampleBufferPlayerEngine.makeAudioRenderer`, so a replacement
  after a failure or a media-services reset sounds exactly like the renderer
  it replaces. What the factory changes is the spatialization default, which
  differs between Apple's two players and not in this one's favour:
  `AVPlayerItem` documents `monoStereoAndMultichannel` for video content,
  while `AVSampleBufferAudioRenderer` documents — and, verified at runtime,
  really does default to — `multichannel` alone. Left alone, a stereo
  soundtrack that AVPlayer would spatialize on AirPods plays flat, which
  covers a great deal of television, anime and older film. The property
  grants permission rather than forcing an effect: the viewer's Spatial Audio
  setting still decides, and over HDMI to a receiver it changes nothing.
  A test pins both defaults, so if a future SDK closes the gap it says so and
  the override can go.
- **Playback speed** (HEL-106). 0.5× through 2×, from the playback panel's
  **Video** tab, which mirrors the Audio tab twice over: the same split — what
  is playing on the left, its options on the right, a content-sized divider
  between — and the same control shape as the audio delay row, a label, the
  value, and a pair of `-`/`+` steppers. It is the same kind of setting, one
  value from a short ordered scale, and it is almost always left at 1×, so it
  gets a row rather than six selectable options; those were tried both stacked
  and as a row and neither earned the space. Stepping is clamped at both ends
  rather than wrapped: a plus at 2× that landed on 0.5× reads as a bug. The
  value is dimmed at 1× exactly as a zero delay is.

  The options column declares `.focusSection()`, which the Audio tab does not
  need: its left column is a list of focusable rows, so something always sits
  directly under the tab. This card's left column is a summary line, and
  without the section Down from the tab finds nothing below it and focus never
  enters the card at all.

  The transport shows the selected rate beside the title whenever it is not
  1×. Pausing, seeking, buffering,
  renderer recovery, delivery fallback and next-episode handoff all preserve
  it. Every audio renderer uses the time-domain pitch algorithm, including a
  replacement after media-services reset. Stall recovery, the delivered-PTS
  margin, initial priming and demux watermarks scale their media-time cushion
  by rate while retaining the decoded-frame hard limits. Now Playing publishes
  the real rate and `changePlaybackRateCommand` exposes the same choices to
  Control Center, headset and system clients.

  It briefly lived in the transport instead, as a button above the scrubber
  that opened a menu. That was reverted — see **Putting controls in the
  transport** below, which is the useful part of the exercise.

- **An engine that has shut down must never be revived** (HEL-110).
  `attach(displayLayer:)` guards on `shutdownRequested`, not only on the
  renderer being empty. `finishRendererShutdown` nils `videoRenderer`, so the
  emptiness check alone let a retired engine pass — and SwiftUI *does* re-mount
  the player surface after a failed playback, whose `makeUIView` attaches
  unconditionally. The retired engine then re-registered a renderer set that
  could never be detached, because `shutdown` early-returns once requested, and
  started a **second demux loop** that reopened the stream — for a transcode,
  a second server-side ffmpeg job nobody would ever stop.
  The stale renderer entry is process-global and `PlaybackController.start`
  waits on it, so one failed title delayed the next by the full 15 s timeout
  and showed "The previous video could not release its player resources."
  Deliberately *not* fixed by clearing the counters in `deinit`: renderer
  removal is asynchronous and outlives the Swift object, so its real
  AVFoundation completion has to balance the counter or the lifecycle
  benchmark stops being able to see a leak at all. Traced with
  `debug.playbackLifecycleLog`, which prints each lifecycle event with the
  engine id — the ids are what made "the same engine attached twice" visible.
- **Audio renderer failure** (HEL-101). The two notifications an audio
  renderer posts — `WasFlushedAutomatically` and
  `OutputConfigurationDidChange` — are its *recoverable* events, and both
  reseek from the playhead. Hard failure has no notification: Apple exposes
  it as `status`, documented key-value observable and "terminal status from
  which recovery is not always possible". Unobserved, a failed renderer left
  the film playing on in silence with nothing reported anywhere.
  The observation hops to the main actor rather than using
  `MainActor.assumeIsolated` like the notification blocks, because KVO is
  delivered on whichever thread changed the property and a CoreMedia-owned
  renderer does not change it on the main one.
  Recovery is replacement — the object cannot be revived — and it shares one
  path with the media-services reset, which needs the same swap. The two
  differ only in what the viewer is owed afterwards, which is what
  `AudioRendererReplacement` encodes: a reset stays paused because Apple
  requires an explicit viewer action before resuming, while a renderer that
  failed on its own resumes, since nothing the viewer did caused it. Neither
  un-pauses a viewer who paused deliberately: the refill goes through `seek`,
  and `beginPlayback` honours `isPaused`. The video renderer stays attached
  to the synchronizer throughout, so what is lost is a few hundred
  milliseconds of audio rather than the film. If the swap itself fails,
  playback has no audio path at all and the failure is reported as
  `.delivery`, which sends it to the delivery ladder above.
  `debug.regressionInjectAudioRendererFailure` drives it (a renderer cannot
  be made to report `.failed` on demand), and the HUD's `Recovery:` line
  counts audio replacements and service resets separately — otherwise a
  replacement leaves no trace at all, which is the point of it. Verified on
  the simulator: injected mid-playback at 691.2 s, resumed at 691.2 s, clock
  past 727 s with queues refilled, zero stalls and zero audio gaps.
- `NowPlayingCoordinator` publishes a stable Jellyfin item identifier,
  title/episode line, poster, duration, elapsed time, rate, and playback
  state. It registers play, pause, toggle, ±10 s, absolute position, and
  playback-rate and audio/subtitle language-option commands. Handlers hop to
  the main actor because MediaPlayer doesn't promise a callback queue; all
  targets and Now Playing state are removed on teardown.
- PiP uses `AVPictureInPictureController.ContentSource` with the existing
  `AVSampleBufferDisplayLayer` and a
  `AVPictureInPictureSampleBufferPlaybackDelegate`. Its play/pause/skip
  callbacks operate on the same `SampleBufferPlayerEngine`; there is no
  hidden AVPlayer. iOS exposes the system `AVRoutePickerView` for AirPlay.
  Backgrounding pauses unless PiP is active/transitioning or AirPlay owns
  the route. `AVInitialRouteSharingPolicy=LongFormVideo` and the audio
  background mode are declared in the plist.
- Caption rendering reads Apple's Media Accessibility font, foreground,
  opacity, size, background, and edge preferences live; Lagoon's per-account
  override adds size, edge, background, and vertical-position controls.
  System caption languages seed the ordered primary/fallback search list,
  system Forced/Automatic/Always On policy seeds a first playback, explicit
  track selection feeds the language back to the system preference stack,
  and visible text is reported through
  `MACaptionAppearanceDidDisplayCaptions`. Authored bitmap subtitles retain
  their original appearance and placement.

The tvOS simulator regression suite uses a Debug-only capability profile:
H.264 direct play when possible, otherwise a low-bitrate H.264/AAC HLS
rendition. This is necessary because CoreSimulator has no dependable HEVC /
Dolby Vision hardware decoder. Release builds and physical Apple TV runs
always use the full `DeviceProfile.lagoon` profile. Four real-media UI
regressions cover pause/resume, forward/backward scrubbing, subtitle
selection across a seek, rendered subtitle cues, automatic intro skipping,
and audio switching/re-prime. The audio test discovers a server-declared
direct-play H.264 item with multiple tracks so HLS cannot silently collapse
the fixture to one rendition.

## Display mode matching (tvOS, HEL-64)

The custom player must do by hand what AVPlayerViewController does
automatically: ask the display to match the content. The engine publishes
a `DisplayMatchRequest` (the video's tagged `CMFormatDescription` plus
frame rate) once the demuxer knows the stream; `VideoPlayerView` applies
it to a window's `AVDisplayManager.preferredDisplayCriteria`
(`DisplayModeMatcher`) and clears it on exit. Lagoon always submits the
request; the user's tvOS Settings → Video and Audio → Match Content
options remain the authority, and criteria are silently ignored when those
are disabled. The HUD's `Display:` line names every observable layer: the
requested rate, then `no window` / `no manager` (lookup failed — nothing
was applied), `system on/off` (the user setting), and `switched ×N`
counting the system's actual `AVDisplayManagerModeSwitchStart`
notifications — the hard proof a request moved the display. The first
hardware run taught why the layers must be distinguishable: a collapsed
"off" could not say whether matching was disabled or never reached. Do
not require the key window in the lookup — during a fullScreenCover the
key flag isn't guaranteed, and a nil there silently disables the
feature; any window of the scene reaches the screen's manager.

Why this landed on HEL-64: without a mode switch the display idles at
60 Hz in whatever range the UI runs, and the compositor cadence-converts
and tone-maps every video frame. That per-pixel cost is the standing
suspect for the hardware drops that hit full 3840×2160 HDR10 titles
(Resident Evil 2002, Snowden) while a 3840×1600 letterbox encode with the
same codec, range, and bitrate class (Tomorrow War) plays clean — the
comparison that also exonerated decode throughput, Dolby Vision, bitrate,
and the audio path for those titles. Hardware verification now covers both
the original 4K HDR10 failure and Snowden's 610 s stress scene at zero loss
in normal viewer mode. The simulator still has no display modes (`system
match off` there, criteria are a no-op).

## Debug playback HUD

Settings → Debug → Playback HUD: a top-left overlay in the player showing
the negotiated method/container/codecs/range/bitrate plus live engine state
refreshed every 2 s. Ships in **all** builds, TestFlight included — real
Apple TV hardware only ever runs Release; defaults off
(`debug.playbackHUD`, read once at playback start).

HEL-56 adds two live diagnostic lines to that HUD: renderer queue depths +
stall count, and AVFoundation's total/dropped/corrupted frame counters. The
same build emits `PlaybackPerformance` signposts for controller startup,
playback cushion readiness, stalls, dismissal-critical main-actor work, renderer
teardown, demux close, the stopped-report request, and every increase in the
dropped/corrupted-frame counters. Frame-loss events include the delta, playback
position, queue depths, and stall count so a hardware trace can distinguish
decoder pressure from starvation without a screen recording. Capture those
with the Instruments **Points of Interest** template on real Apple TV hardware;
the signposts intentionally ship in Release/TestFlight.

The HUD is itself a SwiftUI layer composited over video. On Snowden's
full-raster 4K stress scene, two otherwise clean hardware windows measured
4–5 presentation drops with the HUD on and zero in two HUD-off repeats.
Use its live values for diagnosis, but use console/signpost output with
`debug.playbackHUD=false` for the final viewer-mode frame-loss verdict.

**Frame droppability is opt-in metadata** (HEL-64, the end of the
4e2ad5f saga): CMSampleBuffer.h — "A frame is considered droppable if
and only if kCMSampleAttachmentKey_IsDependedOnByOthers is present and
set to kCFBooleanFalse." Absent = not droppable. Marking disposable
frames `false` licenses the renderer's *pre-decode* dropper for every
non-reference frame — 67% of the stream on the title that measured
10.7% steady loss at a matched display rate with full queues. The
engine therefore volunteers nothing by default (`IsDependedOnByOthers`
true on reference frames only, absent otherwise); the old marking sits
behind `debug.markDroppableFrames` for the hardware A/B. Never trust a
sim A/B of this: the pre-decode dropper doesn't engage at 60 Hz with
software decode.

## Frame-loss bench (HEL-64)

Measuring frame loss casually produces false positives — HEL-64 retracted
two "fixes" measured across different scenes, positions, and sampling
rates before landing the rule: **compare only the same scene over the same
media-time window, untouched**. Content alone varies loss 3× within one
file. (Also: taking a simulator screenshot forces a render capture and
drops frames — never screenshot during a measurement window.)

Settings → Debug → Frame-Loss Bench encodes that rule in the app: after
every playback start or seek it warms up 10 s of *media time*, measures a
60 s window, then freezes the result into the HUD's `Bench:` line and a
`Bench Result` signpost (dropped/frames/percent, stalls, `aGaps`,
min queue depth, window start, plus two fields Apple's metrics expose
that decide arguments: `optimized` — frames shown via the
direct-display path that bypasses UI compositing, against `frames` —
and `delayMs`, Apple's accumulated display-lateness metric). Touching the transport re-arms it from the
new position — "seek to the scene, hands off, read the number" is the
whole protocol, identical in the simulator and on hardware. Windows are
keyed on position, not wall time, so stalls stretch the run without
diluting the denominator; stalls are reported in the result, not
discarded.

`scripts/framedrop-bench.sh` automates repeated runs in the simulator:
seeds a resume point via the Jellyfin API, launches playback through the
`lagoon://play/{id}` deep link, waits out the window hands-off, and reads
`Bench Result` back — note the simulator has its own log store
(`xcrun simctl spawn <udid> log show`), the host's `log show` sees
nothing. `--set key=bool` flips app defaults between A/B configs. On real
hardware, read the same number off the HUD's Bench line instead.

For scripted device A/Bs, pass `-debug.benchStartSeconds <seconds>` at
launch alongside `-debug.frameLossBench YES`. This pins the engine start
locally so the previous run's Jellyfin progress report cannot advance the
next run into a different scene. The override is ignored unless the bench is
enabled and has no Settings UI; it is diagnostic launch state, not a playback
preference. A device harness that does not already know the item ID can also
pass `-debug.benchSearchTerm <exact title>` and, when titles collide,
`-debug.benchProductionYear <year>`. Lagoon resolves the item through its
existing signed-in Jellyfin client and enters the normal player path.

The bench, the passthrough timeline, and the EL NAL filter are covered by
the `LagoonTests` unit target (`xcodebuild test -scheme Lagoon
-destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'`)
— the first tests in the project, added because this ticket's regressions
(timestamp jitter, bitstream mangling, measurement discipline) are all
pure logic that a simulator pass can't pin down.

Memory is sampled alongside them: the HUD carries a `Memory:` line (footprint
plus remaining headroom from `os_proc_available_memory()`, which reads 0 in the
simulator and reports real headroom on device), and the progress loop emits a
`Playback Memory` signpost every 10 s with both figures and the playback
position. Watch the footprint's *slope*, not its absolute value — a leak is a
straight line that never plateaus, and it is the one playback failure that
leaves no crash trace, because jetsam writes a `JetsamEvent` report instead.
Anything above roughly 0.2 MB/s sustained over a few minutes needs explaining;
see the note under the renderer feed below for the one that shipped.

### Decoded-frame memory ceiling (HEL-109)

The controlled frame-loss bench also samples physical footprint at roughly
1 Hz for the exact warmup-delimited window. `BenchResult` and its signpost now
report `memoryStartMB`, `memoryPeakMB`, `memoryGrowthMB`, and the minimum
jetsam headroom as `minimumAvailableMB`; the HUD freezes the peak and growth in
the `Bench:` line. This is the measurement to record on physical Apple TV for
a 3840×2160 Main 10 HDR title, with the HUD off so the overlay does not alter
the video path. The console line includes the presentation dimensions and
whether the stream used VideoToolbox or libavcodec, making a captured result
self-identifying.

Above roughly 24 MB a frame, the frame *count* stops bounding anything useful
and `DemuxBackpressurePolicy.videoHardLimit` falls back to bytes (HEL-137). The
software path's limit of 42 frames was chosen when it carried SD and HD: at
1080p 10-bit that is 250 MB, but software AV1 reaching 4K made the same 42
frames 1.05 GB of P010 surfaces, in a process jetsam has already killed once at
2100 MB. The budget is `decodedQueueByteBudget`, deliberately set to the
ceiling the hardware-decoded path was already permitted (30 frames of 4K P010,
746 MB), so every configuration measured before this keeps the limit it was
measured with and only 4K software decode is brought back under it. There is a
floor of 8 frames however large a frame gets, because a queue still has to hold
the codec's reorder depth plus a cushion.

The byte arithmetic is pinned separately so the measured process number has
something honest to compare against. A 4:2:0 P010 surface is
`3840 × 2160 × 3 = 24,883,200` bytes (23.73 MiB): luma and half as many chroma
samples, each stored in a 16-bit word. Lagoon's decoded-video soft/hard queue
limits remain 18/30 frames, so the app-visible queue alone is approximately
427/712 MiB at 4K Main 10. VideoToolbox may retain 6–16 reorder surfaces and
the renderer owns another private set, which is why multiplying the queue is
not a process ceiling and why the bench peak—not the estimate—is authoritative.
Do not lower the 18-frame soft cushion from arithmetic alone; it is the reserve
that removed steady 4K presentation loss. If the physical peak leaves too
little headroom, reduce the 30-frame hard limit first and repeat the identical
window.

The renderer feed is kept cheap under high-bitrate load: packet wakeups are
coalesced onto a user-interactive serial pump, and the app-side sample FIFO is
head-indexed/amortized O(1) rather than shifting its whole Swift array for every
frame. The demuxer blocks on condition-driven video/audio high-water marks and
resumes at lower thresholds instead of polling queue counts, and compressed
payloads retain FFmpeg's existing backing buffer (`av_buffer_ref` behind a
`CMBlockBufferCustomBlockSource`) instead of being copied per packet. Decoded
LPCM coalesces into a reused `NSMutableData` that swresample fills in place,
then **is copied** into a CoreMedia-owned block at emit. These optimizations
reduce Lagoon's packet-copying, allocation, scheduling, and ARC overhead;
AVFoundation's hardware decoder remains responsible for codec decode.

**Do not make the LPCM emit zero-copy.** HEL-58 originally handed that
`NSMutableData` to CoreMedia behind a custom block source, and the free
callback never ran: the app leaked the entire decoded audio stream —
~2.2 MB/s on TrueHD 7.1 — and jetsam killed it for `per-process-limit` at
2100 MB partway through a movie, with a `JetsamEvent` report rather than a
crash trace. The copy that bought back is 1.5 MB/s on the demux queue,
roughly 0.03% of a core, and cannot reach the render path: a matched pair of
6.5-minute 4K/TrueHD runs measured 2 dropped frames out of ~9300 either way,
0 stalls, with footprint going 131 → 113 MB fixed versus 225 → 1003 MB
leaking. The compressed video handoff uses the same block-source pattern and
is measured leak-free, so the pattern itself is fine — only the LPCM use of
it regressed. It was isolated by playing one file twice and switching only
the audio track (TrueHD vs AC-3), which holds the video path constant; that
is the fastest way to attribute a playback leak to audio or video.

Player exit is deliberately two-phase (HEL-57). The main actor cancels the
clock/observer and interrupts FFmpeg, then renderer stop/flush, queued sample
release, and renderer removal are serialized on the existing pump queue.
FFmpeg codec/decoder wrappers are released by `FFmpegDemuxer.close()` on the
demux queue. This prevents dismissal from paying for hundreds of queued
media-buffer releases or C decoder destruction. `Sessions/Playing/Stopped`
still reports exactly once from the controller after the engine position is
captured; network reporting never gates UI dismissal.

Release direct-play and direct-stream files use the sparse range buffer
(HEL-86). One custom `AVIOContext` lets libavformat read and seek through a
discardable file under `Library/Caches/Lagoon/Playback`; authenticated HTTP
`Range` misses fill that file and repeated reads are local. The engine first
tries this path, but if the server rejects or ignores byte ranges during open,
it closes the partial context and immediately reopens the original URL through
libavformat's native HTTP transport. A whole-body `200` is rejected before its
body is delivered: pretending it were a range would redownload and discard an
ever-growing prefix for every chunk.

Transcoded HLS stays on native libavformat I/O in Release. Its manifests are
mutable while Jellyfin produces the rendition, so a direct-file completion
model does not apply. The HLS resource-cache experiment remains available only
with `-debug.experimentalPlaybackCache YES`; it leaves `.m3u8` playlists native
and routes immutable segments through bounded custom contexts. This preserves
the segment-boundary regression without putting that experimental ownership in
TestFlight.

The active direct file begins proactive fill only after the initial playback
cushion has reached the renderer. Fill is cooperative rather than one large
background request: the controller advances one 1 MiB chunk at a time, pauses
for four times the measured request duration while video is playing, and
enters a 20-second cooldown whenever buffering or a new stall is observed.
Pause allows full-speed fill; backgrounding cancels proactive work. This
explicit scheduler is required because Apple documents URLSession priority as
a hint rather than a bandwidth guarantee. Foreground cache misses remain high
priority, and proactive requests disallow constrained or expensive paths.

The coordinator preserves 256 MiB of free volume space and permits one half of
the remainder for the current title. A declared resource smaller than that cap
buffers completely and keeps the whole-file scheduler: nothing is evicted, and
proactive fill wraps back to close early holes until the file is contiguous.

A title **larger** than the cap is buffered through a window that travels with
the playhead instead. Filling to the cap and stopping was a cliff, not a
graceful stop: once the playhead reached the filled edge, every read missed,
and because a miss fetched a whole 1 MiB request while storing none of it, one
64 KiB AVIO buffer cost a 1 MiB download and a round trip — sixteen times the
bandwidth and sixteen times the requests, serialized on the demux thread. The
engine's own cushion is only the sample queues (~4 s of compressed video), so
that state was permanent rebuffering roughly an hour into a large movie. The
window keeps `byteLimit / 8` (at most 256 MiB) behind the playhead for ordinary
backwards scrubbing and spends the rest ahead of it, freeing the islands
furthest from the playhead when a request needs room. The reserve is clamped to
what actually exists behind the playhead, so the window is a whole cap's worth
of file wherever it sits: near the start it stays `[0, cap]` and only begins to
slide once the playhead has passed the reserve distance. Without that clamp its
lower half hung off the front of the file and that capacity went unspent — a
viewer who paused a minute in buffered up to 256 MiB less than the cache was
allowed to hold (HEL-99). `preferredPrefetchOffset`
follows every foreground read, so a backwards seek re-centres the window on its
next demux read and the bytes now far *ahead* become the eviction candidates;
anything evicted is simply refetched, because the range set is the sole
authority on what the file may be read for.

Eviction reclaims real blocks with `F_PUNCHHOLE` over the block-aligned
interior of a range, and the cap is checked against `st_blocks` as well as the
range bookkeeping — logical eviction without physical reclaim would let the
file grow past the free-space reserve. If the filesystem refuses to punch, the
scope abandons the window and falls back to a fixed cap, but reads then ask
only for the bytes they were given, so the amplification never returns. For the
same reason the AVIO buffer is sized to the cache's request size: one demux
read is at most one network request even when nothing can be stored.

`debug.playbackCacheCapMB` forces a small cap in DEBUG so the window is
observable within a minute instead of after gigabytes.

The legacy percentage diagnostic reports only the contiguous byte-zero prefix,
which a windowed title drops to 0 as soon as the head is evicted; the scrubber's
islands stay accurate. A sparse file is exposed as a normal local playback URL
only after the complete server-declared byte range has been validated and
synchronized, so a hole can never masquerade as EOF.

The scrubber draws every cached byte island as a middle-opacity layer behind
the solid played range. File-byte fractions are not timeline fractions for
variable-bitrate media, so FFmpeg's video-packet byte positions are paired
with their media timestamps as playback advances; a seek records an initial
cursor anchor before the first post-seek packet arrives. Buffered ranges are
projected piecewise through the latest anchor, keeping the active island
joined to the playhead while preserving 0 and EOF as exact endpoints. The
Playback HUD reports contiguous MiB/total MiB, percentage, hit rate, request
count and latency, while a `Playback Buffer Progress` signpost provides the
same fraction and stall count for Instruments runs.

A failed cache read returns an I/O error, never EOF: EOF is reserved for a
successfully read resource ending. URL loading retries transient failures;
deterministic range incompatibility does not retry because the engine's native
open fallback is both faster and safer. Reaching the disk cap no longer ends
proactive fill for a windowed title — "nothing to fetch" means the read-ahead
is full, so the controller waits for the playhead to make room rather than
giving up on the rest of the movie.

Pausing freezes the window rather than the fill. The demuxer parks on its queue
watermarks, so `preferredPrefetchOffset` stops moving and low-priority prefetch
never advances it; the fill loop meanwhile drops its throttle entirely while
paused, because no foreground demux request is competing for the link. The
result is a full-speed fill up to the window's edge followed by an idle 2 s
poll, and **nothing is evicted**: eviction only runs from a read that is short
of capacity, so an idle cache never trims itself.

Cache ownership is part of the player lifecycle, never an offline-download
feature. There is one active scope and at most one staged successor. Dismissal,
failure, or account/player replacement cancels requests and removes both;
episode advance cancels/removes the old scope and promotes the staged one.
Deletion waits for an in-flight demux read on a utility queue so the main actor
does not inherit file/network teardown. Stale scope directories are discarded
when a new coordinator starts.

The dismissal boundary itself is synchronous: before the full-screen cover
returns to Home or Settings, the controller cancels its clocks and subtitle
work, detaches system media state, marks the engine cancelled, interrupts
FFmpeg, and queues renderer teardown. Only the Jellyfin stopped report remains
asynchronous, and that task carries copied request values rather than retaining
the controller. A replacement player waits up to 15 s for the exact outgoing
engine's demux loop and renderer set to retire. Renderer removal is
asynchronous inside AVFoundation and can exceed the old three-second allowance
after high-resolution playback. A timeout is recorded as `Playback Resource
Retirement Timeout` and aborts the replacement instead of silently overlapping
two media pipelines on one display-layer renderer.

`Playback Lifecycle` signposts record live controllers, engines, demux loops,
renderer sets, unclean engine destructions, and physical footprint at every
ownership transition. The Debug-only accessibility probe exposes the same
counters to `testPlaybackDismissSettingsReplayLifecycleAndStallBenchmark`.
That regression performs the hardware-shaped sequence—play, dismiss, enter
Settings, replay—then requires every cleanup point to reach 0/0/0/0, limits
cleanup-to-cleanup footprint growth to 48 MB, limits replay startup growth to
96 MB, and permits at most one new stall while media time advances at least
10 s in a 15 s CPU/memory/hitch measurement window. It runs three
replay/dismiss cycles by default so smaller per-cycle leaks become a slope
instead of hiding beneath one allocator-noise allowance. Run it with:

```sh
scripts/playback-lifecycle-bench.sh
```

When the Xcode test environment supplies `LAGOON_LIFECYCLE_REPLAYS`, the value
overrides that default and is capped at ten replays.

On a device already signed into Fixture, target the reported software-decoded
fixture instead of the public-demo fallback:

```sh
LAGOON_LIFECYCLE_VC1_SERIES='Rick and Morty' \
  scripts/playback-lifecycle-bench.sh 'platform=tvOS,id=<Apple-TV-UDID>'
```

The resolver walks that series' episodes and chooses one whose Jellyfin
PlaybackInfo actually declares VC-1, so season/file naming changes do not turn
the benchmark into an H.264 test by accident.

`testControlledFrameLossPlaybackPerformance` adds frame presentation to the
automated performance gate. It resolves one playable item, then runs that same
item from the same position three times. Each run leaves the simulator
untouched for a 10-second warmup plus a 60-second media-time window and
requires more than 1,000 frames, no corrupted frames, at most one stall, at
most 1% frame loss, zero enqueued audio gaps, and no more than 0.5 percentage
points of run-to-run spread. On 2026-08-19 the post-fix control produced the
same result in all three windows: 0/1,450 dropped frames, zero corrupted
frames, zero stalls, zero audio gaps, and a minimum video queue depth of 90.
The public demo is sufficient for this H.264 simulator control; the scripted
hardware/Fixture bench remains authoritative for VC-1, HEVC, HDR, and TrueHD.

`testVC1DirectPlayMaintainsContinuousAudioAndVideo` is the dedicated live
legacy-codec gate. It resolves VC-1 by inspecting Rick and Morty's real
PlaybackInfo, requires Direct Play, the sparse direct-file buffer, and local
LPCM audio, then applies the same untouched 60-second presentation window and
dismissal lifecycle assertions. The final tvOS 26.5 simulator run against
Fixture presented 1,445 frames with zero dropped/corrupted frames, zero stalls,
and zero enqueued audio gaps. Footprint was 73.7 MB on initial readiness,
84.7 MB after decoder settling, remained 84.7 MB at the end, and returned to
71.6 MB after dismissal. These numbers are regression evidence, not a physical
Apple TV jetsam threshold; a signed-device run remains the release acceptance
test.

The same final run's measured 15-second lifecycle window used 1.363 s app CPU,
peaked at 107.1 MB, and grew by only 115 KB. All three dismiss/replay cycles
ended with zero live controllers, engines, demuxers, and renderers.

Those allowances are deliberately above simulator allocator noise and below
one retained decoded-video queue. Set Xcode performance baselines from repeated
hardware runs; do not use one simulator's absolute RAM number as an Apple TV
jetsam threshold. For a live secondary check, attach Instruments' Leaks or run
`leaks` during the second window. The lifecycle counters remain the stronger
gate for AVFoundation objects because allocator caching can keep footprint flat
or elevated after the owning engine has gone away.

Stall recovery is bounded as well. An empty Lagoon queue must remain empty for
one second before the engine pauses Apple's shared clock; this prevents one
100 ms scheduling tick from turning a healthy renderer-owned sample into a
visible micro-stall. Normal refill resumes at the demuxer's 12-frame low-water
cushion; if it cannot rebuild that cushion within 5 s, the engine re-primes
audio, video, renderers, and the clock at the current media position. The pure
`StallRecoveryPolicy` unit test makes an accidental return to an infinite
rate-zero polling loop a deterministic failure.

## Progress reporting

Positions are ticks (see jellyfin-api.md). Three report points, all fire-
and-forget (`try?` — reporting must never interrupt playback):

- `Sessions/Playing` once playback starts.
- `Sessions/Playing/Progress` every 10 s from a detached loop, including
  `IsPaused` from the engine.
- `Sessions/Playing/Stopped` exactly once from `stop()` (guarded by
  `didReportStop`), called on dismiss. This is what moves the server-side
  resume point and reorders Continue Watching.

Detail screens re-fetch the item in `fullScreenCover`'s `onDismiss`, and
HomeView re-fetches its Resume/Next Up rails in `onAppear`, so the UI
reflects the new position immediately.

## Putting controls in the transport (tvOS)

The area around the scrubber is the obvious home for shortcut buttons —
subtitles, audio, speed, whatever comes next — and the reference player puts
its buttons exactly there. Before writing one, read this: playback speed was
built there and reverted, and the cost was mostly in rediscovering the
constraints below.

**Nothing in the transport is focusable today, and that is deliberate.** The
overlay sets `allowsHitTesting(false)` on tvOS and the surface owns focus at
all times. `onMoveCommand` lives *on the surface*, so the moment focus leaves
it the arrows stop scrubbing (HEL-63). The skip prompt and the Up Next card are
visible-but-not-focusable for that reason and are driven by Select instead.

**The remote grammar is fully allocated except Up.** Left/right seek or walk
the scrub playhead, down opens the panel, Menu cancels/closes/exits, Play/Pause
toggles. Up (when not scrubbing) is the only free direction, and it is what a
transport control would have to be reached by.

A focusable control there needs *all* of the following, and the first three are
not optional:

1. The overlay must become hit-testable (`allowsHitTesting(transportVisible)`).
2. Focusability must be gated on `transportVisible`, or focus walks into an
   invisible control while the transport is hidden.
3. The four-second auto-hide must not fire while it holds focus, or focus is
   stranded on a control that is then disabled.
4. It needs a way back: down should return `playerFocus = .surface`, because
   the surface must own focus for the arrows to scrub.

### Platform limits found the hard way

These are all verified on device, not inferred:

- **SwiftUI `Menu` never presents inside the player's `fullScreenCover`.** The
  button takes focus and Select does nothing at all — no popup, no error, the
  player keeps playing. Same class of tvOS-26 fullScreenCover gap that
  `MenuPressGate` exists for. Apple's HIG agrees from the other direction: the
  pop-up button, which is the component this would be, is documented as *"Not
  supported in tvOS or watchOS."* A menu has to be built from ordinary buttons.
- **Focusable buttons nested inside another `Button`'s overlay stop taking
  focus entirely.** Anchoring a popup to a button therefore has to be done from
  *outside* it — publish the button's corner with `anchorPreference` and place
  the popup as a sibling.
- **A default tvOS button enforces its own minimum height**, around 66pt.
  Neither a smaller font nor an explicit `.frame(height:)` moves it.
  `.controlSize(.small)` is the only lever short of drawing the focus lozenge
  by hand, which this codebase does not do.
- **Do not ask for `.buttonStyle(.glass)`.** On tvOS, per Apple, "certain
  interface elements, like image views and buttons, adopt Liquid Glass **when
  they gain focus**" — a plain button already becomes glass at the moment it
  should. Asking for it makes every option permanently glass, against "use
  Liquid Glass effects sparingly … limit these effects to the most important
  functional elements". It also tints the label with the accent, which is
  white, so on a bright backdrop the labels disappear into their own pills.
  That is exactly how the first speed control shipped, and it is why the panel
  rows are plain buttons.

## Player view gotchas (learned the hard way on tvOS)

- The custom player UI (`CustomPlayerView`) talks **only to the
  `PlayerEngine` protocol** — engine internals must never leak into it.
- Focus invariants: the video surface is focusable at **all** times (Menu
  would quit the app from an unfocusable screen).
- **Scrub grammar** (HEL-39 slice 2, reworked in HEL-55): tvOS arrows walk
  a virtual playhead (`scrubTarget`) **whenever the duration is known** —
  playing or paused alike. Scrub used to additionally require
  `engine.isPaused`, which meant trickplay, chapter ticks and chapter hops
  existed but were unreachable unless you guessed you had to pause first;
  that gate is the whole of HEL-55, and the reason slices 2/3 sat unverified.
  Only a live stream (`duration == 0`) still falls back to blind ±10 s seeks
  with the glyph indicator.
  - **Playback keeps running** behind the chip. Nothing to restore on
    cancel, and no pause/resume round-trip through the synchronizer on every
    small skip. So on tvOS the *fill* keeps showing the live position while
    the *knob* walks ahead — which is why `fillMotion` stays on `liveMotion`
    there and never takes the scrub curve; easing the fill per position
    update would stutter the glide. Touch is the reverse: the fill is what
    the thumb drags, so it takes the scrub curve.
  - **A lone press is still a 10 s skip.** The scrub lands itself after
    `ScrubMetrics.runExpiry` + `ScrubMetrics.selfCommit` (600 + 600 ms) of
    quiet, so a single nudge previews the frame and then commits without a
    Select. Both constants are hardware-tuning knobs — too short and the
    preview can't be read, too long and a nudge feels stuck.
  - Select/Play commits *and plays on* (the native tvOS grammar); the
    self-commit timeout and iOS drags keep whatever the play state was.
    Menu cancels back to the live position, so it outranks close-the-panel
    in `MenuPressGate`'s policy.
  - Sustained walking accelerates 10 → 30 → 60 s. Mid-scrub, up/down hop
    chapters (slice 3) — everywhere else down still opens the panel, which
    is why the hop is scoped to scrub mode: opening the panel mid-scrub
    would strand the virtual playhead behind it. Backwards hops land on the
    current chapter's start first, the way track skip-back does.
  - Chapter ticks stay unlabelled deliberately: a feature film reports ~25
    of them, and 25 captions along a TV-width bar collide into noise. The
    chip names the chapter under the playhead instead, which is now
    reachable without pausing.
  - iOS instead drags the bar directly and seeks on release only — seeking
    per drag update would flush the renderers and re-demux on every frame of
    the gesture.
- **Skip intro/recap** (HEL-63): `GET MediaSegments/{itemId}` — **native to
  Jellyfin 10.10+**, so no plugin-specific client code even though a plugin
  (Intro Skipper) is what populates it. Ticks as usual. `includeSegmentTypes`
  wants *repeated* query params and 400s on a comma-joined list, so the
  filtering is done client-side instead.
  - Only `Intro` and `Recap` are skippable. `Preview` and `Commercial` turn
    up mid-film in real libraries — one sampled movie carries two
    `Commercial` segments — and acting on them would raise a skip prompt in
    the middle of a film. `Outro` is left alone too: the end of an episode
    is a hand-off to the next one, not something to jump.
  - Real data breaks the obvious assumptions: episodes carry **two `Intro`
    segments** more than occasionally, and an `Intro` can start at tick 0.
    Both are handled; don't "simplify" to first-of-each.
  - Three modes in Settings (`SkipMode`): auto-after-delay (default, 5 s
    fill then commits, Menu cancels), instant, and ask-every-time.
  - **The button is deliberately not focusable.** Taking focus would move
    `onMoveCommand` off the video surface and kill scrubbing while it is up,
    so it extends the existing priority chains instead — Select commits a
    scrub, else skips, else toggles pause; Menu cancels a scrub, else waves
    off a pending auto-skip, else closes the panel, else exits.
    On iOS the visible pill handles a direct tap because there is no remote
    Select gesture to route through the video surface.
  - `handledSegmentIDs` marks a segment before seeking. Without that, landing
    near the segment end puts the playhead back inside it and re-arms the
    whole thing.
- **Autoplay the next episode** (HEL-66): the credits hand off to the next
  episode inside the same player — `PlaybackController.playNextEpisode()`
  reports the finished episode stopped, resets its one-shot state, then
  starts the next one. Three modes in Settings (`AutoplayMode`): automatic
  (default), ask-every-time, off. The countdown is 5 s, the same as
  `SkipMode`'s — two countdowns in one player running at different speeds
  read as a bug.
  - HEL-86 keeps both the full-screen player and its UIKit-backed
    `AVSampleBufferDisplayLayer` mounted through that handoff. Within the last
    120 s, the controller negotiates the next PlaybackInfo and warms up to the
    first 8 MiB of a direct-file successor in a second bounded scope. Warmup
    uses the same one-chunk cooperative scheduler and supersedes active-title
    proactive fill, so credits never carry two competing downloads. Advance
    first reports the old session stopped and retires its demuxer/render
    synchronizer; only after the
    lifecycle counters reach zero does `SampleBufferVideoSurface.updateUIView`
    attach the successor engine to the same display layer. The old final frame
    remains beneath a non-focusable "Starting next episode" overlay instead of
    flashing the presenting screen. PiP swaps its transport delegate while
    retaining the same content source, and audio-session, Now Playing, and
    tvOS display-match ownership remain active across the boundary. There are
    never two demux/render pipelines alive together; seamless here means a
    persistent surface and pre-negotiated playback, not overlapping decoders.
  - An `Episode Handoff` signpost measures viewer action/automatic advance to
    the successor's primed presentation clock. The same duration appears in
    the Playback HUD and the launch-gated UI-test probe. The hardware journey
    starts a real episode near its end, selects the production Up Next card,
    and injects a seven-second renderer-retirement delay to model slow Apple TV
    decoder teardown. It asserts the surface never disappears, requires one
    engine/demuxer/renderer set after the successor becomes ready, then keeps
    episode two running for 20 seconds with media-clock, stall, buffering, and
    memory-growth ceilings. Native HLS and buffered direct-play journeys assert
    their negotiated mode and transport ownership, cross sustained playback
    windows, and enforce the same single-pipeline invariants. Direct journeys
    additionally require the published contiguous buffer fraction never to
    regress. A separate DEBUG-opted-in cached-HLS journey keeps the
    experimental boundary covered; buffered direct-stream has a fixture-
    conditional sustained journey too.
  - **Never resolve the next episode from `Shows/NextUp`.** That endpoint
    returns the episode *in progress* when there is one — `enableResumable`
    defaults to `true`, per the server's own OpenAPI document — and at the
    moment an episode finishes its stop report has not landed yet. NextUp
    therefore hands back the episode that just ended, and autoplay loops on
    it forever. `episodeAfter(_:)` uses
    `Shows/{seriesId}/Episodes?startItemId=<current>&Limit=2` instead:
    index 1 is the next episode, it doesn't depend on watch state at all,
    and naming no season is what carries a binge across a season boundary.
    It also guards that item 0 *is* the anchor — a mismatch means the
    server never found it and started from the top of the series, and
    rolling into episode 1 is far worse than doing nothing.
  - **Two anchors, not one.** The card appears at the `Outro` segment's
    start when the server marked one, and the countdown runs from there —
    that is the whole point, cutting the credits short. With no outro there
    is nothing to say where the episode stops being the episode, so the
    card appears on a fixed 15 s run-out but the *fill* is pinned to the
    last 5 s of the file. Collapsing these into one anchor would either
    hide the card until it was useless or eat content nobody called credits.
  - **Track selection carries into the next episode**, matched by language
    and title rather than by ordinal. Two episodes of one show usually
    share a stream layout, and "usually" is not "always" — a commentary
    track on one episode would shift every choice below it and hand over
    the wrong language. Subtitles-off is carried as a choice of its own, or
    the next episode reinstates the server default. External sidecars stay
    paired with their streams while the list is built: one whose URL won't
    resolve is dropped from what the engine gets, so it has to leave the
    stream list too or every ordinal past it names the wrong track.
  - **A cancel has to outlive the card.** Back sets `nextUpDismissed`, but
    the file still has its credits to run, and `didFinish` then arrives and
    autoplays over the "no" — verified happening, and fixed by plumbing
    `onCancelNextUp` up to `VideoPlayerView`, which holds the flag until
    the next episode actually starts. `didFinish` still advances when
    nothing was cancelled: with no outro the countdown and the end of the
    file land within a frame of each other, and `playNextEpisode` is
    guarded (`isAdvancing`) against being taken up on it twice.
  - The card is **not focusable**, same trap and same fix as the skip pill:
    it extends the Select and Menu priority chains instead. It sits on the
    same bottom-trailing shelf, which is free because intros and recaps
    live at the front of an episode and credits at the back.
  - Its background is `.regularMaterial`, not a black wash. Credits are
    white text on black and at *any* opacity a flat scrim lets them through
    the card as readable letters; blurring is what actually stops it.
- **Trickplay** (slice 3, Jellyfin 10.9+): `BaseItemDto.Trickplay` is
  `[mediaSourceId: [width: TrickplayInfo]]`, and its `Interval` is
  **milliseconds**. Sheets come from `Videos/{id}/Trickplay/{width}/{n}.jpg`
  — one sprite sheet per `TileWidth × TileHeight` grid of thumbnails, so
  the default 10×10 at 10 s covers ~16 minutes each. Two gotchas: unlike
  `Items/…/Images/…` this route **401s without credentials**, so the URL
  carries `api_key` the way stream URLs do; and a sheet is ~23 MB decoded,
  which is why `TrickplayLoader` holds its own two rather than going
  through `ImageCache` (one scrub would evict every poster). Tile crops are
  derived from the *decoded* sheet's size, never the declared numbers — the
  decode caps sheets at 3200 px, and the last sheet of a film is only
  partially filled, so its height isn't `rows` tiles.
- Chapters and trickplay are fetched by the player itself
  (`playbackExtras`, concurrent with the PlaybackInfo negotiation), not
  taken from the `MediaItem` it was handed: playback starts from rails too,
  and their list requests don't carry those fields. Both degrade to
  nothing — no ticks, no preview — on servers that never generated them.
- A faded-out overlay **still hit-tests**: the transport gates
  `allowsHitTesting` on its own visibility, or the invisible iOS scrubber
  swallows drags meant for the video. tvOS keeps the whole transport
  non-hit-testable — Select goes to the focused surface, and anything else
  down there steals it.
- **SwiftUI's `onExitCommand` never fires inside a fullScreenCover on
  tvOS 26** — arrows and play/pause reach SwiftUI, but UIKit's
  presentation controller consumes Menu and dismisses the cover directly,
  and `interactiveDismissDisabled` doesn't gate it (verified with
  instrumented handlers). `MenuPressGate` owns the policy: panel open →
  close panel, else → explicit dismiss. **It needs BOTH interception
  layers**: a real Siri Remote `.menu` press is eaten by UIKit's
  dismissal *gesture recognizer* before press delivery reaches any
  responder — only our own `UITapGestureRecognizer` with
  `allowedPressTypes = [.menu]` inside the hierarchy preempts it (found
  on hardware: responder-chain overrides alone let Menu kill the whole
  player) — while the simulator's keyboard Escape arrives as a keyboard
  press (type = 2000 + HID usage, never `.menu`) that no recognizer
  matches, so the `pressesEnded` override must catch
  `key?.keyCode == .keyboardEscape`. Sim-only testing exercises only the
  second path; hardware exercises only the first.
- `defaultFocus` is only honored when a fresh scene appears — any
  mid-screen reveal must assign its `@FocusState` programmatically
  (immediately, plus a settled retry) or focus strands.
- **Nothing that *appears* inside the player can animate — animate values
  instead.** The animation transaction doesn't survive the `MenuPressGate`
  hosting boundary (state lives outside the `UIHostingController`, updates
  cross via `rootView` reassignment), so `withAnimation` lands instantly.
  Value-driven `.animation(_, value:)` in the hosted tree *does* work, which
  covers opacity, offset, and asymmetric timing via a target-state-conditional
  animation argument.
  **Transitions are the trap**: `.transition()` on a conditionally-inserted
  view has no value to hang an animation on at the moment of insertion, so it
  never runs no matter how it's wrapped. Two fixes were tried and *both
  failed* — `.animation(_, value:)` on a `Group` around the `if` (2026-08-17,
  believed fixed but wasn't), and forwarding `context.transaction` around the
  `rootView` assignment. Frame-by-frame capture settled it: the panel still
  appeared whole between two frames 0.04 s apart. The panel now stays mounted
  permanently and slides via `.offset` + `.opacity`, `.disabled(!panelOpen)`
  keeping its buttons out of the focus engine while closed.
  **Verify animations by recording, not screenshots**: `simctl io recordVideo`
  then step frames out with `AVAssetImageGenerator` — a screenshot lands after
  the animation has finished and tells you nothing.
- Never nest `SharedState.withLock` (non-recursive lock — nesting was the
  engine's first real deadlock). `sample <pid>` on the host names the
  exact stuck line when a queue wedges.
- Native buttons only; never draw custom chrome tied to focus — the system
  lozenge is the design (see the Infuse reference on HEL-35).
- On failure the engine is set to **nil** and replaced with an error
  overlay carrying a Back button and `.onExitCommand` — a dead surface
  would swallow the Menu press and trap the user.
- The loading state is `LoadingView` (focusable) for the same Menu-button
  reason as everywhere else.
- tvOS does not restore focus to the presenting screen after the player
  cover dismisses (custom focusable content inside) — every screen that
  presents the player wraps in `.restoresFocusAfterPlayer(isPresented:)`
  (`FocusRestoration.swift`: focus scope + `resetFocus` timed past the
  dismissal transition).
