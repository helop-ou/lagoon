# Design System engineering notes

Why the [design system guide](../design-system.md) is shaped the way it is.
Token values live in the guide and `Lagoon/Shared/UI/DesignSystem.swift`.
These notes are not a release checklist or proof of hardware acceptance.

## Spacing and type

- `Metrics.Space` is one scale for both platforms. Internal rhythm does not
  need to shrink like structure does; gutters, card widths and hero heights
  follow the 10-foot safe zone and have their own tokens.
- Steps grow about ×1.5 after `s`, so adjacent steps look deliberately
  different. (Before the scale, views used 22 distinct spacing values and 71
  literals with no rule.)
- `.system(size:)` never appears in a screen. The only exceptions are SF
  Symbols used as artwork and logo-like display type, named in `Typography`
  (`glyph`, `largeGlyph`, `quickConnectCode`). Symbols sized with a semantic
  style (a placeholder glyph at `.title`) are fine.
- **One role, one style.** A synopsis was once `.body`, `.callout` and
  `.subheadline` on three screens. All are `.callout` now, the style for
  synopses, metadata, track names and button labels.

## Brand

The Twin Shores identity from the `lagoon-branding` package: three colours,
used **only** for branding (lockup, progress fills, selection markers,
onboarding wash).

**Black has to be stated, not inherited.** `.preferredColorScheme(.dark)` only
gives the system's dark backing, which on tvOS is a lifted grey tinted by
what is behind it (measured rgb(47, 45, 42) on Settings against rgb(0, 0, 0)
elsewhere). Any screen not covered edge to edge by content needs an explicit
background. `TVSettingsPage` and `SettingsView.splitLayout` carry it for the
whole settings hierarchy; onboarding uses `BrandBackground`.

Token names differ from the package on purpose:

- `.lagoonShore` (`#0D4A57`) is the mark's upper shore. The package calls it
  "Lagoon Teal", but `lagoonTeal` already names a bright accent here.
- `.lagoonAqua` (`#2ED4C7`) is the lower shore, the only brand colour bright
  enough to accent black.
- `.lagoonNavy` (`#0B1D28`) is the package's Deep Navy.

**`AccentColor` stays white, and no brand colour is ever assigned to it.** It
is the system-wide tint, so Aqua would repaint every button label, list row
and control. This has been got wrong twice. If a control looks wrong in white,
fix its button style (see `.glassProminent` below), not the accent.

**Backgrounds.** `BrandBackground` is flat, full-bleed Deep Navy, used by all
three onboarding screens so they read as one place. Past onboarding, content
plays against black. On iOS, server entry and sign-in put native text fields
straight on that background: plain style, a subtle bottom divider, 44 pt
minimum touch height; no `.roundedBorder` fields or grouped Form rows. tvOS
keeps its centred column and glass buttons.

**`LagoonLockup`** composes the mark, because the package has no
dark-background lockup (its colour lockup's Ink wordmark vanishes on black; its
white lockup merges the shores). Colour symbol plus Light wordmark keeps both.

- Proportions come from the package's horizontal lockup, which sets the
  wordmark almost twice as large relative to the mark as the stacked one, and
  centres it on cap height, not the ink box.
- The lockup applies its own clear space (half the symbol height on all
  sides) rather than trusting call sites.
- `scripts/import-brand-vectors.swift` imports the marks and crops each PDF to
  its ink, so `.frame(height:)` sizes the mark. Re-run it and re-measure if
  the artwork changes shape.

**The jellyfish** is the secondary accent. The package allows it only as
small, one-colour, low-contrast punctuation. It appears across onboarding and
nowhere else, at 0.15–0.30 opacity.

It swims (`JellyfishSwimLayer`), rebuilt as a parametric path from the same
geometry and deformed per frame, because moving the flat artwork reads as a
dragged sticker. Four coupled behaviours:

- The beat pushes **up**: it rises quickly while contracting and sinks slowly
  after (measured on device: +138 px over about a third of the beat, sinking
  about 2.5× slower).
- Over a beat, lift and sink cancel exactly. Position comes from a separate,
  much slower drift, so it hovers instead of climbing off screen.
- The bell narrows and lengthens rather than scaling.
- Tentacles lead the bell slightly, streaming behind a surge and curling on
  the sink.

Every value is a closed-form function of time, so the motion cannot drift or
desynchronise. Placement is per screen (`JellyfishSwimLayer.School`): the
connect and sign-in forms leave both flanks open; the picker's rail owns the
middle band and grows rightwards.

- The body stays upright and leans only into its sideways drift. Turned fully
  into its heading it swims on its side and reads as dead.
- Every drift stays clear of the centre column and the 5% overscan margin,
  body width included.
- `LagoonJellyfishAccent` is the still artwork and the Reduce Motion
  fallback.

## Iconography

SF Symbols, and **fill is not a free choice**: navigation (tabs, library rows)
and transport controls are filled; empty and error states are outline, since
they are pictures, not controls. `checkmark`, `chevron.*`, `plus`, `minus`,
`xmark`, `magnifyingglass` and `speedometer` have no filled variant.

Anything the app navigates to takes its glyph from `ContentIcon`, never a
string at the call site (the tab bar, library picker and Discover buttons once
drifted apart).

**Shape is a selection criterion.** `house.fill` and `gearshape.fill` anchor
the tab bar at 1.00–1.13 width-to-height and about 0.55 ink density. Glyphs far
from that look out of place (`film.fill` measured 1.28 wide and 0.85 dense;
`play.square.stack.fill` 0.75 wide). The set now spans 1.00–1.13:

| tab | glyph | w/h | ink |
| --- | --- | --- | --- |
| Home | `house.fill` | 1.13 | 0.55 |
| Discover | `sparkle` | 1.00 | 0.28 |
| Shows | `rectangle.stack.badge.play.fill` | 1.10 | 0.65 |
| Movies | `movieclapper.fill` | 1.04 | 0.73 |
| Libraries | `square.grid.2x2.fill` | 1.00 | 0.81 |
| Search | `magnifyingglass` | 0.99 | 0.26 |
| Settings | `gearshape.fill` | 1.00 | 0.56 |

- Shows is a stack (a series is a pile of episodes), which also separates it
  from Movies. Libraries is a grid so the two cannot be confused.
- Discover and Search are light by nature. SF Symbols has no solid magnifier,
  and circled forms read as buttons.

`everyContentIconResolvesToARealSymbol` checks each name exists on the
running OS. A missing symbol renders as nothing, with no crash or warning.

## Status glyph motion

Seerr's unsettled states animate their symbol **while their container holds
focus**: Processing rotates (`.rotate`), an active download bounces
(`.bounce`), Pending pulses (`.pulse`). Settled states (available, declined,
failed, removed, blocked) never move; a fact that wobbles reads as an error.

- Focus-gated because twenty animating cards is noise. `SeerrStatusLabel`
  reads `\.isFocused`, which reports the nearest focusable ancestor, so it
  works inside a card label or a button.
- **Symbol effects do not honour Reduce Motion on their own.**
  `SeerrStatusLabel` gates on `accessibilityReduceMotion`, like
  `HeroSection`'s carousel.
- tvOS availability: `pulse`, `bounce`, `variableColor`, `scale` are tvOS 17;
  `rotate`, `breathe`, `wiggle` tvOS 18; `drawOn`/`drawOff` tvOS 26.

## Focus strategy

**No custom focus scaling anywhere.** Cards use the system `.card` style (lift,
parallax, specular) via `cardButtonStyle()` (`.plain` on iOS), and that is the
whole indication. Selection elsewhere is a **weight** change, not a border or
colour.

**Artwork focus halo** (`artworkFocusHue`, tvOS only): the focused card casts
a soft halo in its artwork's colours, from the same `ArtworkPalette` as the
hero glow.

- Strictly additive: it grows through negative padding, not scale, so no card
  carries a focus-driven transform.
- Sampling waits 180 ms for focus to settle, because holding a direction
  walks a rail faster than artwork can be read.
- The palette cache holds 160 entries, so a sweep does not evict the hero's.
- `MediaRail`'s `ScrollView` needs `.scrollClipDisabled()`, or the halo is cut
  square at the rail's bounds.

**Buttons use `.glass` everywhere, including primary actions.**
`.glassProminent` fills with the accent, which is white, so it becomes a white
pill labelled in white. On tvOS a filled button at rest also looks like the
focused lozenge, so the page seems to have two focused controls. Prominence
comes from position and order. iOS follows the same rule for one design
language; do not reopen it per platform.

**Never set a foreground colour on a focusable control or any ancestor.** The
focused lozenge picks its own label colour for the white pill; an explicit
`.foregroundStyle` overrides it and the text vanishes when focused. It has
happened twice: `.foregroundStyle(.white)` on the player's panel card, and
`.primary`/`.secondary` selection on season chips (`.primary` is white here,
so the selected chip disappeared). Show selection with content (bold weight,
a checkmark). Hardcoded white is fine for non-focusable text over video, like
the transport title, timestamps and scrub chip.

**The rule is about the lozenge, not focus.** It binds styles that paint a
lozenge (`.glass` and the default `Button`), where even `.secondary` becomes
low-contrast grey on white. It does **not** bind `.card`, whose focus is lift
and parallax, so label colours survive. The poster caption, landscape and
episode overlays and hero synopsis correctly keep `.secondary`. An audit of
all 37 foreground overrides found each was non-focusable or `.card` content;
do not "fix" them.

**A tvOS `Form` row needs an explicit control style.** A default-styled
`Button` or `Toggle` in a tvOS `Form` does not flip its title colour under the
focused lozenge, so it renders white on white with no `.foregroundStyle`
involved (the trailing value does flip, which makes it look like a colour
bug). A real control style restores the flip. Settings no longer uses `Form`
on tvOS, but any future tvOS `Form` needs this. `Toggle` has no `.button`
style on tvOS, so the Playback HUD switch is a native button with a
checkmark.

### Settings uses platform-native category navigation

- The root is an index of destinations, not one form of every control. The
  categories match on both platforms.
- On tvOS the left column is identity (avatar, user, server, host, app
  version), not navigation. A short category list on the right opens focused
  `TVSettingsPage` destinations; glass rows and native menu pickers keep the
  system focus treatment. On iOS each row pushes a page in the Settings tab's
  `NavigationStack`.
- Account actions and playback diagnostics stay off the root.
- Both platforms use the same account-scoped preference stores and keys.
  Opening or moving between categories never changes a saved preference.

## Components

- **Rails** (`MediaRail`): `.headline` title and a `LazyHStack` at
  `cardSpacing`, gutter padding, asymmetric top/bottom padding for focus lift;
  the page ScrollView has `.scrollClipDisabled()`. On iOS every media rail
  uses 12 pt from heading to cards and 40 pt to the next heading (the same
  40 pt grids use between rows).
- **Any horizontal ScrollView of focusable things** puts the gutter _inside_
  the scroll content. A ScrollView clips at its edges, and the focused lozenge
  is larger than the resting frame, so a padded ScrollView slices the leading
  item flat. Inside an already-padded container (season chips in
  `DetailHeader`), use matching negative padding on the ScrollView so the clip
  lands at the screen edge. Check a _focused_ leading item: a straight edge
  where a capsule end should be is the tell.
- **Cards:**
  - `PosterCard` opens details. Artwork starts at 280×420 pt on tvOS and
    160×240 pt on iOS, scaled by `PosterLayout` with Dynamic Type.
  - `LandscapeCard` is 360×203 pt on tvOS and 240×135 pt on iOS; Continue
    Watching and Next Up give it a direct-play action.
  - `EpisodeCard` is 89% of `Metrics.landscapeWidth` at 16:9 (about 320×180 pt
    tvOS, 214×120 pt iOS). It opens details on iOS and plays on tvOS.
  - Progress uses the teal `ItemProgressBar`, hidden at ≥95% watched.
- **A poster's title goes under the artwork, never over it.** A scrim across
  the bottom third covers the part of the poster its designer cared most
  about. `PosterCard` shows name over year in a minimum-height caption so grid
  rows align at any text size. The gap above the caption must clear the
  **focus lift**, since `.card` grows the artwork past its resting edge. The
  landscape and episode cards still overlay their label, since a still is not
  a title card.
- **Genre cards:** on tvOS the name is centred both ways, up to two lines,
  inside 24 pt padding, over darkened artwork. iOS uses one bottom-leading
  line.
- **Library grid:** 5 columns on tvOS, not 6. Cards are fixed width, so
  dropping a column is what buys spacing, and captions need the vertical room.
  On iOS the grid sizes cards to columns: `PosterLayout.grid(fitting:)` fits
  as many columns as a 100 pt minimum allows on iPhone and 150 pt on iPad (by
  idiom, since a Pro Max reports regular width in landscape), and passes the
  card width through the `posterCardWidth` environment value. Poster rails,
  including More Like This, keep 160×240 pt. Both are Lagoon choices, not
  Apple sizes.
- **Hero** (`HeroSection`): a _contained_ rounded panel filled by the
  backdrop.
  - On tvOS it sets **no `clipShape`**. The `.card` style draws its plate at
    the system radius, and a second clip showed as a double edge when
    focused. The iOS banner keeps its own rounded clip and grows with Dynamic
    Type.
  - The title is the item's logo via `TitleArtView` at `heroLogoHeight`.
    Legibility comes from a **leading wash** over the text column only, like
    detail pages; no mask over a third of the image.
  - Paging: a native paging ScrollView on iOS. On tvOS Left/Right wraps
    through slides **without replacing the focused `.card`**, and Up/Down
    leave normally.
  - Auto-advance every 7 s while visible and idle, pre-warming adjacent
    artwork and palettes. Manual paging restarts the interval. tvOS focus,
    touch scrolling, hidden destinations, backgrounding, Reduce Motion and
    VoiceOver pause it; Reduce Motion still allows manual paging without the
    transition.
  - **The whole banner is the link** to the on-screen item's detail. There is
    no separate "See more" button. VoiceOver gets adjustable next/previous
    actions that keep activation.
  - Selection follows the item's ID across refresh and reorder, falling back
    to the first slide only if the title disappears.
- **Ambient glow** (`AmbientGlowView` + `ArtworkPalette`): three radial
  gradients at fixed points from the artwork's dominant colours, blur 120,
  bleeding 80 pt past the hero. The palette is a pure-Swift 4-bit RGB
  histogram ranked by `count × (saturation+0.05) × (brightness+0.1)` (the
  floors stop letterbox bars winning), sampled at 64×64 off-main and memoized
  per URL in `ArtworkPaletteCache`.
- **Detail pages (tvOS):** the backdrop is the full-bleed artwork.
  - Legibility comes from a **leading wash** (0.9 → clear by 68%), since the
    info block is left-aligned. A uniform scrim strong enough for text would
    flatten the whole still.
  - **No scroll-linked dimming.** It was cut: focus moving into a rail jumps
    further than any ramp, so it read as a slam to black. Rails stay legible
    because the wash covers the heading column and cards are opaque.
  - The hero space is a **scroll content margin, not a spacer view**. A
    spacer is non-focusable content above the first button, so Up from Play
    did nothing and the tab bar became unreachable.
  - Order: title art, facts line, genres, ★ rating, synopsis, actions, then
    cast and related rails, sized so the cast heading is on the first screen.
- **Detail pages (phone):** the same full-bleed artwork with a top-to-bottom
  wash from photographic at the title to near-black before the rails (a
  horizontal wash cannot protect full-width phone text). Tighter spacing,
  centred title art, and enough bottom runway to clear the floating tab bar.
  Play leads a native action group at `.controlSize(.large)`, 8 pt between
  circular actions: Apple's [accessibility
  guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)
  gives 44×44 pt as the default iOS control (28×28 minimum), and these are the
  most used actions.
- **Series pages describe an episode, not the show.** The header's label and
  synopsis follow the focused episode, else `Shows/NextUp?seriesId=` (the
  in-progress or next unwatched episode). Play, Resume and the watched toggle
  act on the same subject; the title art stays the show's.
  - The highlight is **not** cleared when focus leaves the rail: after
    browsing to E5, Play starts E5. It is cleared on a season change.
  - On iOS the header shows what's next, a native menu picks the season, and
    tapping an episode opens its details. tvOS plays the focused episode.
- **Facts line:** on tvOS one row: runtime, year, a _boxed_ certification (r4
  outline), then plain capability tokens from `MediaSource.qualityTokens`
  ("4K DV TrueHD 7.1 Atmos"). iOS splits identity facts and capabilities into
  two wrapping flows. Plain text, not capsules, which are too loud. The
  vocabulary lives in `MediaQuality`, so the player and detail page agree on
  what counts as 4K.
- **Title art** (`TitleArtView`): Jellyfin's `Logo` wordmark, with type as
  fallback. Logos are transparent PNGs of any aspect ratio, so they fit a box
  (`logoMaxWidth` × `logoMaxHeight`) rather than a fixed frame.
- **Cast** (`CastStrip`): circular portraits, name over role. A fixed,
  non-focusable row on tvOS (there is no person screen, and a focusable row
  that does nothing is worse); a scrolling row on iOS.
- **Overlays over credits** (the Up Next card): system translucent material,
  never a black wash. White credits on black show through any flat scrim as
  readable letters; only blur hides them. On tvOS the track panel is
  regular-material content with Liquid Glass tabs and actions, avoiding
  nested glass, and its height follows the selected tab.

## Themes

Mechanics behind the [guide's rules](../design-system.md#themes).

| Role | Use |
| --- | --- |
| `accent` | Progress fills, selection marks, the jellyfish, the focus halo's fallback |
| `ground` | Card washes and ambient glow |
| `background` | The surface behind content, and fades that carry artwork into the page |
| `surface` | Grouped-form rows, one step above background. Nil keeps the system grey, which suits black but clashes on rose |
| `glowDepth` | The third glow colour |
| `controlTint` | iOS native control tint. Kept pale because it fills whole toggle tracks |
| `artworkTint` | Blushes into every artwork glow and focus halo through `Theme.glow(for:)`, so a hero never hides the theme |
| `chrome` | Wash behind iOS tab and navigation bar glass, via `themedChrome()`. Keep it faint: at 0.7 the glass became a flat pane, so Baby Pink uses 0.25 of the ground |

Palettes:

- `AppTheme.lagoon`: Twin Shores over true black; controls in pale aqua (the
  accent lifted 40% toward white); no surface, artwork or chrome tint.
- `AppTheme.babyPink`: `#FFB7CF` accent, `#5E2848` rose ground, `#1F1019`
  background, `#33182A` rows; the accent as both tints, and a faint wash of
  the ground as chrome.

Where it applies:

- `TouchSettingsPage` wraps `ThemedForm` for settings categories.
  Acknowledgements, Downloads, Home Rows and the Seerr season picker use it
  directly.
- Plain scrolling pages (changelog, a licence, Seerr requests) sit on
  `Theme.background` like browse screens.
- Only the player's panel and the DEBUG Developer page keep the system form.
- tvOS's tab bar keeps the system glass.

**Account ownership.** `SessionStore` points `ThemeStore.shared` at the active
account with the other per-account stores, passing itself as owner. A nil
account counts only from the owner that activated the current one (the
`DownloadStore` rule): SwiftUI constructs the root session store more than
once, and the extras announce no account. With nobody active the last
profile's theme stays visible but stops saving. So the picker, sign-in and
add-account screens show the last viewer's look; an account re-signing in
after expiry shows its own; a launch with nobody remembered shows the brand.
Those screens use `GroundBackground` with the jellyfish in the theme accent.
`AccountLocalData` removes `appearance.theme.<accountID>` with the account, and
the regression reset clears it.

**The bloom.** Choosing a theme in Settings › Appearance plays
`ThemeBloomOverlay` from the root: a bloom of the new accent with the theme's
`bloomMotif` drifting up through it for under two seconds. Baby Pink's motif is
flowers; Lagoon's is the jellyfish, beating as it rises with the same
`JellyfishGeometry` as the sign-in screens. A new theme names its motif in
`AppTheme.bloomMotif`. Reduce Motion makes it a plain fade. It plays only for
a viewer's choice, never when loading a saved theme.

The tvOS player panel uses regular material for content with separate glass
tabs and actions; iOS uses a native resizable options sheet.

## Detail pages

How the shared scaffolding lays out per platform; the
[guide](../design-system.md#components) has the rules.

**Phone or compact-width iPad:** the landscape key art is the hero in both
orientations.

- Portrait: the hero fills `detailBackdropHeroShare` of the height with the
  art's middle, cropped at the sides. Title, facts, a wide Play (capped at
  `detailPlayButtonMaxWidth`) and circular actions sit over its lower part,
  with the full synopsis below.
- Landscape: the art fills the window, centred; a window wider than 16:9 trims
  top and bottom rather than padding the sides. Title art, actions and a
  smaller Play share one row along the lower part; facts and synopsis follow
  below the fold.
- No backdrop: the poster stands in. Top-anchored in portrait; in landscape
  shown whole over a blurred, dimmed copy (`detailPosterAmbientBlur`,
  `detailPosterAmbientDecodeSize`).
- Every secondary control is a glass circle, including From Beginning, so the
  row never folds. "Resume from" sits under the Resume pill.
  `DetailCircleButton` (and `DetailCircleMenu` for download menus) is a plain
  button under `.glassEffect(.regular.interactive(), in: .circle)`.

**Regular-width iPad:** landscape backdrop with more of it above the title,
and the leading column. **tvOS** keeps its own order.

**Series:**

- Playback actions describe the episode that will play: the focused card,
  else the server's up-next, else the visible season's first. So a finished
  show still offers Play.
- The watched toggle acts on the whole show, since on a finished show it
  clears everything, not episode one.
- The page opens on the up-next episode's season; a finished show opens on
  its first regular season, not Specials.
- The rail's position is a `scrollPosition(id:)` binding, set only on load, a
  season pick or after playback, never while browsing. Its gutter is a scroll
  content margin, so a scrolled-to episode lands at the gutter and a focused
  card's lift clears the edge.
- After playback the page follows the server's up-next, seasons away if
  needed, and drops any card picked before the session.
- On tvOS the series synopsis reserves three lines
  (`lineLimit(3, reservesSpace: true)`), even for an episode without one,
  because it sits above the rail and follows focus.
- Watched episodes carry `WatchedMark`, a checkmark on the same dark disc as
  the download badge, sized by `cardMarkSize` and inset by `cardMarkInset`.

## Image loading

The loader's shape; the [guide](../design-system.md#image-loading) lists the
limits.

- The cache probe in `CachedAsyncImage.init` is synchronous, so cached art
  never flashes a placeholder.
- The CGImageSource thumbnail decode runs off-main with an explicit
  `maxPixelSize` and `ShouldCacheImmediately`, so the render thread never
  decompresses a JPEG.
- Coalesced callers cancel independently; the transfer stops when the last
  waiter leaves.
- Failed images are never cached, so a broken URL cannot poison the cache.

Always pass a sensible `maxPixelSize`; full-size art on a rail card is the
difference between smooth and stuttering focus scrolling. Card budgets follow
layout size and display scale through `ArtworkSizing`; heroes and backdrops
use 1920, palette sampling 120.

## App artwork

Two scripts write the same catalogue:

- `scripts/generate-artwork.swift` draws the marks from code.
- `scripts/import-artwork.swift` builds every asset from supplied artwork.

```sh
scripts/import-artwork.swift --icon art/icon.png
scripts/import-artwork.swift --icon art/icon.png --topshelf art/banner.png
scripts/import-artwork.swift --back art/back.png --middle art/mid.png \
                            --front art/front.png --icon art/icon.png
```

**What to ask for when commissioning art:**

| asset | size | notes |
| --- | --- | --- |
| iOS icon | 1024x1024 square | opaque; the system masks it, so no rounded corners |
| tvOS icon | **2560x1536 (5:3)** | not square. A square source is fitted on the palette background and leaves a visible edge |
| tvOS parallax layers | 2560x1536 each, **alpha** | optional. Back is the opaque scene; Middle and Front are transparent except what should lift on focus |
| Top Shelf | 3840x1440 | wide banner, aspect-filled |
| Top Shelf Wide | 4640x1440 | wider still |

Everything is aspect-filled or fitted, never squashed. Only layers give the
tvOS focus parallax; a flat image makes a valid but static icon.

Keep sources under `art/` (gitignored) and commit only the generated
catalogue.
