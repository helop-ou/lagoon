# Design system

Lagoon is dark-locked, with black backgrounds, system semantic text colors,
and native Liquid Glass actions. Use the shared implementation in
[`DesignSystem.swift`](../Lagoon/Shared/UI/DesignSystem.swift), not
screen-specific copies of its values.

## Tokens

| `Metrics` token | tvOS | iOS |
| --- | --- | --- |
| `screenGutter` | 80 | 20 |
| `cardSpacing` | 40 | 14 |
| `posterWidth` | 280 | 160 rail card baseline, scales with Dynamic Type |
| `phoneGridPosterMinimum` / `padGridPosterMinimum` | Not used | 100 / 150; grids fit as many columns as these allow and size cards to the column |
| `landscapeWidth` | 360 | 240 |
| `heroHeight` | 620 | 200 baseline on iPhone and compact-width iPad windows |
| `expandedHeroHeight` | Not used | 360 on regular-width iPad windows |
| `expandedHeroTextWidth` | Not used | 520 maximum on regular-width iPad windows |
| `detailPosterHeroMaxShare` / `detailPosterContentOverlap` | Not used | 0.72 / 0.36: the portrait poster hero's ceiling as a share of the window height, and how far the metadata block rises over it |
| `detailLandscapeRowShare` | Not used | 0.88: where the landscape row starts down the full-screen poster |
| `detailBackdropHeroShare` | Not used | 0.6: the portrait hero's height as a share of the window for the landscape key art |
| `detailBackdropRequestWidth` / `detailBackdropDecodeSize` | 1920 request | 1920 / 1920: the key art is decoded at the width it was requested at, so a landscape phone hero is never decoded smaller and upscaled soft |
| `detailCircleActionSize` | Not used | 50: diameter of the phone's circular detail actions, the large control height |
| `detailPosterAmbientBlur` | Not used | 36: blur of the poster copy filling the sides of a landscape hero |
| `detailPosterAmbientDecodeSize` | 240 | Longest edge of that blurred copy's decode, shared |
| `detailPlayButtonMaxWidth` / `detailLandscapePlayButtonMaxWidth` | Not used | 360 / 260: the phone's Play pill cap in portrait and in the landscape row |
| `gridColumns` | 5 | Not used; the count follows the width (three across on a portrait phone) |
| `downloadRingLineWidth` | Not used | 2.5: the download control's progress ring stroke |
| `downloadMarkSize` | Not used | 18: the download progress ring and the poster's "downloaded" badge glyph |
| Rail top / bottom padding | 48 / 96 | 12 / 40 |

`Metrics.Space` provides `hair=2`, `xs=4`, `s=8`, `m=12`, `l=16`, `xl=24`,
`xxl=40`, and `section=56`. Use it for internal spacing; structural gutters
and card dimensions have their own tokens. Shared radii are card 12, artwork
10, badge 6, and panel 32. iOS Home and Discover heroes use the dedicated
`heroCornerRadius` of 16; tvOS heroes retain the native card shape.
`Motion` durations are fast 0.2, standard 0.4,
slow 0.6, and crossfade 0.8 seconds.

Use semantic type: `largeTitle` for screen titles, `title2` for the player's
title, `title3` for section headings, `headline` for rails/cards, and
`callout` for synopses, metadata, and control labels; the touch detail page's
wide Play is the one hero action and sets its label in `title3`. Supporting labels use
the existing footnote/caption roles. Display glyphs and logo-like type use
named `Typography` values rather than raw `.system(size:)` in screens.

## Brand and materials

Brand tokens are `.lagoonAqua` (`#2ED4C7`), `.lagoonShore` (`#0D4A57`), and
`.lagoonNavy` (`#0B1D28`). Reserve them for branding and the established
progress/selection accents. `AccentColor` stays white; it is not a brand
color. Use `.primary`, `.secondary`, `.tertiary`, fills, and materials for
ordinary UI.

Use native `.glass` actions and the existing circular control shape where
appropriate. The iOS player's center transport uses `.glass(.clear)` to keep
the video visible through the controls. Do not introduce `.glassProminent`.
The tvOS player panel uses regular material for content with separate glass
tabs/actions; iOS uses a native resizable options sheet. Avoid nested glass.
Use translucent material for cards over credits so text underneath is blurred.

## Focus strategy

The system `.card` button style owns focus lift and parallax. Do not add
custom focus scaling, competing backgrounds, or clipping around that control.
Preserve rail headroom and `.scrollClipDisabled()` so focused artwork can lift.
The existing artwork hue halo is an accent, not a replacement focus treatment.

Never set foreground colors on a tvOS focusable control that draws the native
focused lozenge, or an ancestor of it: inherited white text can become white
on its white focused background. This applies to default/glass controls;
card labels without that lozenge keep their semantic text colors. Form rows
need an explicit appropriate control style. Test focused and unfocused states.

## Components

- **Browsing:** reuse `MediaRail` and the existing media cards. Titles belong
  beneath posters. Keep horizontal gutters inside scroll content and leave
  focus padding intact. tvOS Library has five columns; iOS uses `PosterLayout`.
- **Heroes:** use the contained banner, artwork wash, and existing native
  paging behavior. Keep the focused/tappable control stable while artwork
  transitions. Home and Discover share the taller iPad layout, with the
  title and two-line synopsis in a bounded text column. Height can grow
  further for Dynamic Type. Ambient glow uses the shared palette and
  `AmbientGlowView`.
- **Details:** use `DetailPageScaffold`, `DetailMetadataHeader`,
  `AdaptiveActionStack`, and `MetadataFlowLayout`. Reuse title art and cast
  components; the shared scaffolding serves Jellyfin and Seerr screens. On a
  phone or a compact-width iPad window the landscape key art is the hero
  for both orientations, as Infuse frames it (HEL-169): portrait fills
  `detailBackdropHeroShare` of the height with the art's middle, cropped at
  the sides, and centres the title, facts, a wide Play button (capped at
  `detailPlayButtonMaxWidth`) and the circular actions over its lower part,
  with the whole synopsis below; landscape fills the window with the art
  edge to edge, centred, and since a phone's window is wider than 16:9 a
  little of the top and bottom is trimmed rather than the sides padded, and
  puts title art, the actions and a smaller Play on one row along its lower
  part, the facts and synopsis following below the fold. A title with no
  backdrop falls back to its poster: top-anchored in portrait, and in
  landscape shown whole over a blurred and dimmed copy of itself
  (`detailPosterAmbientBlur`, `detailPosterAmbientDecodeSize`). On a phone every secondary
  control in that row is a glass circle, From Beginning included, so the
  row never folds into a column, and the "Resume from" caption sits under
  the Resume pill rather than under the block. Those circles are
  `DetailCircleButton`, a plain button under `.glassEffect(.regular.interactive(), in: .circle)`
  rather than `.buttonStyle(.glass)` with a circular border shape, because
  that style's pressed highlight is a capsule sized to the label and showed
  through the circle as a lozenge (iOS 26.0 and 26.5). `DownloadControl`'s
  menus still use the border-shape form and have not been checked for the
  same artefact. Regular-width iPad windows
  keep the landscape backdrop, with more of it above the title, and the
  leading column. tvOS keeps its
  own order. Series playback actions describe the episode that will play.
- **Settings:** use native category navigation on each platform. iOS uses
  Forms, pickers, toggles, and Edit/reorder; tvOS keeps remote focus behavior.
- **Downloads (iOS only, HEL-166):** `DownloadControl` is a glass circle
  beside the detail page's other actions, in the same family as
  `ItemActionRow`'s toggles; its glyph and a menu carry the entry's state
  through symbol weight and opacity, never color. Its progress ring uses
  `downloadRingLineWidth`; it and a poster's small "downloaded" badge on
  `PosterCard`, `LandscapeCard`, and `EpisodeCard` share `downloadMarkSize`.
  `DownloadsView` lists every downloaded title reachable with no server at
  all; Library surfaces an entry point to it and an offline banner when the
  server can't be reached.
- **Loading and failures:** use the shared state views. Keep mounted content
  during reconciliation and use inline retry when there is usable content.

## iPhone accessibility and browsing

`PosterLayout` scales cards, caption space, and columns together. Adaptive
actions measure intrinsic width and height before stacking. Segmented pickers
become menu pickers at accessibility sizes. Show phone synopses in full,
give title art a spoken title/header, and combine cast names and roles while
treating their portraits as decorative.

Keep the transport available with VoiceOver, expose adjustable timeline
seeking and meaningful icon labels, and respect Reduce Motion explicitly for
symbol effects. System caption appearance hides Lagoon settings that would
have no effect. Current player layout and auto-hide behavior are specified in
[Playback](playback.md#controls-and-presentation).

## Image loading

Use `CachedAsyncImage` with an explicit `maxPixelSize`, never `AsyncImage`.
`ArtworkSizing` converts display dimensions to pixels. A changed size reloads
the image. The shared loader provides synchronous cache hits, off-main
thumbnail decoding, coalesced requests, and independent caller cancellation.

The cache is bounded at 200 images / 50 MB. Hero/backdrop decode budgets are
1920 pixels, palette sampling 120, and Now Playing 1024. Responses are capped
at 16 MiB and validated before decoding; failed/incomplete images are not
cached. Top Shelf uses the same validated input before composition. Trickplay
has its own two-sheet decoded cache and 32 MiB compressed cache with the same
response cap. See [download validation](archive/download-hardening-validation.md).

For brand artwork, icon selection, detailed compositions, and the rationale
behind focus decisions, see the [design engineering notes](reference/design-system.md).
