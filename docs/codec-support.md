# Codec support

**Generated file. Do not edit.** Run `scripts/generate-codec-support.sh`
after changing `DeviceProfile`.

This is the capability profile Lagoon sends Jellyfin with every
`PlaybackInfo` request. The server decides direct play against exactly
this and nothing else, so what is listed here is what actually plays
without a re-encode.

Support is conditional, not a flat list. A codec appears below with the
profiles, ranges and limits that go with it, because "everything direct
plays" is never true and the conditions are where the real answer is.

The reasoning behind each decision is in the engine's [codec
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/codecs.md).

## Containers

**Video** — `mkv`, `webm`, `mp4`, `m4v`, `mov`, `avi`, `mpg`, `mpeg`, `ts`, `mpegts`, `m2ts`, `vob`

**Audio** — `mp3`; `m4a`, `m4b` (`aac`, `alac`); `flac`

## Video codecs

| Codec | Conditions |
| --- | --- |
| `hevc` | Video profile one of `main`, `main 10`; Video range type one of `SDR`, `HDR10`, `HLG`, `DOVI`, `DOVIWithHDR10`, `DOVIWithHDR10Plus`, `DOVIWithHLG`, `DOVIWithSDR`, `DOVIWithEL`, `DOVIWithELHDR10Plus`, `HDR10Plus`; Video level at most `183`; Is interlaced is not `true` |
| `h264` | Video profile one of `high`, `main`, `baseline`, `constrained baseline`; Video range type one of `SDR`; Video level at most `52` |
| `av1` | Video profile one of `main`; Video range type one of `SDR`, `HDR10`, `HLG`, `HDR10Plus`; Video bit depth at most `10`; Is interlaced is not `true` |
| `vp9` | Video profile one of `profile 0`, `profile 2`; Video range type one of `SDR`, `HDR10`, `HLG`, `HDR10Plus`; Video bit depth at most `10`; Width at most `1920`; Height at most `1080`; Is interlaced is not `true` |
| `vc1` | Video range type one of `SDR`; Video bit depth at most `8`; Width at most `1920`; Height at most `1080`; Is interlaced is not `true` |
| `wmv3` | Video range type one of `SDR`; Video bit depth at most `8`; Width at most `1920`; Height at most `1080`; Is interlaced is not `true` |
| `mpeg4` | Video range type one of `SDR`; Video bit depth at most `8`; Width at most `1920`; Height at most `1080`; Is interlaced is not `true` |
| `mpeg2video` | Video range type one of `SDR`; Video bit depth at most `8`; Width at most `1920`; Height at most `1080` |

## Audio tracks in a video file

Some of these are passed through untouched and some Lagoon decodes
itself before handing the result to the renderer. Either way the
video is never re-encoded, which is what direct play means here.
Which is which is in the reference note linked above.

`aac`, `mp3`, `mp2`, `ac3`, `eac3`, `dts`, `truehd`, `flac`, `alac`, `opus`, `vorbis`, `pcm_s16le`, `pcm_s24le`, `pcm_s32le`, `pcm_f32le`, `pcm_f64le`, `pcm_s16be`, `pcm_s24be`, `pcm_s32be`, `pcm_f32be`, `pcm_f64be`, `pcm_bluray`, `pcm_dvd`

## When direct play is not possible

The server re-encodes and Lagoon plays the result. This is the only rung
where the picture is not the original file.

- **Video** over `hls` in `mp4` segments: video `hevc`, `h264`, audio `eac3`, `ac3`, `aac`, up to 8 channels

## Subtitles

- **Embedded in the file, decoded by Lagoon** — `subrip`, `srt`, `ass`, `ssa`, `mov_text`, `webvtt`, `vtt`, `pgssub`, `pgs`, `dvdsub`, `dvbsub`
- **Sidecar files** — `vtt`
- **Delivered with an HLS transcode** — `vtt`

## Reading this table

A codec listed here still needs its container listed too, and a stream
that fails any condition is transcoded rather than refused. Conditions
marked on the profile as not required pass when the server could not
probe the property, which is why an unusual file sometimes direct plays
where the table suggests it might not.

Video level is the codec's own `level_idc` rather than the number people
quote. Divide by 30 for HEVC, so `183` is level 6.1; divide by 10 for
H.264, so `52` is level 5.2.
