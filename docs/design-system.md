# Design system

Lagoon is dark-locked: black backgrounds, system semantic text colors and
native Liquid Glass actions. Use the shared values in
[`DesignSystem.swift`](../Lagoon/Shared/UI/DesignSystem.swift), never
screen-specific copies.

## Tokens

| `Metrics` token | tvOS | iOS |
| --- | --- | --- |
| `screenGutter` | 80 | 20 |
| `cardSpacing` | 40 | 14 |
| `posterWidth` | 280 | 160 rail card baseline, scales with Dynamic Type |
| `phoneGridPosterMinimum` / `padGridPosterMinimum` | Not used | 100 / 150; grids fit as many columns as these allow |
| `landscapeWidth` | 360 | 240 |
| `heroHeight` | 620 | 200 on iPhone and compact-width iPad |
| `expandedHeroHeight` | Not used | 360 on regular-width iPad |
| `expandedHeroTextWidth` | Not used | 520 maximum on regular-width iPad |
| `detailPosterHeroMaxShare` / `detailPosterContentOverlap` | Not used | 0.72 / 0.36: portrait poster hero's cap as a share of window height, and how far the metadata rises over it |
| `detailLandscapeRowShare` | Not used | 0.88: where the landscape row starts down the full-screen poster |
| `detailBackdropHeroShare` | Not used | 0.6: portrait hero height as a share of the window for landscape key art |
| `detailBackdropRequestWidth` / `detailBackdropDecodeSize` | 1920 request | 1920 / 1920: decode at the requested width, so a landscape phone hero is never upscaled soft |
| `detailCircleActionSize` | Not used | 50: the phone's circular detail actions |
| `detailPosterAmbientBlur` | Not used | 36: blur of the poster copy filling a landscape hero's sides |
| `detailPosterAmbientDecodeSize` | 240 | Longest edge of that blurred copy's decode, shared |
| `detailPlayButtonMaxWidth` / `detailLandscapePlayButtonMaxWidth` | Not used | 360 / 260: the phone's Play pill cap, portrait / landscape row |
| `gridColumns` | 5 | Not used; columns follow the width (three on a portrait phone) |
| `downloadRingLineWidth` | Not used | 2.5: download progress ring stroke |
| `downloadMarkSize` | Not used | 18: download progress ring |
| `cardMarkSize` / `cardMarkInset` | 28 / 8 | 18 / 4: a card's "downloaded" and "watched" badges and their corner inset |
| `themeSwatchSize` | Not used | 28: swatch in Settings › Appearance |
| `qrCodeSize` / `qrCodeMinimumQuietZone` | 420 / 32 | 220 / 16, gallery only. A code scans from about ten times its width. The real quiet zone is derived from the code |
| Rail top / bottom padding | 48 / 96 | 12 / 40 |

- `Metrics.Space`: `hair=2`, `xs=4`, `s=8`, `m=12`, `l=16`, `xl=24`,
  `xxl=40`, `section=56`. Use it for internal spacing; gutters and card sizes
  have their own tokens.
- Radii: card 12, artwork 10, badge 6, panel 32. iOS Home and Discover heroes
  use `heroCornerRadius` 16. tvOS heroes keep the native card shape.
- `Motion`: fast 0.2, standard 0.4, slow 0.6, crossfade 0.8 seconds.

Type is semantic: `largeTitle` for screen titles, `title2` for the player
title, `title3` for section headings and the touch detail page's wide Play,
`headline` for rails and cards, `callout` for synopses, metadata and control
labels, footnote/caption for supporting labels. Display glyphs and logo-like
type use named `Typography` values, never raw `.system(size:)`.

## Brand and materials

- Brand tokens: `.lagoonAqua` (`#2ED4C7`), `.lagoonShore` (`#0D4A57`),
  `.lagoonNavy` (`#0B1D28`), and the monochrome pair `.lagoonInk` (`#07161D`)
  and `.lagoonMist` (`#E9F1F2`) for the one dark-on-light place.
- Use them only for the lockup and anything that must never follow a theme.
  Other brand moments read the current theme through `Theme` (see
  [Themes](#themes)).
- `AccentColor` stays white. iOS controls take the theme's `controlTint`,
  never the asset.
- Ordinary UI uses `.primary`, `.secondary`, `.tertiary`, fills and materials.

## Themes

A theme is a `ThemePalette` of eight roles: `accent`, `ground`, `background`,
`surface`, `glowDepth`, `controlTint`, `artworkTint` and `chrome`. Two exist:
`AppTheme.lagoon` over true black and `AppTheme.babyPink`. Keep the list short;
each theme is checked over every screen.

- **Read colours from `Theme.accent`, `.ground`, `.background` and `.glow`
  inside `body`**, never brand tokens or `Color.black`. That is what makes a
  theme change re-render through Observation.
- **Text never takes a theme colour.** A scrim over artwork inside a card stays
  black.
- **A grouped form on iOS is a `ThemedForm`**, never a bare `Form` or `List`.
  It themes page, rows and bars, so a new settings page needs nothing else.
- **The player surface, its overlays, subtitles and Top Shelf stay pure
  black**, outside the theme.
- **tvOS controls are never tinted.** `themedControls()` and `themedChrome()`
  are iOS only.
- **The theme belongs to the Jellyfin profile**, stored under
  `appearance.theme.<accountID>`, so the account picker and sign-in screens
  show the last viewer's look.

Materials: use native `.glass` actions and the existing circular control
shape. The iOS player's centre transport uses `.glass(.clear)` so video shows
through. No `.glassProminent`, no nested glass. Cards over credits use
translucent material so text beneath is blurred.

Role meanings, palette values and the bloom overlay are in the [design
notes](reference/design-system.md#themes).

## Focus strategy

- The system `.card` button style owns focus lift and parallax. No custom
  focus scaling, competing backgrounds or clipping around it.
- Keep rail headroom and `.scrollClipDisabled()` so focused artwork can lift.
  The artwork hue halo is an accent, not a focus treatment.
- Never set foreground colors on a tvOS control that draws the native focused
  lozenge, or on its ancestors: inherited white text turns white on white when
  focused. This covers default and glass controls. Card labels without the
  lozenge keep semantic colors.
- Form rows need an explicit control style. Test focused and unfocused states.

## Components

- **Browsing:** reuse `MediaRail` and the media cards. Titles go beneath
  posters. Horizontal gutters stay inside scroll content; keep focus padding.
  tvOS Library has five columns; iOS uses `PosterLayout`.
- **Chip rows** (Discover's Movies/Shows/Requests, the Requests filters) stay
  one row everywhere. On a phone the row scrolls horizontally, with the gutter
  as a content margin and no glyphs, and never folds into a column. The TV
  keeps a fixed row for focus geometry.
- **Title art:** `TitleArtView` shows a library title's Jellyfin logo and
  `TitleArtImage` any logo URL; both fall back to the name in type. Seerr
  titles use the Jellyfin logo once the title is in the library.
- **Top 10 shelves:** landscape cards with an oversized rank beside each. The
  rank sits outside the focusable card, so focus lift and accessibility stay
  with the native control.
- **Heroes:** contained banner, artwork wash, native paging. The focused or
  tappable control stays stable while artwork transitions. Home and Discover
  share the taller iPad layout, with title and two-line synopsis in a bounded
  column; height grows for Dynamic Type. Ambient glow uses `AmbientGlowView`.
- **Details:** `DetailPageScaffold`, `DetailMetadataHeader`,
  `DetailActionLayout`, `MetadataFlowLayout`, title art and cast components
  serve both Jellyfin and Seerr pages; request state stands in for Play.
  `CastStrip` takes Jellyfin people or `CastCredit`s (Seerr's TMDB credits).
  - `DetailActionLayout` owns all four action compositions (primary pill,
    secondary controls, optional accessory). No page keeps its own copy.
  - On a phone every secondary control is a glass circle, so the row never
    folds. Use `DetailCircleButton` and `DetailCircleMenu`, not
    `.buttonStyle(.glass)` with a circle: its pressed highlight is a
    label-sized capsule that shows through as a lozenge.
  - Set the episode rail's `scrollPosition(id:)` only when the rail changes
    hands (load, season pick, after playback). Setting it while browsing makes
    the rail jump under a moving focus.
  - Series playback actions describe the episode that will play: the focused
    card, else the server's up-next, else the visible season's first. The
    watched toggle applies to the show.

  Per-orientation layout, poster fallback, season opening and the tvOS
  synopsis reservation are in the [design
  notes](reference/design-system.md#detail-pages).

- **Settings:** native category navigation on each platform. iOS uses Forms,
  pickers, toggles and Edit/reorder; tvOS keeps remote focus. Home Rows is one
  list of every row, each naming its source under its title. Reorder is Edit
  and drag on iOS, up/down glass buttons beside each row on the TV.
- **Modals (tvOS):**
  - A sheet with custom content ignores `presentationSizing`, so the panel
    sets its size (`Metrics.modalPanelSize`) or fills the screen.
  - Layout is title, scrolling content, Done, in sequence, not
    `safeAreaInset` overlays (overlays draw over content and need their own
    material). `onExitCommand` dismisses, so Menu and Done agree.
  - Prefer a fixed size when content can change while open, or the panel
    resizes under focus.
  - Never put `TVSettingsPage` in a sheet. It is the full-screen Settings
    destination (460pt identity column, page title, Back, opaque background).
- **Downloads (iOS only):**
  - `DownloadControl` is a glass circle beside the detail actions, like
    `ItemActionRow`'s toggles. Glyph and menu show state through symbol weight
    and opacity, never color. Its ring uses `downloadRingLineWidth` and
    `downloadMarkSize`.
  - Permission is `DownloadStore.permitted`, refreshed on account activation
    and each detail load. The control never resolves it: it renders nothing
    until allowed, and a task on a view that renders nothing never runs.
  - `DownloadedMark` is the badge on `PosterCard`, `LandscapeCard` and
    `EpisodeCard`, sized by `cardMarkSize`.
  - `DownloadsView` lists every download and works with no server. Library
    links to it and shows an offline banner when the server is unreachable.
    Settings › Downloads shows the count, and its Show Downloads button opens
    the Library list through the `showDownloadsList` environment action. The
    Settings stack is destination-owned and the list's rows are route values,
    so the two must not share a stack (see `ContentNavigationRoute`).
- **Watch Together:**
  - `WatchTogetherControl` is the detail entry point: a glass circle on a
    phone, a labelled pill where there is width. It renders nothing until the
    store says the account may join a group.
  - `WatchTogetherSheet` is a modal panel on tvOS, and a `ThemedForm` in a
    `NavigationStack` with medium and large detents on touch. The explainer
    under its title goes once the viewer is in a group.
  - `SyncPlayToastLabel` is the player's transient group message: a material
    capsule at the top, SDR, never hit-tested, shared with the DEBUG gallery.
  - `SyncPlayStateCopy` is the one place a group's state is put into words, so
    the sheet, the Together tab and the banner agree.
- **QR codes (tvOS):** `QRCodeView` hands an address to a phone, since tvOS
  cannot open links. It is the one exception to the dark lock and ignores the
  theme. Every rule below fails silently when broken, and `QRCodeTests`
  renders and decodes the real view to catch it.
  - Colours are `lagoonInk` on `lagoonMist` (about 16:1). Keep the pair
    extreme; never tint the light half.
  - Scale with `.interpolation(.none)`, since the generator emits one pixel per
    module.
  - Keep modules square. Rounded or dotted ones lose contrast at sofa
    distance.
  - The quiet zone is four modules, measured from the generated code.
  - Branding is only the centre mark, absorbed by correction level H:
    `LagoonSymbol` on a Mist plate covering `QRCode.markShare` of the width,
    with a gap between mark and modules. Not the jellyfish, not a dark tile.
  - Show the address in type beside the code, and hide the code from
    VoiceOver so the address is not read twice.
- **Loading and failures:** use the shared state views. Keep mounted content
  during reconciliation, and use inline retry when there is usable content.

## iPhone accessibility and browsing

- `PosterLayout` scales cards, caption space and columns together.
- Adaptive actions measure intrinsic width and height before stacking.
- Segmented pickers become menu pickers at accessibility sizes.
- Phone synopses show in full. Title art has a spoken title and header trait.
  Cast names and roles are combined; portraits are decorative.
- The transport stays available with VoiceOver, with adjustable timeline
  seeking and descriptive icon labels. Respect Reduce Motion explicitly for
  symbol effects.
- System caption appearance hides Lagoon settings that would have no effect.

Player layout and auto-hide are in
[Playback](playback.md#controls-and-presentation).

## Image loading

Use `CachedAsyncImage` with an explicit `maxPixelSize`, never `AsyncImage`.
`ArtworkSizing` converts display size to pixels, and a size change reloads.
The loader gives synchronous cache hits, off-main thumbnail decoding,
coalesced requests and per-caller cancellation.

| Limit | Value |
| --- | --- |
| Image cache | 200 images / 50 MB |
| Hero/backdrop decode | 1920 px |
| Palette sampling | 120 px |
| Now Playing artwork | 1024 px |
| Response cap | 16 MiB, validated before decoding |
| Trickplay | two-sheet decoded cache, 32 MiB compressed cache, same response cap |

Failed or incomplete images are never cached. Top Shelf composes from the same
validated input.

Brand artwork, icons, detailed compositions and the reasoning behind focus
decisions are in the [design notes](reference/design-system.md).
