# Changelog

**Generated file. Do not edit.** Run `scripts/generate-changelog.sh`
after changing
[`Changelog.swift`](Lagoon/Features/Settings/Changelog.swift), which is
the source of truth. This file, the About screen inside the app, and
the notes on a GitHub release are all renderings of it.

These notes are written for someone watching rather than someone
reading the diff. They say what changed on screen and leave out
refactors, tests and documentation, so a build that changed nothing a
viewer would notice has no entry here. The commit log is the record of
everything else.

Builds are newest first. The number in brackets is the build, which is
what identifies a binary: it is what About shows, what a release tag
carries, and what to quote in a bug report. One marketing version spans
many builds.

## 0.2.1 (108)

September 2026

**Smoother playback for some films and episodes on Apple TV.**

### Improvements

- Lagoon now says when a Seerr server sits behind a sign in proxy such as Cloudflare Access, instead of reporting an unreadable response. Connecting through one is not supported yet.

### Bug fixes

- Some 23.976 fps films and episodes no longer judder on Apple TV: the TV now switches to the right frame rate for them.

## 0.2.0 (107)

September 2026

**Privacy policy and support pages in Settings.**

### New features

- Settings, About and the sign in screens link Lagoon's privacy policy and support page. On Apple TV, scan the code to open them on your phone.

## 0.1 (106)

September 2026

**Home is yours to arrange.**

### New features

- Reorder and hide every Home row, including Home Screen Sections plugin rows, in Settings, Home Rows.

### Improvements

- Home opens with Continue Watching, Next Up and what is new in each library.
- Recently Added is split into separate Movies and Shows rows.
- Lagoon remembers your subtitle choice for a series, including none.
- Skip Intro waits for the picture to move again, so a slow connection no longer rebuffers.

### Bug fixes

- A struggling episode no longer switches to a server transcode partway through.
- Sign Out on Apple TV works, after asking you to confirm.
- Signing out of your last account returns you to the server screen.
- Change Server on the sign in again screen now removes that account.

## 0.1 (105)

September 2026

**The audio track you pick is the one that keeps playing.**

### Improvements

- Audio tracks with identical names show their position so they can be told apart.

### Bug fixes

- Lagoon remembers the audio track you pick for a series, so poorly labelled releases stop starting in the wrong language.

## 0.1 (104)

September 2026

**Search stops leading to a dead end.**

### Bug fixes

- A search with no matches no longer offers an empty Show All page.
- Watch Together on Apple TV opens as a proper panel with a clear name field.

## 0.1 (103)

September 2026

**Jellyseerr search stops coming up empty.**

### Bug fixes

- Seerr search no longer comes up empty when a result is a film collection.
- A film no longer drops to a lower quality stream after the app has been in the background.

## 0.1 (102)

September 2026

**Skip Intro and Next Episode show how long is left.**

### Bug fixes

- The Skip Intro and Next Episode buttons fill up as their countdown runs.

## 0.1 (101)

September 2026

**Readable focused buttons on Apple TV.**

### Bug fixes

- Focused buttons and settings on Apple TV keep their text readable.

## 0.1 (100)

September 2026

**Downloads, Watch Together, themes and a new look for film pages.**

### New features

- Download films and episodes to iPhone or iPad and watch them offline. Needs the server's Allow media downloading permission.
- Watch Together: start or join a group from a title's page and watch in sync with others on your server.
- A Baby Pink theme, chosen per profile in Settings, Appearance.
- On iPhone and iPad, playback continues when you lock the screen or leave the app.
- 1080i and 576i TV recordings play directly and are deinterlaced on the device.

### Improvements

- Redesigned film and series pages on iPhone and iPad, with full width artwork and a large Play button.
- Series pages open on the episode to watch next.
- Seerr title pages match Lagoon's film and series pages.
- Home can show Top 10 Movies and Top 10 Shows from Seerr's trending lists.
- Changelog notes are grouped into New features, Improvements and Bug fixes.

### Bug fixes

- Switching seasons quickly no longer shows the wrong episode list.

## 0.1 (99)

September 2026

**Your Jellyfin profile picture shows up in Lagoon.**

### Improvements

- The account picker and Settings show your Jellyfin profile picture.

## 0.1 (98)

September 2026

**4K buffers ahead properly, and image subtitles stop piling up.**

### Improvements

- A failed watched or favorite change now says so instead of silently reverting.
- On a full width iPad, film and series pages keep their details in a column beside the artwork.

### Bug fixes

- 4K films played directly buffer ahead at your connection's full speed.
- Image subtitles no longer pile up in memory over a long film.
- Scrubbing backwards right after another jump lands where you asked.

## 0.1 (97)

September 2026

**The iPhone and iPad player stays open, and gets swipe controls.**

### Improvements

- The iPhone player no longer forces landscape.
- Swipe down for Picture in Picture, or up for subtitles, audio and speed.
- Three posters per row on iPhone, more in landscape and on iPad.
- Films played directly buffer ahead at full speed and survive brief network drops.

### Bug fixes

- The player no longer closes itself when started from a title page, Library, Search or Discover on iPhone or iPad.

## 0.1 (96)

September 2026

**Playback problems report themselves.**

### New features

- When playback fails or stalls, Lagoon sends a short technical report with no account, server or title details. Turn it off in Settings, Advanced, Diagnostic Reports.

## 0.1 (95)

September 2026

**No more blank cards for titles that only have a poster.**

### Bug fixes

- Titles with only a poster show it on Home rows instead of a blank card.

## 0.1 (94)

September 2026

**Touch controls for the iPhone and iPad player.**

### New features

- Double tap either side of the video to skip ten seconds.
- Closing the player continues in Picture in Picture.

### Improvements

- A large centered play button with ten second skips, and controls that fade while playing.
- The volume keys control the film, and the Silent switch no longer mutes it.

### Bug fixes

- Watching episodes back to back no longer builds up memory.

## 0.1 (93)

September 2026

**A roomier subtitle search and smoother episode handoffs.**

### Improvements

- Subtitle search opens a full list of results.
- Smoother player controls during playback.
- Fewer dropped frames on HDR and Dolby Vision with subtitles on Apple TV.

### Bug fixes

- Play Next no longer drops you back to browsing, and starts the next episode sooner.
- A downloaded subtitle carries over to the next episode.

## 0.1 (92)

September 2026

**Dolby Vision for disc remuxes, and transcoding behind proxy paths.**

### New features

- Dolby Vision profile 7 titles, such as UHD Blu-ray remuxes, play as Dolby Vision on Apple TV.
- Settings, About lists the open source components Lagoon uses.

### Improvements

- Home always has featured titles.
- Subtitle search goes through your Jellyfin server only, and the OpenSubtitles settings are gone.

### Bug fixes

- Servers behind a proxy path such as example.com/jellyfin can transcode and load external subtitles.

## 0.1 (91)

September 2026

**Safer account switching and easier server setup.**

### Improvements

- Changing subtitle tracks keeps the current one until the new one is ready, with Retry if it fails.
- An expired sign in takes you back to sign in, keeping your accounts and settings.
- Sign in warns when a server uses unencrypted HTTP.
- iPhone and iPad explain how to allow local network access when it is blocked.

### Bug fixes

- Switching accounts no longer carries over searches, Seerr sign ins or Top Shelf links.
- Removing an account also clears its searches, preferences and Seerr sign in.
- Server addresses with proxy paths, custom ports and IPv6 work.
- HTTPS playback checks the server's certificate.

## 0.1 (90)

September 2026

**Swipeable featured titles and cleaner Home rows.**

### New features

- Swipe through featured titles on Home and Discover, or press Left and Right on Apple TV.

### Improvements

- Next Up only shows episodes you have not started.
- Recently Added shows a series once, not every new episode.
- Larger posters and buttons on iPhone and iPad.

## 0.1 (89)

September 2026

**One Library, fuller search, and a more comfortable iPhone.**

### New features

- Movies and shows share one Library tab.
- Sort and filter the Library by genre, decade, unwatched, favourites and 4K.
- See All for Jellyfin and Seerr search results.

### Improvements

- iPhone and iPad layouts adapt to the screen and to larger text.
- Sharper artwork on high resolution screens.
- Settings on iPhone and iPad is split into separate pages.
- The iPhone and iPad player uses standard controls, with speed and audio delay options.
- Partly available Seerr titles open in Lagoon.

## 0.1 (88)

September 2026

**Rows pick up the colour of what you are looking at.**

### New features

- With the controls showing, tap the Siri Remote touch surface to see when the film will end.

### Improvements

- Focused artwork on Apple TV casts a glow in its own colours.

## 0.1 (87)

September 2026

**Pages stay current, and the Siri Remote feels at home.**

### Improvements

- Home, Movies, Shows and Discover stay current, with pull to refresh on iPhone and iPad and a refresh button on Apple TV.
- Pending Seerr requests update on their own.
- A light tap on the Siri Remote shows the controls without pausing.

### Bug fixes

- Resume and Continue Watching update as soon as you stop watching.
- Jellyfin 12 preview servers no longer reject Lagoon's video and subtitle links.

## 0.1 (86)

September 2026

**Remuxed and transcoded titles no longer lose their sound every few seconds.**

### Improvements

- Playback Details shows audio and video buffer health.

### Bug fixes

- Remuxed and transcoded titles no longer drop their sound every few seconds.

## 0.1 (85)

September 2026

**4K AV1 plays smoothly on Apple TV.**

### Improvements

- Software decoded HDR is converted on the GPU.

### Bug fixes

- 4K HDR AV1 no longer starts dropping frames half a minute in.

## 0.1 (84)

September 2026

**More of the Apple TV works on 4K AV1 at once.**

### Improvements

- The AV1 decoder works on more frames at once, for a faster decode.

## 0.1 (83)

September 2026

**4K AV1 shows in SDR on Apple TV, the way it has to be.**

### Improvements

- Software decoded HDR shows in SDR on Apple TV, which cannot present it as HDR. iPhone and iPad keep HDR.

## 0.1 (82)

September 2026

**4K AV1 frame preparation spreads across more cores.**

### Improvements

- Preparing decoded frames for display uses several cores instead of one.
- Playback Details shows the full cost of each frame.

## 0.1 (81)

September 2026

**AV1 falls back instead of failing.**

### Improvements

- Most decoder test switches are removed.

### Bug fixes

- AV1 files the system refuses to decode play with Lagoon's own decoder.

## 0.1 (80)

September 2026

**A test switch for decoding AV1 with the system.**

### New features

- Decode AV1 with the System Decoder, in Settings, Advanced, for testing. Turn it off if AV1 files stop playing.

## 0.1 (79)

September 2026

**A newer AV1 decoder.**

### Improvements

- AV1 decoding moves to dav1d 1.5.4, which spreads work across cores better.

## 0.1 (78)

September 2026

**Playback details say how many processor cores are decoding.**

### Improvements

- Playback Details shows how many cores are decoding, and Settings, Advanced can change it.

## 0.1 (77)

September 2026

**A way to measure what film grain costs the decoder.**

### New features

- Skip Film Grain, in Settings, Advanced, measures what AV1 film grain costs. It changes the picture, so it is for testing.

## 0.1 (76)

September 2026

**Playback details say what decoding a frame actually costs.**

### New features

- Playback Details shows each frame's decode cost against its time budget.

## 0.1 (75)

September 2026

**AV1 decodes several times faster.**

### Improvements

- AV1 decodes several times faster on every device, with no change to the picture.

## 0.1 (73)

September 2026

**Software decoded video reads and decodes at the same time.**

### Improvements

- Software decoded video, such as AV1, VP9 and MPEG-2, reads and decodes in parallel for a steadier frame rate.
- Playback Details separates decoding, converting and reading time.

### Bug fixes

- 4K software decoded films no longer hold a gigabyte of frames in memory.

## 0.1 (72)

September 2026

**4K AV1 plays on the device.**

### New features

- 4K AV1 plays on the device instead of being converted by your server.

### Improvements

- Software decoding uses every core, about eight times faster for 4K AV1.

## 0.1 (71)

September 2026

**A film from a disc starts at the beginning, and the scrubber works.**

### Bug fixes

- Disc images and TV recordings start at the beginning, and the scrubber works.

## 0.1 (70)

September 2026

**Disc images play from the disc, Blu-ray and DVD alike.**

### New features

- DVD images play directly from the disc.
- Lagoon deinterlaces MPEG-2 itself, so DVDs and older recordings no longer need the server.

### Bug fixes

- Blu-ray images play, with their original soundtrack.

## 0.1 (69)

September 2026

**A film kept as a Blu-ray disc image now plays straight from the disc.**

### New features

- Blu-ray images play the main feature directly, keeping a TrueHD or Atmos soundtrack.

### Improvements

- DVD images and disc folders go straight to the server, so they start sooner.

## 0.1 (68)

August 2026

**On an iPhone or iPad, cellular no longer means downloading the whole film.**

### New features

- A Full Quality on Cellular switch in Settings, for fast unmetered connections.

### Improvements

- On cellular or a hotspot, Lagoon asks the server for a smaller version instead of the original file.

## 0.1 (67)

August 2026

**Fixes the constant buffering from the last build.**

### Bug fixes

- Films no longer stop to buffer every few seconds, a regression in 0.1 (66).

## 0.1 (66)

August 2026

**More 4K films play directly, and lost sound shows as buffering.**

### Improvements

- When the sound runs out because a film arrives too slowly, Lagoon shows buffering instead of playing on in silence.
- Films your server converts keep more sound in reserve.

### Bug fixes

- Some 4K releases that fell back to a server transcode now play directly. Worth retrying any that did.

## 0.1 (65)

August 2026

**A film your server has to convert keeps playing instead of stalling.**

### Improvements

- Fallback transcodes are requested at 1080p instead of 4K, so most servers keep up.
- Playback Details shows which delivery was used and why.

## 0.1 (64)

August 2026

**A switch for chasing sound that cuts out.**

### New features

- Buffer Transcoded Playback, in Settings, Playback Diagnostics, for converted titles whose sound cuts out.

### Improvements

- Playback Details shows buffered sound in seconds.

## 0.1 (63)

August 2026

**Control Center stops blanking the picture, and more of your files play untouched.**

### New features

- WMV3 video in MKV or AVI, MP2 and Apple Lossless play directly.

### Bug fixes

- Opening Control Center during a film no longer blanks the TV.
- Recent searches keep what you searched for, not every letter typed.

## 0.1 (62)

August 2026

**Collections, and the new Home rows open the title you picked.**

### New features

- A Collections row on Home, and collections in Search.
- Empty and single title collections are hidden.

### Bug fixes

- Picking from the new Home rows opens the title instead of playing it.

## 0.1 (61)

August 2026

**Top Shelf artwork is kept where an Apple TV allows it.**

### Bug fixes

- Top Shelf artwork is saved where Apple TV allows it.

## 0.1 (60)

August 2026

**The Top Shelf artwork can be drawn on an HDR television.**

### Bug fixes

- Top Shelf artwork works on HDR televisions.

## 0.1 (59)

August 2026

**Eight new rows on Home, in an order that reads.**

### New features

- Eight new Home rows, including Because You Watched, Movies in 4K, Ready to Binge and Surprise Me.

### Improvements

- Home groups what you are watching, then movies, then shows.
- Rows with too little in them hide.

### Bug fixes

- Drawing Top Shelf artwork no longer stalls the app.

## 0.1 (58)

August 2026

**Still chasing the Top Shelf.**

### Bug fixes

- The Top Shelf fills in with whatever titles are ready, instead of nothing.
- Continue Watching updates as soon as you stop watching.

## 0.1 (57)

August 2026

**The Top Shelf works.**

### New features

- The Top Shelf shows up to eight titles you were watching, with artwork, a summary, time left and quality badges.
- Play resumes where you stopped, and More Info opens the title in Lagoon.

## 0.1 (56)

August 2026

**Search moves out, and Discover fills the screen.**

### New features

- Search has its own tab and remembers recent searches.
- Discover has a hero banner and eight rows, in your Seerr administrator's order.
- A request that has arrived opens straight into Lagoon.
- Unblock titles on your Seerr blocklist from Lagoon.

### Improvements

- Requests show download progress and the quality they will be fetched at.

### Bug fixes

- Requests show their real status instead of always pending.

## 0.1 (55)

August 2026

**Play at your own speed.**

### New features

- Playback speed from half to double, keeping voices at their pitch.
- Positioned and styled subtitles appear where and how they were authored.
- 10-bit AV1 and VP9 play directly.
- MPEG-2, LPCM and DVB subtitles play directly, covering most DVD rips and recordings.
- Spatial Audio for stereo soundtracks on AirPods.

### Improvements

- A new app icon and look.

### Bug fixes

- Starting a film after a failed one no longer waits fifteen seconds.
- A failed film no longer leaves your server converting it.

## 0.1 (54)

August 2026

**Playback recovers instead of giving up.**

### Improvements

- A film that will not play retries another way instead of showing an error.
- Lost sound is rebuilt instead of playing on in silence.

### Bug fixes

- Pausing near the start buffers as far ahead as it should.

## 0.1 (53)

August 2026

**Subtitle errors say what the server said.**

### Bug fixes

- A failed subtitle download shows your server's reason.

## 0.1 (52)

August 2026

**Subtitle search works for server administrators again.**

### Bug fixes

- Subtitle search works again for Jellyfin administrators.

## 0.1 (51)

August 2026

**Seerr signs itself in.**

### New features

- Discover signs in to Seerr with your Jellyfin account.

## 0.1 (50)

August 2026

**Playback, subtitles and requests.**

### New features

- Fetch subtitles from OpenSubtitles when your Jellyfin account cannot. Add a key in Settings, Subtitles.
- An About screen with this changelog.

### Improvements

- Seerr requests are a poster grid, each with its own page.
- Builds before 50 are not listed.

### Bug fixes

- Long films no longer start stuttering partway through.
- Subtitle errors name the real cause.
- Subtitles that are not UTF-8 display correctly.

## 0.1 (1)

August 2026

**First TestFlight build.**

### New features

- Lagoon's own playback engine, with no AVPlayer.
- Direct play for H.264, HEVC, VC-1 and MPEG-4, so fewer titles transcode.
- HDR10 and Dolby Vision with display matching, and Dolby Digital, Atmos and TrueHD passthrough.
- Embedded, external and searchable subtitles.
- Trickplay scrubbing, intro skipping and autoplay into the next episode.
- Home, library browsing, search and a Top Shelf extension.
- Browse and request titles from Seerr.

