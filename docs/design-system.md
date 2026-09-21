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
| `downloadMarkSize` | Not used | 18: the download progress ring |
| `cardMarkSize` / `cardMarkInset` | 28 / 8 | 18 / 4: a card's round "downloaded" and "watched" badges and their inset from the corner |
| `themeSwatchSize` | Not used | 28: the theme swatch beside each theme's name in Settings › Appearance |
| `qrCodeSize` / `qrCodeMinimumQuietZone` | 420 / 32 | 220 / 16, gallery only: a code scans from roughly ten times its width, so the TV needs a fifth of the screen. The real quiet zone is derived from the code, not this floor |
| Rail top / bottom padding | 48 / 96 | 12 / 40 |

`Metrics.Space` provides `hair=2`, `xs=4`, `s=8`, `m=12`, `l=16`, `xl=24`,
`xxl=40`, and `section=56`. Use it for internal spacing. Structural gutters
and card dimensions have their own tokens. Shared radii are card 12, artwork
10, badge 6, and panel 32. iOS Home and Discover heroes use the dedicated
`heroCornerRadius` of 16. tvOS heroes retain the native card shape. `Motion`
durations are fast 0.2, standard 0.4, slow 0.6, and crossfade 0.8 seconds.

Use semantic type: `largeTitle` for screen titles, `title2` for the player's
title, `title3` for section headings, `headline` for rails/cards, and
`callout` for synopses, metadata, and control labels. The touch detail page's
wide Play is the one hero action and sets its label in `title3`. Supporting
labels use the existing footnote/caption roles. Display glyphs and logo-like
type use named `Typography` values rather than raw `.system(size:)` in
screens.

## Brand and materials

Brand tokens are `.lagoonAqua` (`#2ED4C7`), `.lagoonShore` (`#0D4A57`), and
`.lagoonNavy` (`#0B1D28`), plus the package's monochrome pair `.lagoonInk`
(`#07161D`) and `.lagoonMist` (`#E9F1F2`) for the one place Lagoon prints dark
on light instead of the other way round. Reserve them for the lockup and
anything that must never follow a theme. Everywhere else the brand's moments read the current
theme through `Theme` (see Themes below). `AccentColor` stays white. A theme's
`controlTint` is what colours iOS controls, never the asset. Use `.primary`,
`.secondary`, `.tertiary`, fills, and materials for ordinary UI.

## Themes

A theme is a `ThemePalette` of eight roles: `accent`, `ground`, `background`,
`surface`, `glowDepth`, `controlTint`, `artworkTint` and `chrome`. Two exist —
`AppTheme.lagoon` over true black and `AppTheme.babyPink`. Keep the list
short: a theme is a considered set checked over every screen, not a hue
slider.

The rules:

- **Read colours from `Theme.accent`, `.ground`, `.background` and `.glow`
  inside `body`** — never the brand tokens or `Color.black` directly. That is
  what re-renders a change through Observation without environment plumbing.
- **Text never takes a theme colour**, and a scrim over artwork inside a card
  stays black.
- **A grouped form on iOS is a `ThemedForm`**, never a bare `Form` or `List`.
  It puts the page on the background, rows on the surface and bars in the
  chrome, so a new settings page is themed by using it and nothing else.
- **The player surface, its overlays, subtitles and the Top Shelf stay pure
  black**, outside the theme entirely.
- **tvOS controls are never tinted.** `themedControls()` and `themedChrome()`
  are iOS only.
- **The theme belongs to the Jellyfin profile**, persisted under
  `appearance.theme.<accountID>`, so the account picker and sign-in screens
  wear the look of whoever was just there.

Use native `.glass` actions and the existing circular control shape. The iOS
player's centre transport uses `.glass(.clear)` to keep the video visible
through it. Do not introduce `.glassProminent`, and avoid nested glass. Cards
over credits use translucent material so text underneath is blurred.

Role meanings, the two palettes' values, the account-ownership rule and the
bloom overlay are in [design notes](reference/design-system.md#themes).

## Focus strategy

The system `.card` button style owns focus lift and parallax. Do not add
custom focus scaling, competing backgrounds, or clipping around that control.
Preserve rail headroom and `.scrollClipDisabled()` so focused artwork can
lift. The existing artwork hue halo is an accent, not a replacement focus
treatment.

Never set foreground colors on a tvOS focusable control that draws the native
focused lozenge, or on an ancestor of it. Inherited white text can become
white on its white focused background. This applies to default and glass
controls. Card labels without that lozenge keep their semantic text colors.
Form rows need an explicit, appropriate control style. Test focused and
unfocused states.

## Components

- **Browsing:** reuse `MediaRail` and the existing media cards. Titles belong
  beneath posters. Keep horizontal gutters inside scroll content and leave
  focus padding intact. tvOS Library has five columns. iOS uses
  `PosterLayout`. A row of destination or filter chips — Discover's Movies,
  Shows, and Requests; the Requests page's filters — stays one row on every
  screen. On a phone it scrolls horizontally, with the gutter as a scroll
  content margin and no glyphs, and never folds into a column. The TV keeps a
  fixed row for its focus geometry.
- **Title art:** `TitleArtView` shows a library title's Jellyfin logo,
  `TitleArtImage` any logo URL, and both set the name in type when there is
  none. Seerr titles use the Jellyfin logo once the title is in the library.
  Discovery titles without a Jellyfin item use their name in type.
- **Top 10 shelves:** Home's Top 10 Movies and Top 10 Shows use landscape
  cards with an oversized ranked number beside each card. Keep the rank
  outside the focusable card so tvOS focus lift and accessibility remain owned
  by the native card control.
- **Heroes:** use the contained banner, artwork wash, and existing native
  paging behavior. Keep the focused/tappable control stable while artwork
  transitions. Home and Discover share the taller iPad layout, with the title
  and two-line synopsis in a bounded text column. Height can grow further for
  Dynamic Type. Ambient glow uses the shared palette and `AmbientGlowView`.
- **Details:** use `DetailPageScaffold`, `DetailMetadataHeader`,
  `DetailActionLayout` and `MetadataFlowLayout`, and reuse title art and cast
  components. The same scaffolding serves Jellyfin and Seerr pages, with
  request state standing in where a library title shows Play. `CastStrip`
  takes Jellyfin people or ready-made `CastCredit`s, which is how Seerr's TMDB
  credits reach the same strip.
  - `DetailActionLayout` lays out all four compositions once — one primary
    pill, the secondary controls, an optional accessory — so no page carries
    its own copy.
  - On a phone every secondary control is a glass circle, so the row never
    folds into a column. Use `DetailCircleButton` and `DetailCircleMenu`, not
    `.buttonStyle(.glass)` with a circular shape: its pressed highlight is a
    capsule sized to the label and shows through the circle as a lozenge.
  - The episode rail's `scrollPosition(id:)` is set only when the rail changes
    hands — load, season pick, after playback. Browsing never sets it, or the
    rail jumps under a moving focus.
  - Series playback actions describe the episode that will play: focused card,
    else the server's up-next, else the visible season's first. The watched
    toggle stops one step earlier, at the show.

  Per-orientation layout, the poster fallback, season opening rules and the
  tvOS synopsis reservation are in [design notes](reference/design-system.md#detail-pages).

- **Settings:** use native category navigation on each platform. iOS uses
  Forms, pickers, toggles, and Edit/reorder. tvOS keeps remote focus behavior.
  Home Rows is one list of every row rather than a section per source, since
  the viewer arranges them against each other; each row names its source under
  its title. Reordering is Edit and drag on iOS, and a pair of up/down glass
  buttons beside each row on the TV, where there is no drag.
- **Modals (tvOS):** a sheet with custom content ignores `presentationSizing`,
  so a panel states its own size — `Metrics.modalPanelSize` — or it fills the
  screen. The shape is the changelog's and the acknowledgements': a title, the
  scrolling content, and Done, laid out in sequence rather than as
  `safeAreaInset` overlays. Overlays draw over the content and need their own
  material to hide it. `onExitCommand` dismisses, so Menu and Done agree.
  Prefer a fixed size to a fitted one whenever the content can change while
  the panel is open, or it resizes under the viewer's focus. Never put
  `TVSettingsPage` in a sheet: it is the full-screen Settings *destination* —
  a 460pt identity column, a page-sized title, a Back button, and its own
  opaque background. Inside a sheet it reads as a page someone squeezed into a
  card.
- **Downloads (iOS only):** `DownloadControl` is a glass circle beside the
  detail page's other actions, in the same family as `ItemActionRow`'s
  toggles. Its glyph and a menu carry the entry's state through symbol weight
  and opacity, never color. Whether the account may download is
  `DownloadStore.permitted`, refreshed on account activation and on each
  detail page load. The control never resolves this itself: it renders nothing
  until download is allowed, and a task on a view that renders nothing never
  runs — so it could not have learned the answer that would make it appear.
  Its progress ring uses `downloadRingLineWidth` and `downloadMarkSize`. A
  poster's small "downloaded" badge on `PosterCard`, `LandscapeCard`, and
  `EpisodeCard` is `DownloadedMark`, sized by the shared `cardMarkSize`, which
  is equal on iOS. `DownloadsView` lists every downloaded title, reachable
  with no server at all. Library surfaces an entry point to it, and an offline
  banner when the server can't be reached. Settings
  > Downloads shows the count. Its Show Downloads button lands on that
  same Library list through the `showDownloadsList` environment action,
  because the Settings stack is destination-owned and the list's rows are
  route values. The two must not share a stack — see `ContentNavigationRoute`.
- **Watch Together:** `WatchTogetherControl` is the detail page's entry point,
  in the same family as the download control: a glass circle on a phone, the
  labelled pill where there is width. It renders nothing until the store says
  the account may join a group. `WatchTogetherSheet` is the modal panel above
  on tvOS, and on touch a `ThemedForm` in a `NavigationStack` with medium and
  large detents. The explainer under its title goes once the viewer is in a
  group, since that space is better spent on the room's own state.
  `SyncPlayToastLabel` is the player's transient line about the group: a
  material capsule at the top of the screen, SDR over whatever the video is,
  never hit-tested, and shared with the DEBUG gallery. `SyncPlayStateCopy` is
  the one place a group's state is put into words, so the sheet, the Together
  tab, and the banner never disagree.
- **QR codes (tvOS):** `QRCodeView` is how the TV hands an address to a phone,
  since tvOS cannot open a link. It is deliberately the one place that breaks
  the dark lock: a code needs dark on light with a quiet zone around it, so it
  draws its own card and does not follow the theme. The colours are the brand
  package's own monochrome pair, `lagoonInk` on `lagoonMist`, which is Lagoon's
  without anyone choosing it — about 16:1 where black on white is 21:1, and
  both are far above what a scanner needs. It is the *pair* that has to stay
  extreme: tinting the light half toward the accent is what would break it.
  Three more rules keep it scannable, and none of them is visible when broken.
  Scale with `.interpolation(.none)` — the generator emits one pixel per
  module and smoothing blurs them into each other. Keep the modules square;
  rounded or dotted ones look better up close and cost contrast at the
  distance a sofa actually is. The quiet zone is four modules, measured from
  the generated code rather than fixed, because a short address makes fewer
  and wider modules than a long one. Branding is the centre mark only, which
  correction level H is there to absorb: `LagoonSymbol` on a Mist plate
  covering `QRCode.markShare` of the width. Not the jellyfish, which the brand
  package restricts to small, low-contrast punctuation, and not on a dark tile,
  which the two-tone symbol's navy half would vanish into. The gap between
  symbol and modules is the part that matters. Without it the mark reads as a
  sticker dropped on the code rather than a hole punched in it, which is how
  the first version shipped and why it had to be redone. `QRCodeTests` renders
  the real view and decodes it, so growing the mark fails a test instead of
  quietly producing a code that only scans from two feet away.
  The address stays on screen in type beside it — the code is the quick way
  out, not the only one — and the code itself is hidden from VoiceOver so the
  address is not read twice.
- **Loading and failures:** use the shared state views. Keep mounted content
  during reconciliation and use inline retry when there is usable content.

## iPhone accessibility and browsing

`PosterLayout` scales cards, caption space, and columns together. Adaptive
actions measure intrinsic width and height before stacking. Segmented pickers
become menu pickers at accessibility sizes. Show phone synopses in full, give
title art a spoken title/header, and combine cast names and roles while
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
at 16 MiB and validated before decoding. Failed or incomplete images are not
cached. Top Shelf uses the same validated input before composition. Trickplay
has its own two-sheet decoded cache and 32 MiB compressed cache with the same
response cap.

For brand artwork, icon selection, detailed compositions, and the rationale
behind focus decisions, see the [design engineering
notes](reference/design-system.md).
