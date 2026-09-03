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

**Since this audit** (updated September 2, 2026). The findings
below are left exactly as they were written; this says which of them moved.

* **B4, interlaced content** — half closed. MPEG-2 deinterlaces locally as of
  HEL-127 and its `IsInterlaced` guard is out of the profile; every codec that
  decodes in hardware still goes to the server. The audit's inference that
  this needed a filter-graph stage did not hold: libavfilter is not in the
  pinned build, and `Deinterlacer` does yadif's spatial pass directly on the
  decoded planes instead, at 1.61 ms per frame at 720x576.
* **Order item 1, HEL-123** — the renderer-side signal ships in Release
  and passed its hardware pass on 2026-09-03: direct-play lead sits at
  1.9–2.2 s, the injected hold takes it below zero and counts one `aDry`,
  the hold is audibly silent with the picture moving and sound returns in
  sync, and the switched-off buffering mode stalls and resumes in place. The
  default stays off, because the same pass found the symptom this ticket
  was filed on is alive on every HLS rung (item 2). The earlier reading,
  that the WALL·E cutouts were the server rebuilding a Blu-ray image below
  real time, was wrong in its cause and right in its cure: HEL-133 moved
  the title off the HLS path, which is what stopped them.
* **Order item 2, HEL-124** — closed as invalid on 2026-09-02, reopened
  and fixed on 2026-09-03. The `A 0` premise was indeed the wrong queue,
  but the mechanism it described is real on HLS: each fMP4 fragment
  carries its video block before its audio block, libavformat emits them
  in that order from a non-seekable stream, and the 30-frame decoded video
  limit with one-slot pacing delivered a fragment's audio roughly a
  fragment late (transcode rung: lead sawtoothing +1…−1.2 s, 22 dry
  episodes in 70 s; remux rung: −7 s, 13). The fix is a compressed video
  intake in front of every decoder, read into whenever the decoded queue is
  full and bounded by the audio high water and its own limits, drained by
  the video pump; see docs/playback.md for the two hardware lessons that
  shaped it.
* **Not in this audit at all: disc images.** Lagoon could not open one when
  this was written, and the resulting failure was being read as a transcode
  problem rather than as the client never having been in the path. See *Disc
  images* in `docs/playback.md`.

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
