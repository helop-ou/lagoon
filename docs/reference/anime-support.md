# Anime support

What anime viewers expect from a Jellyfin client, how Lagoon measures up, and
the order in which to close the gaps. This is a research note written on
2026-09-28 against app `main` and engine 1.0.12, and the code may have moved
on since. Line references are to that revision.

## What anime libraries lean on

Anime differs from the rest of a typical library in four ways. Each one
drives recurring complaints about other clients:

- **Styled ASS/SSA subtitles.** Fansub and many official releases ship ASS
  with named styles, positioned signs, karaoke for openings and endings, and
  fonts embedded in the MKV as attachments. Clients that flatten ASS to plain
  text lose the signs and the look. The official Android app strips the
  styling in its "ASS compatibility" mode, or else transcodes and burns the
  subtitles in. Swiftfin's AVPlayer path had no styled ASS as of early 2026.
- **Japanese audio with subtitles in the viewer's language** as the default,
  with the choice remembered across a series. Separate "signs & songs" tracks
  are common.
- **Episode numbering.** Long runners (One Piece, Naruto, Detective Conan) are
  watched in absolute order. Specials belong between particular episodes
  (`AirsBeforeSeasonNumber`/`AirsBeforeEpisodeNumber`), and double episodes
  carry `IndexNumberEnd`. Jellyfin's own absolute-order support is uneven.
  The server bugs are upstream, but the client must not add to them.
- **Opening and ending skipping**, now provided through Jellyfin's
  `MediaSegments` (intro-skipper plugins publish Intro and Outro segments).

Older releases add **10-bit H.264 (Hi10P)**, which no Apple hardware decoder
handles, and mixed-cadence video (a 29.97 OP in a 23.976 episode).

## Where Lagoon stands

| Need | State | Evidence |
| --- | --- | --- |
| ASS styling | Partial | The engine renders a signs-and-dialogue subset: `\an`, `\pos`, `\b`, `\i`, `\c`/`\1c`, `\r`, scaled from `PlayResX/Y` (engine `Subtitles/Subtitles.swift:284`, `:379-411`). Named `[V4+ Styles]`, `\fn`/`\fs`, karaoke, `\move`, `\fad`, `\clip`, borders and rotation are ignored. There is no libass (engine `scripts/build-ffmpeg.py:84`). Text uses the viewer's caption font (`PlayerSubtitleOverlay.swift`). `\p1` drawings are not recognised, so a drawn sign would likely show as path text (inferred, not observed) |
| Sidecar `.ass` | Degraded | `DeviceProfile` asks for external subtitles as `vtt` only (`DeviceProfile.swift:244-250`). A sidecar ASS arrives converted, with its tags stripped |
| Embedded fonts | Not supported | No attachment streams are read and no fonts are registered, in either repository |
| PGS / image subtitles | Supported | Bitmaps are drawn on the video plane (engine `SubtitleDecoder.swift:78-79`) |
| Japanese audio + subtitles | Supported | "Original Audio" uses the stream's `IsOriginal` first, then the item's `OriginalLanguage` (`TrackPreferences.swift:14`, `:167-176`). Smart subtitles show full subtitles when the audio isn't in a preferred language (`:204-218`). Choices are remembered per series (`SubtitleTrackMemory.swift`) |
| Signs & songs tracks | Partial | Recognised only through `IsForced`, never by track title |
| Hi10P H.264 | Transcoded | The H.264 profile condition allows only `high\|main\|baseline\|constrained baseline` (`DeviceProfile.swift:126-132`), so Jellyfin transcodes Hi10P. The engine would send a Hi10P stream that slipped through to VideoToolbox, because software H.264 is used only for interlaced streams (engine `SoftwareVideoDecoder.swift:280`), even though that path handles 10-bit |
| Absolute order, specials placement | Server's order | Seasons and episodes are shown exactly as `Shows/{id}/Seasons` and `…/Episodes` return them. Nothing reads `DisplayOrder`, `AirsBefore*` or `IndexNumberEnd`. Specials appear as season 0 and are labelled `S0 E1` (`MediaCards.swift:508`). A double episode shows only its first number |
| OP skip | Supported | `MediaSegments` Intro and Recap, skipped automatically, instantly or on request (`SkipMode.swift`) |
| ED skip | Partial | An Outro segment only moves the Up Next card earlier (`PlaybackAutomation.swift:206-207`). There is no Skip Credits for a mid-episode ending followed by a post-credits scene |
| Chapters | Supported | Ticks and names on the scrub bar, with Up and Down jumping between them. Chapters named Opening or Ending are not used for skipping |
| Frame-rate matching | One rate per title | Match Content uses the stream's guessed rate, with the Matroska 23.976 fix. A VFR stamp re-anchors the frame grid rather than switching the display rate |
| Original title | Not shown | `MediaItem` has no `OriginalTitle`; only the Seerr models carry one |

## Recommendations, in order

1. **Styled ASS through libass in the engine.** This is the one gap every
   anime viewer notices, and the one that makes other Apple clients
   unattractive. libass (ISC licence) with its FreeType, FriBidi and HarfBuzz
   dependencies renders into bitmaps, which the engine already composites
   for PGS. The work includes reading MKV font attachments and handing them
   to libass. It needs an engine ticket, a licence and acknowledgement
   entry, and a measurement of karaoke-heavy openings on the Apple TV
   (rendering cost per frame, and HDR subtitle brightness, which PGS already
   handles). Until then, the subset renderer is the right fallback.
2. **Ask for sidecar ASS as ASS**, so external `.ass` files keep their
   positioning with today's subset instead of being flattened to VTT. This is
   a small `DeviceProfile` change plus a check that the external fetch path
   parses ASS.
3. **Skip Credits from Outro segments** when the segment ends before the end
   of the file, because anime often has a post-credits scene. This reuses the
   intro skip prompt.
4. **Specials and double episodes on the series page.** Label season 0 as
   "Special" rather than `S0`, show `E1–2` from `IndexNumberEnd`, and, when
   the server puts specials inline (Jellyfin's "display specials within
   seasons"), keep its order instead of assuming numeric order. Check whether
   the Episodes query needs `Fields=SpecialEpisodeNumbers`/`AirsBefore*`.
5. **Hi10P in software on direct play.** This is only worth doing if
   transcoding Hi10P proves a real problem. Route High 10 H.264 to the
   existing software path, which already handles 10-bit, and add
   `high 10` to the profile once measured on the A15. Most modern anime
   ships HEVC or 8-bit H.264, so this is low priority.
6. **Signs & songs by title** as a fallback when `IsForced` is missing:
   "Signs", "Songs", "S&S". This is small and fits the existing Smart mode.

Absolute numbering is not on this list. It is a server-side display order,
and Lagoon shows whatever order the server returns. The failures users
report are metadata-plugin bugs, not client ones.

## Testing

jaflix has little anime. A useful fixture set is small MKVs with:

- an ASS track using named styles, `\pos` signs and `\k` karaoke, plus an
  embedded font;
- a sidecar `.ass`;
- a Hi10P H.264 encode;
- a series with specials placed by `AirsBeforeSeasonNumber`;
- a double episode.

FFmpeg can generate all of them locally, the same way as the interlaced
H.264 fixtures.

Sources: Jellyfin issues
[#14708](https://github.com/jellyfin/jellyfin/issues/14708),
[#13914](https://github.com/jellyfin/jellyfin/issues/13914),
[#3062](https://github.com/jellyfin/jellyfin/issues/3062); tvdb plugin
[#91](https://github.com/jellyfin/jellyfin-plugin-tvdb/issues/91); Android
[#1833](https://github.com/jellyfin/jellyfin-android/issues/1833); Swiftfin
[#242](https://github.com/jellyfin/Swiftfin/issues/242),
[#1892](https://github.com/jellyfin/Swiftfin/issues/1892),
[#1068](https://github.com/jellyfin/Swiftfin/issues/1068); Infuse community
[specials in season](https://community.firecore.com/t/specials-in-season/46769).
