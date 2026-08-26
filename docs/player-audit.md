# Lagoon player audit — codec coverage and performance

Audit date: August 27, 2026. Commit `ba40300`, version `0.1` build `62`.

Scope: the ~16,700 lines under `Lagoon/Views/Player` and
`Lagoon/Views/Player/SampleBuffer`, plus `Networking/DeviceProfile.swift` and
`Networking/PlaybackCapabilities.swift`.

**Method, and its limit.** This is a static reading of the code against
`docs/playback.md`. Nothing here was measured on hardware. Every performance
item below is a hypothesis with a named way to test it, never a result —
CLAUDE.md's rule about casual frame-loss comparison applies to all of them,
and HEL-64 already retracted two fixes that skipped it.

## How the pipeline routes, in one paragraph

`DeviceProfile.everything` is the envelope the engine can play;
`DeviceProfile.lagoon` is that envelope minus what the running hardware cannot
decode. Video takes one of three paths: H.264 reaches
`AVSampleBufferVideoRenderer` still compressed; HEVC and AV1 with hardware
support are decoded ahead through `VideoToolboxDecoder` into IOSurface-backed
frames; VC-1, WMV3, MPEG-4 Part 2, MPEG-2, VP9 and AV1-without-hardware go to
`SoftwareVideoDecoder` on the CPU. Audio splits two ways: AAC, MP3, AC-3 and
E-AC-3 stay compressed as passthrough, everything else is decoded to LPCM by
`AudioDecoder`. That last class matters for what follows, because
`AudioDecoder` calls `avcodec_find_decoder` generically
(`AudioDecoder.swift:47`) — it can decode anything in the build, so its
coverage is bounded only by what the profile advertises.

## Codec coverage

### A. Already decodable, never advertised

These need no new decoding capability. The engine handles them today and the
server is simply never told, so every such file takes an unnecessary
server-side transcode.

| Format | Decoder | In the profile? | Cost today |
| --- | --- | --- | --- |
| **WMV3 / WMV9** | `SoftwareVideoDecoder.swift:79` lists `AV_CODEC_ID_WMV3` | **No** — zero occurrences of `wmv3` in `DeviceProfile.swift` | Full video transcode |
| **MP2 audio** | `AudioDecoder` is generic | **No** | Audio transcode |
| **ALAC in video containers** | `AudioDecoder` is generic | Only on the `m4a,m4b` *audio* profile | Audio transcode |

WMV3 is the standout. It is the same bitstream family as VC-1, it rides the
identical code path, and VC-1 *is* advertised (SDR, 8-bit, ≤1080p, progressive).
Adding `wmv3` alongside it is close to a one-line change with an existing
tested decoder behind it — the best benefit-to-risk ratio in this audit.

MP2 matters more than its obscurity suggests: `mpg`, `mpeg`, `ts`, `mpegts`
and `vob` are all advertised containers, and MPEG Layer II is precisely what
lives in them. DVD rips and DVB recordings currently transcode their audio for
no reason.

**Verify before acting.** `Packages/LagoonFFmpeg/Package.swift` points at
remote MPVKit 1.0.0 binary artifacts that were not resolved locally, so
decoder presence here is inferred from these being standard FFmpeg decoders,
not confirmed by symbol. Check the pinned build before advertising anything.

### B. Genuine gaps

4. **Interlaced content, all of it.** Every entry in `codecProfiles` carries an
   `IsInterlaced` condition, so interlaced media always goes to the server.
   There is no local deinterlacer, and `docs/playback.md:401` records that the
   demuxer has no bitstream-filter plumbing at all — so this is a real
   architectural addition (a filter-graph stage), not a profile edit. It is
   also the largest category still transcoding, and the gap that most
   separates Lagoon from Infuse.

5. **VP8.** `webm` is an advertised container, but VP8 appears in neither
   `SoftwareVideoDecoder.supports` nor the codec list.

6. **MPEG-1 video.** `.mpg`/`.mpeg` are advertised and `mpeg2video` is
   supported; `mpeg1video` is not.

7. **4:2:2 and 4:4:4 chroma.** `SoftwareVideoDecoder` accepts only
   `YUV420P`, `YUVJ420P`, `NV12`, `YUV420P10LE` and `P010LE`
   (`SoftwareVideoDecoder.swift:264-270`). Any 4:2:2 source transcodes
   whatever its codec.

### C. Correctly out of scope — do not revisit

- TrueHD Atmos objects and DTS:X reduced to multichannel LPCM. Platform limit,
  documented, matches what Infuse does.
- Dual-layer Dolby Vision profile 7 played as its HDR10 base layer. The
  reasoning in `DeviceProfile.swift` is sound: tvOS cannot reconstruct
  dual-layer, so direct play beats a lossy server re-encode to the same
  ceiling.
- Full libass parity. Explicitly scoped out at `Subtitles.swift:52`.

### D. Dead weight

`uavs3d` — an AVS3 decoder — ships in the linked xcframework set per
CLAUDE.md, but `avs3` appears nowhere in the app: not in
`SoftwareVideoDecoder.supports`, not in the profile. It is binary size for
nothing. Either wire it up or establish whether the artifact set can drop it.

## Performance

### 1. Queue limits are frame counts; memory is measured in bytes

`DemuxBackpressurePolicy.videoHardLimit` returns 30, 42 or 120 purely from
which decode path is in use, with no reference to surface size. The same 30
means roughly **93 MB** of 1080p SDR NV12 surfaces and roughly **712 MB** of
4K Main 10 P010 — a 7.6× spread behind one constant.

The cost itself is not news: `docs/playback.md:895-905` already does this
arithmetic and lands on 427/712 MiB for the 18/30 soft/hard pair. What is
missing is any code that *adapts*. A single frame count is either chosen for
the worst case and overpaid at every lower resolution, or chosen for the
common case and unsafe at 4K HDR.

Shape: derive the hard limit from a byte budget and the real surface size
rather than a frame count. Respect `playback.md:902` — do not lower the
18-frame soft cushion from arithmetic alone, it is the reserve that removed
steady 4K presentation loss.

### 2. There is a real OOM kill sitting in the repo

`docs/JetsamEvent-2026-08-17-215656.ips` records Lagoon killed while frontmost
on tvOS 26.6 at **134,404 pages ≈ 2.1 GB**.

Caveat that matters: it is dated 2026-08-17, the same day MPVKit left the
project, so it may describe the old engine rather than the current one.
Worth settling, because it is the only hard ceiling datum in the repo and
`playback.md:1124` explicitly warns against substituting a simulator number
for one.

### 3. The documented remedy currently makes HEL-124 worse

`playback.md:903` advises that if physical headroom is short, "reduce the
30-frame hard limit first". But 30 is exactly the threshold that pins the
demux loop into one-read-per-dequeue pacing once the audio queue empties
(HEL-124). Lowering it tightens that trap.

Order matters here: **HEL-124 before any hard-limit reduction.**

### 4. Already tracked

- Unconditional `maxStreamingBitrate: 120_000_000` → HEL-108.
- Decoded-frame memory ceiling at 4K HDR → HEL-109.

### 5. Not a concern

The 512 MB playback cache is disk-backed (`PlaybackCache.swift:713`, `:745`),
so it does not compete with the surface budget.

## Suggested order

1. **HEL-123** — audio silently dropped. User-visible today.
2. **HEL-124** — backpressure trap. Blocks the memory work below.
3. **Advertise WMV3, MP2, ALAC.** Small, verifiable, existing decoders.
4. **Byte-derived video queue limit.** Needs HEL-124 first.
5. **Deinterlacing.** Large, and the real competitive gap.

Items 1 and 2 are bugs in shipped behaviour. Items 3 through 5 are the player
getting better rather than getting fixed, and none of them should start before
1 and 2 are closed.
