# Design System engineering notes

Why the [design system guide](../design-system.md) is shaped the way it is.
Token values live in the guide and `Lagoon/Shared/UI/DesignSystem.swift`.
These notes are not a release checklist or proof of hardware acceptance.

## Spacing and type

- `Metrics.Space` is one scale for both platforms. Internal rhythm does not
  need to shrink like structure does. Gutters, card widths and hero heights
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
whole settings hierarchy. Onboarding uses `BrandBackground`.

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
straight on that background: plain style, a faint bottom divider, 44 pt
minimum touch height, with no `.roundedBorder` fields or grouped Form rows. tvOS
keeps its centred column and glass buttons.

**`LagoonLockup`** composes the mark, because the package has no
dark-background lockup (its colour lockup's Ink wordmark vanishes on black, and
its white lockup merges the shores). Colour symbol plus Light wordmark keeps
both.

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
connect and sign-in forms leave both flanks open. The picker's rail owns the
middle band and grows rightwards.

- The body stays upright and leans only into its sideways drift. Turned fully
  into its heading it swims on its side and reads as dead.
- Every drift stays clear of the centre column and the 5% overscan margin,
  body width included.
- `LagoonJellyfishAccent` is the still artwork and the Reduce Motion
  fallback.

## Iconography

SF Symbols, and **fill is not a free choice**: navigation (tabs, library rows)
and transport controls are filled. Empty and error states are outline, since
they are pictures, not controls. `checkmark`, `chevron.*`, `plus`, `minus`,
`xmark`, `magnifyingglass` and `speedometer` have no filled variant.

Anything the app navigates to takes its glyph from `ContentIcon`, never a
string at the call site (the tab bar, library picker and Discover buttons once
drifted apart).

**Shape is a selection criterion.** `house.fill` and `gearshape.fill` anchor
the tab bar at 1.00–1.13 width-to-height and about 0.55 ink density. Glyphs far
from that look out of place (`film.fill` measured 1.28 wide and 0.85 dense, and
`play.square.stack.fill` 0.75 wide). The set now spans 1.00–1.13:

| tab | glyph | w/h | ink |
| --- | --- | --- | --- |
| Home | `house.fill` | 1.13 | 0.55 |
| Discover | `safari.fill` | 1.00 | 0.68 |
| Shows | `rectangle.stack.badge.play.fill` | 1.10 | 0.65 |
| Movies | `movieclapper.fill` | 1.04 | 0.73 |
| Libraries | `books.vertical.fill` | 1.08 | 0.68 |
| Search | `magnifyingglass` | 0.99 | 0.26 |
| Settings | `gearshape.fill` | 1.00 | 0.56 |

- Shows is a stack (a series is a pile of episodes), which also separates it
  from Movies. Libraries is a shelf so the two cannot be confused.
- Discover is a compass. A sparkle now reads as AI.
- Search is light by nature. SF Symbols has no solid magnifier, and circled
  forms read as buttons.
- Settings categories each have their own glyph, never a tab's: Home Rows is
  `rectangle.grid.1x2.fill`, not the house. Seerr shares Discover's compass
  because it is the same service.

`everyContentIconResolvesToARealSymbol` checks each name exists on the
running OS. A missing symbol renders as nothing, with no crash or warning.

## Status glyph motion

Seerr's unsettled states animate their symbol **while their container holds
focus**: Processing rotates (`.rotate`), an active download bounces
(`.bounce`), Pending pulses (`.pulse`). Settled states (available, declined,
failed, removed, blocked) never move. A fact that wobbles reads as an error.

- Focus-gated because twenty animating cards is noise. `SeerrStatusLabel`
  reads `\.isFocused`, which reports the nearest focusable ancestor, so it
  works inside a card label or a button.
- **Symbol effects do not honour Reduce Motion on their own.**
  `SeerrStatusLabel` gates on `accessibilityReduceMotion`, like
  `HeroSection`'s carousel.
- tvOS availability: `pulse`, `bounce`, `variableColor`, `scale` are tvOS 17.
  `rotate`, `breathe`, `wiggle` are tvOS 18. `drawOn`/`drawOff` are tvOS 26.

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
language. Do not reopen it per platform.

**Never set a foreground colour on a focusable control or any ancestor.** The
focused lozenge picks its own label colour for the white pill. An explicit
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
all 37 foreground overrides found each was non-focusable or `.card` content.
Do not "fix" them.

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
  `TVSettingsPage` destinations. Glass rows and native menu pickers keep the
  system focus treatment. On iOS each row pushes a page in the Settings tab's
  `NavigationStack`.
- Account actions and playback diagnostics stay off the root.
- Both platforms use the same account-scoped preference stores and keys.
  Opening or moving between categories never changes a saved preference.

## Components

- **Rails** (`MediaRail`): `.headline` title and a `LazyHStack` at
  `cardSpacing`, gutter padding, asymmetric top/bottom padding for focus lift.
  The page ScrollView has `.scrollClipDisabled()`. On iOS every media rail
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
  - `LandscapeCard` is 360×203 pt on tvOS and 240×135 pt on iOS. Continue
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
- **Genre cards:** the name is centred both ways, up to two lines, inside
  24 pt padding, over darkened artwork, on every device.
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
    detail pages, with no mask over a third of the image.
  - Paging: a native paging ScrollView on iOS. On tvOS Left/Right wraps
    through slides **without replacing the focused `.card`**, and Up/Down
    leave normally.
  - Auto-advance every 7 s while visible and idle, pre-warming adjacent
    artwork and palettes. Manual paging restarts the interval. tvOS focus,
    touch scrolling, hidden destinations, backgrounding, Reduce Motion and
    VoiceOver pause it. Reduce Motion still allows manual paging without the
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
  act on the same subject. The title art stays the show's.
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
- **Cast** (`CastStrip`): circular portraits, name over role, in server
  order. Library people are a `RailShelf` of `.card` buttons with
  `.buttonBorderShape(.circle)`, so the system lift follows the circle. On
  tvOS only the portrait is the button and the name stays beneath, as in the
  profile picker. Everyone is listed, a missing headshot shows `person.fill`,
  and one person can appear once per credit (director and writer). Seerr's
  credits open the TMDB person's page. One without a TMDB id would open
  nothing, so a strip holding one stays a fixed, non-focusable row of
  `castCount` on tvOS: a focusable row that does nothing is worse. Search
  reuses the strip, titled "People", for Seerr's person results.
- **Person page** (`PersonDetailView`): headshot, name and the birth and death
  lines, then "In Your Library" as a poster rail, then, with Seerr connected,
  "More from TMDB" in Seerr's cards, then the biography. The rails come
  before the biography so focus lands on a title, not on a wall of text. On
  tvOS the biography's paragraphs are focusable so Down scrolls through them,
  and an empty library says so in a focusable line, so the page always has a
  focus target. A library person's page shows the TMDB rail only when it has
  titles, so without Seerr it is unchanged. A TMDB person's page takes its
  headshot and biography from Seerr, drops the library rail when the library
  does not know them, and always keeps the TMDB section, with a focusable
  line when it is empty.
- **Overlays over credits** (the Up Next card): system translucent material,
  never a black wash. White credits on black show through any flat scrim as
  readable letters. Only blur hides them. On tvOS the track panel is
  regular-material content with Liquid Glass tabs and actions, avoiding
  nested glass, and its height follows the selected tab.

## Themes

Mechanics behind the [guide's rules](../design-system.md#themes).

| Role | Use |
| --- | --- |
| `accent` | Progress fills, selection marks, the jellyfish, the focus halo's fallback |
| `ground` | Card washes and ambient glow |
| `background` | The surface behind content, and fades that carry artwork into the page |
| `surface` | Grouped-form rows, one step above background. Nil keeps the system grey, which suits black but clashes on plum |
| `glowDepth` | The third glow colour |
| `signal` | A colour of the theme's own family that stands apart from the accent, on a few small marks: a started series' unwatched count and the hero's current page dot. Bright enough for black figures on it (6.7:1 or better, which `AppThemeTests` checks). The accent's straight opposite was tried first and read as another app's colour |
| `controlTint` | iOS native control tint. Kept pale because it fills whole toggle tracks |
| `artworkTint` | Blushes into every artwork glow and focus halo through `Theme.glow(for:)`, so a hero never hides the theme |
| `chrome` | Wash behind iOS tab and navigation bar glass, via `themedChrome()`. Keep it faint: at 0.7 the glass became a flat pane, so Baby Pink uses 0.25 of the ground |

Palettes:

- `AppTheme.lagoon`: Twin Shores over true black. Controls in pale aqua (the
  accent lifted 40% toward white). Sand `#F2C46D` signal, the shore beside the water. No surface,
  artwork or chrome tint.
- `AppTheme.babyPink`: Orchid. `#E7B0DE` accent, `#400849` plum ground,
  `#160414` background, `#26092A` rows, `#FF5A0A` orange as the third glow,
  hot pink `#FF5FA2` signal. Controls in pale orchid `#EFC6E8`. No artwork tint, so posters
  keep their own colours, and a faint wash of the ground as chrome.
- `AppTheme.spooky`: `#FF8C1A` pumpkin accent, `#2B1433` aubergine ground,
  `#110B14` background, `#21152A` rows, `#5C2E91` purple glow. Controls in
  pale pumpkin `#FFB870`, signal in lifted violet `#B07CFF`. Its artwork tint
  is the purple, not the accent: an orange blush turned every page brown,
  which read as autumn rather than night.
- `AppTheme.winter`: `#9ADBFF` ice blue accent, `#0F2A4E` night blue ground,
  `#060C18` background, `#101C30` rows, `#4A5FD0` periwinkle as the third
  glow. Signal in berry red `#FF6464`, the one warm colour: a candle gold
  read as Lagoon's sand, and a green aurora glow as Lagoon's aqua. Controls
  in `#8FD0F7`, a step deeper than the accent, because a toggle's white knob
  was lost on anything paler. Its artwork tint is a cold blue `#3F74C9`:
  untinted, a warm poster's glow turned the whole page olive on the Apple TV.

Where it applies:

- `TouchSettingsPage` wraps `ThemedForm` for settings categories.
  Acknowledgements, Downloads, Home Rows and the Seerr season picker use it
  directly.
- Plain scrolling pages (What's New, a licence, Seerr requests) sit on
  `Theme.background` like browse screens.
- Only the player's panel and the DEBUG Developer page keep the system form.
- Every page's backdrop is `ThemePageBackground`, through
  `.themedPageBackground()` (`ThemedForm` uses it too), so Spooky's cobwebs
  and Winter's snow reach every page without the page knowing.
- tvOS's tab bar keeps the system glass.

**Account ownership.** `SessionStore` points `ThemeStore.shared` at the active
account with the other per-account stores, passing itself as owner. A nil
account counts only from the owner that activated the current one (the
`DownloadStore` rule): SwiftUI constructs the root session store more than
once, and the extras announce no account. With nobody active the last
profile's theme stays visible but stops saving. So the picker, sign-in and
add-account screens show the last viewer's look. An account re-signing in
after expiry shows its own. A launch with nobody remembered shows the brand.
Those screens use `GroundBackground` with the jellyfish in the theme accent.
`AccountLocalData` removes `appearance.theme.<accountID>` with the account, and
the regression reset clears it.

**The bloom.** Choosing a theme in Settings › Appearance plays
`ThemeBloomOverlay` from the root: a bloom of the new accent with the theme's
`bloomMotif` drifting through it for under two seconds. Baby Pink's motif is
flowers. Lagoon's is the jellyfish, beating as it rises with the same
`JellyfishGeometry` as the sign-in screens. Winter's is snowflakes
(`SnowflakeGeometry`), the one motif that falls instead of rising
(`BloomMotif.falls`). A new theme names its motif in
`AppTheme.bloomMotif`. Reduce Motion makes it a plain fade. It plays for a
viewer's choice and when switching to another profile, in that profile's
theme (`ThemeStore.bloomCount`), but never at launch and never on returning to
the same profile. An in-app switch waits until the picker has closed
(`MainTabView.finishProfilePicker`): switching under the closing picker
repainted it in the new theme on its way out, which looked like a clipped
bloom.

**The seasons.** `ThemeSeason.current(on:)` names the season a date falls
in: Spooky through October, Winter from 1 December to 6 January. A winter is
one season on both sides of New Year, known by the year it began in.
`ThemeStore.theme(for:in:on:)` resolves a profile's theme. It is the season's,
unless the profile turned Seasonal Themes off
(`appearance.followsSeasons.<accountID>`, on when absent) or chose a theme
during this season (`appearance.seasonDeclined.<accountID>` holds that
season's id, which `select` writes). Otherwise it is the saved choice.

- Nothing is saved when a season applies itself, so the profile's own theme
  is there when it ends. Settings › Appearance names the one that returns
  (`themeAfterSeason`).
- The picker shows the theme being worn. Choosing another during a season
  keeps it for the rest of that season. Choosing the season's own theme
  while wearing it changes nothing, so the profile's own still returns.
- Turning the switch on during a season forgets a choice made in it and
  brings the season's theme at once, with the bloom. Turning it off returns
  the profile's own the same way.
- `RootView` calls `refreshSeason()` on every return to the foreground, so a
  season that began or ended while the app slept turns the theme without a
  bloom.
- Both keys are per-account keys like the theme's, removed with the account
  and by the regression reset. Builds before the switch stored a bare year
  for a declined October, which matches no season's id.
- The tvOS Appearance UI test expects the season's theme as the starting
  value.

**Haunted.** Spooky decorates pages as well as colouring them
(`AppTheme.isHaunted`). `ThemePageBackground` draws `HauntedDecoration`
behind content:

- **Cobwebs** (`CobwebGeometry`) in the top corners, seeded, so the corners
  differ but never change. Each has a hub set out from the corner, twelve
  radials running to a straight frame thread tied to both screen edges, and a
  capture spiral that follows the frame and droops between radials, with a
  few strands broken. They fade from the hub by a radial gradient
  (`Metrics.cobwebSize` 300 on tvOS, 130 on iOS). A web that was only a fan
  from the corner, with no hub or frame, read as a seashell.
- **Spiders** (`SpiderGeometry`), seen from above: head with palps, a
  teardrop abdomen with the accent's hourglass, four jointed legs a side, the
  front pairs reaching forward. They are drawn in one layer so overlapping
  legs do not show through each other. One sits on the left web and one
  hangs head-down from the right, both on the web's steepest radial
  (`Metrics.cobwebSitterShare`, `cobwebHangerShare`), clear of the controls
  near each corner. The phone's sit high, because the Home hero covers
  everything below the status bar. The hanging spider lowers itself and
  climbs back over `Motion.spiderDrop` (`SpiderDrop`), swaying a little. It is
  the only part of the webs that redraws, in its own small canvas at 30 fps.
- **Passing ghosts** (`GhostFlight`): one crosses the page every two to four
  minutes, every one to two and a half after 19:00, and a flock of three
  every 45 to 90 seconds from 17:00 on 31 October until morning. The wait
  starts when a page appears, so a page left sooner never shows one. A ghost
  enters and leaves wholly off the page over `Motion.ghostCrossing`, mostly
  high up, where a Home hero leaves the backdrop open, and slips behind
  artwork elsewhere. It is a soft glow with a body fading toward its hem.
  A flat fill read as a grey sticker. The layer redraws only while one is in
  the air.

Nothing moves under Reduce Motion or while the player is up. The iOS player
is presented `.overFullScreen`, so the pages stay live under it and
`HauntedDecoration` reads `PlayerPresentationHub.request`. On tvOS the
player's `fullScreenCover` hides the pages without stopping their timelines:
on the Apple TV the hanging spider kept redrawing at the display's 24 Hz
under a film. So the cover's content counts itself on and off screen in
`PlayerPresence`, and the decoration rests while `isPlayerUp`. On
the TV it measured no spider frames during playback, and they were back as soon
as it closed.

A small `GhostGeometry` ghost also bobs above `LoadingView` and
`ErrorStateView`'s glyph (`ThemeStateGhost`, still under Reduce Motion).
Ghosts are pale, never the accent, with faces cut out by an even-odd fill so
they read over anything. Spooky's bloom motif is `.ghosts`. None of this
covers text or artwork, and none of it reaches the player or Top Shelf.

**Frost and snow.** Winter decorates pages too (`AppTheme.isSnowy`):
`ThemePageBackground` draws `WinterDecoration` behind the content, so it
shows in the gaps between rails and never over a poster.

- **Frost** (`FrostGeometry`, `FrostCorners`) in both top corners, where
  Spooky has its cobwebs. Each corner is a haze, a cluster of ice crystals and
  specks of ice, all fading away from the corner. The biggest crystal sits in
  the corner and smaller ones follow each edge, a little in or out of it.
  Seeded, so the corners differ but never change, and drawn once
  (`Metrics.frostSize` 340 on tvOS, 150 on iOS). A frost crystal is
  `SnowflakeGeometry.frostPath`: four pairs of branches an arm and a hexagon
  at its heart.
- **Snow** (`Snowfall`, `SnowfallFrame`) is a fixed, seeded set of flakes
  (`Metrics.snowflakeCount`, 56 on tvOS and 40 on iOS). Each keeps its own
  lane and depth. From `Snowfall.crystalDepth` on, a flake is close enough to
  be a crystal with six branched arms, turning slowly as it falls. Further
  off it is a soft dot that fades toward its edge, like something out of
  focus. A near flake is bigger, brighter and faster: it crosses the page in
  14 seconds and the farthest in 30.
- A flake's place depends only on the clock (`Snowfall.pose`), so every page
  shows the same snow and nothing jumps when one page covers another.
- **The moving snow is Core Animation layers** (`SnowfallLayers`,
  `SnowfallLayerView`): one small layer a flake, a shape layer for a crystal
  and a stretched soft-dot picture for the rest, each with endless fall, sway
  and spin animations that start where the wall clock has the flake. The
  render server moves them, so a snowing page costs the app nothing: on the
  Apple TV 4K it idles on Home at 0.2 to 0.8 % of a core, the same as the
  Lagoon theme. The first version drew every flake in one `Canvas` thirty
  times a second, which looked the same and took 33 % of a core, because the
  whole 4K layer was drawn again for each frame. Leaving the window or the
  foreground removes the animations, so the view builds them again when it
  comes back.
- Under Reduce Motion, and while the player is up (the `playerCover` rule
  the haunted decoration follows), the snow stands still: `SnowfallFrame`
  draws `WinterDecoration.stillMoment` once in a `Canvas`. On the Apple TV
  nothing of the snow was drawn during playback. The frost stays either way.

Tried and dropped: plain white discs for every flake read as dots, not
snow. Frost as feathered spines growing from the corner read as scribble.

**The elf.** `ElfVisitor` is part of a snowy page's backdrop. Now and then
an elf in a red cap slides down a rope at the side of the page, hangs there,
waves toward the page, and climbs back up hand over hand: 2.8 seconds down,
7 staying, 4.8 up in seven pulls (`ElfVisit.pose(at:)`).

- Elves are about on the days of `SeasonalCalendar.elves`. A page's first
  visit comes 20 to 50 seconds after it appears and the ones after it every
  100 to 220 seconds (`ElfVisit.plan`), each on either side, at its own
  place across the side's lane and its own depth. A page left before the
  wait is over never shows one.
- The elf hangs in the lane a page leaves open beside its content, so on a
  phone, where that lane is narrow, the content covers part of it, as it
  does Spooky's spider.
- It swings by a share of its own height, not by an angle: on a long rope
  an angle carried it out of its lane.
- It is drawn in a canvas its own size at thirty frames a second, and only
  while one is on the page, so a page costs nothing between visits. Never a
  full-screen canvas: see the snow above.
- Its red, skin and gold are `ChristmasInk`, the sleigh driver's.
- `-debug.elfVisit YES` sends one three seconds after a page appears and
  every five after, whatever the date, on a DEBUG build.

**Christmas.** `SantaOverlay` sits over the tabs like the fireworks and
flies `SantaFlight`: a gold sleigh and three pairs of reindeer on an arc
across the top of the page, the driver in red with a green sack, the lead's
nose glowing red, and gold dust that twinkles and falls behind. It takes
9.5 seconds to cross and the last dust is gone at 12.7. No sound.

- It is due the first time a profile is on screen on each day of
  `SeasonalCalendar.santa` (`Christmas.day(on:)`), 2.5 seconds after the
  page appears, so the page arrives first.
  `ThemeStore.welcomeSantaIfDue()` stores the day under
  `appearance.santaWelcomed.<accountID>`, so each profile sees it once on
  each day. A profile with Seasonal Themes off gets none.
- It never starts over a playing title, by the fireworks' rule: the overlay
  only asks while the scene is active and `playerCover` says no player is up.
- **The figures** are drawn in their own units, where a reindeer's body is
  100 long, and scaled so the team spans 46 % of the page's width, never
  under 280 points or over 900. Each figure sits on the arc by itself and
  leans with it. The arc's climb is limited by the page's width: by its
  height alone, a phone stood the team on end.
- **Colours** are `ChristmasInk`, not the theme's: gold reads as Christmas
  over any theme. Every colour is opaque. A see-through far reindeer read as
  a blur of the near one, so it is a darker gold instead. An all-gold driver
  read as a snowman, so he wears red.
- The page dims by 42 % while the sleigh is over it, or the gold is lost on
  bright artwork.
- Reduce Motion gets one still moment for four seconds.
- **In motion it is layers, not a canvas** (`SantaFlightLayers`). Each figure
  is a picture drawn once by `SantaArt`, each leg two shape layers swinging
  between stretched and gathered, and each mote a small layer. The team's
  path is sampled thirty times a second into keyframes, and the render
  server moves everything, so the app does nothing while the sleigh flies.
  `SantaFlightFrame`, the canvas, draws the same art once: the still moment
  and the snapshots. Both take their shapes and numbers from `SantaArt`,
  `SantaGeometry` and `SantaFlight`, so they cannot drift apart.
- **Why:** measured on the Apple TV 4K (3rd generation), Release, three
  alternating runs each. The canvas redrawn every frame held 50 to 56 frames
  a second on the main thread, with 30 to 83 frames late in an eleven-second
  flight, at 35 % of a core. The layers hold 60 with none late, at 1 %, and
  add nothing to the whole device's load. An empty full-screen canvas
  redrawn every frame held 60, half resolution did not help, and the team
  alone, with no glow and no dust, still lost frames: the cost is drawing
  the figures every frame, not the canvas or any one effect.
- `-debug.santaFlight YES` flies it on a DEBUG build.

**New Year.** `NewYearOverlay` sits over the tabs and plays `Fireworks` with
the year in gold for thirteen seconds, in every theme, with no sound. It
happens once a year, so it is meant to feel like an event.

- It is due the first time a profile is on screen on 1 January
  (`NewYear.year(on:)`), which covers Lagoon being open as the year turns: on
  31 December the overlay sleeps until midnight and asks again.
  `ThemeStore.welcomeNewYearIfDue()` stores the year under
  `appearance.newYearWelcomed.<accountID>`, so each profile sees it once a
  year. A profile with Seasonal Themes off gets none.
- It never starts over a playing title. The overlay only asks while the
  scene is active and `playerCover` says no player is up, so a year that
  turns during a film is welcomed when the player closes, if it is still
  1 January.
- **The show** (`Fireworks.show`) is fixed and seeded: one big shell in the
  middle, eleven that come closer together, and a volley of nine across the
  page from `Fireworks.finale`. Colours are the theme's accent and signal,
  gold and white. A shell climbs for 0.9 seconds and bursts with a flash.
  Its `Kind` sets the burst: a peony is a full ball, a chrysanthemum a thin
  shell with long tails, a willow slow gold that hangs and falls, a ring one
  clean circle about a small heart. Each spark is drawn as a tapering tail
  with a white-hot head, and from `Fireworks.glitterFrom` of its burn it
  glitters, blinking on its own beat as it dies. Like the snow it is a pure
  function of time, drawn in one `Canvas`.
- **The greeting** (`NewYearGreeting`) is "HAPPY NEW YEAR" in tracked
  capitals over the year in gold numerals (`Metrics.newYearNumeralSize`, a
  display size outside the Dynamic Type scale). The numerals pop in one
  after another with the opening burst, a shine crosses them three times,
  and four-pointed stars twinkle around them. The gold is the greeting's
  own: it is decoration, not text that takes a theme colour.
- A scrim of 0.7 black sits under it, so the page does not fight the show.
- Reduce Motion gets one still moment of the volley (`Fireworks.stillMoment`)
  for six seconds, the greeting at rest. VoiceOver hears the greeting as an
  announcement.
- `-debug.newYearFireworks YES` plays it once at launch in a DEBUG build.

Tried and dropped: fourteen shells of two neat rings each, with a plain
white "Happy New Year", looked lacklustre.

The tvOS player panel uses regular material for content with separate glass
tabs and actions. iOS uses a native resizable options sheet.

## Detail pages

How the shared scaffolding lays out per platform. The
[guide](../design-system.md#components) has the rules.

**Phone or compact-width iPad:** the landscape key art is the hero in both
orientations.

- Portrait: the hero fills `detailBackdropHeroShare` of the height with the
  art's middle, cropped at the sides. Title, facts, a wide Play (capped at
  `detailPlayButtonMaxWidth`) and circular actions sit over its lower part,
  with the full synopsis below. The circles keep one centred row and wrap
  only when they cannot fit. A series page's season picker takes its own
  line beneath them.
- Landscape: the art fills the window, centred. A window wider than 16:9 trims
  top and bottom rather than padding the sides. Title art, actions and a
  smaller Play share one row along the lower part. Facts and synopsis follow
  below the fold.
- No backdrop: the poster stands in. Top-anchored in portrait. In landscape,
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
- The page opens on the up-next episode's season. A finished show opens on
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

The loader's shape. The [guide](../design-system.md#image-loading) lists the
limits.

- The cache probe in `CachedAsyncImage.init` is synchronous, so cached art
  never flashes a placeholder.
- The CGImageSource thumbnail decode runs off-main with an explicit
  `maxPixelSize` and `ShouldCacheImmediately`, so the render thread never
  decompresses a JPEG.
- Coalesced callers cancel independently. The transfer stops when the last
  waiter leaves.
- Failed images are never cached, so a broken URL cannot poison the cache.

Always pass a sensible `maxPixelSize`. Full-size art on a rail card is the
difference between smooth and stuttering focus scrolling. Card budgets follow
layout size and display scale through `ArtworkSizing`. Heroes and backdrops
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
| iOS icon | 1024x1024 square | opaque. The system masks it, so no rounded corners |
| tvOS icon | **2560x1536 (5:3)** | not square. A square source is fitted on the palette background and leaves a visible edge |
| tvOS parallax layers | 2560x1536 each, **alpha** | optional. Back is the opaque scene. Middle and Front are transparent except what should lift on focus |
| Top Shelf | 3840x1440 | wide banner, aspect-filled |
| Top Shelf Wide | 4640x1440 | wider still |

Everything is aspect-filled or fitted, never squashed. Only layers give the
tvOS focus parallax. A flat image makes a valid but static icon.

Keep sources under `art/` (gitignored) and commit only the generated
catalogue.
