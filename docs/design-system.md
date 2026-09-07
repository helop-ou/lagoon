# Design system

The visual language is adapted from a 2026 streaming-app redesign: dark-locked,
system-semantic-first, tvOS 26 Liquid Glass, with brand color reserved for
genuine branding.

## Tokens (`Views/Components/DesignSystem.swift`)

Use tokens, not literals. tvOS values follow the 80 pt safe-zone gutter
convention; iOS scales down via `#if os(tvOS)`.

| Token | tvOS | iOS |
|---|---|---|
| `screenGutter` | 80 | 20 |
| `cardSpacing` | 40 | 14 |
| `posterWidth` (2:3) | 280 | 160 (grows with Dynamic Type) |
| `landscapeWidth` (16:9) | 360 | 240 |
| `heroHeight` | 620 | 200 (grows with Dynamic Type) |
| `gridColumns` | 5 | 2 baseline; adaptive to available width and Dynamic Type |
| rail padding (focus headroom on tvOS) | top 48 / bottom 96 | 12 / 40 |
| poster grid row spacing | 72 | 40 |

Shared radii: card 12, card artwork 10, badge 6, hero panel 32. Player
progress is a flat 6 pt rail with an attached time label and a transient
vertical scrub marker; Liquid Glass is reserved for action controls.
`Motion`: fast 0.2 / standard 0.4 / slow 0.6 / crossfade 0.8.

### Spacing scale (`Metrics.Space`, HEL-51)

Every gap and inset *inside* a screen picks a step. The structural values in
the table above stay separate — they answer to the 10-foot safe zone, not to
rhythm — and the scale is the same on both platforms, because internal rhythm
doesn't need to shrink the way structure does (giving iOS its own is HEL-41's
call).

| step | pt | for |
|---|---|---|
| `hair` | 2 | a label sitting on its value |
| `xs` | 4 | inside a control |
| `s` | 8 | between tight siblings |
| `m` | 12 | the default gap |
| `l` | 16 | between groups |
| `xl` | 24 | card padding, form rows |
| `xxl` | 40 | between sections |
| `section` | 56 | between major blocks |

Roughly ×1.5 after `s`, which is what makes adjacent steps read as different
rather than as a mistake. Before this existed there were **22 distinct
spacing values** across the views and 71 literals bypassing the tokens, with
no rule for when 10 versus 12 versus 14 applied — that arbitrariness, not any
single value, is what made spacing feel off.

### Type

Text uses the **semantic styles** so it scales and stays consistent, and each
one has a job:

| style | job |
|---|---|
| `largeTitle` | a screen's own name — the sign-in header, a detail page's title when there's no logo art |
| `title2` | the player's title block over the video, the largest thing in the player |
| `title3` | section headings inside a screen — "Episodes", an empty state's line |
| `headline` | rail titles and card headers |
| `callout` | **the workhorse**: synopses, metadata lines, track names, button labels |
| `footnote` | card titles on artwork, the player's facts line |
| `caption` | a poster's title, secondary labels |
| `caption2` | a poster's year, cast roles, the smallest supporting text |

`.system(size:)` appears nowhere in a screen. The only legitimate escapes are
SF Symbols used as artwork and display type that is effectively a logo, and
those are named in `Typography` (`glyph`, `largeGlyph`,
`quickConnectCode`). Adding a raw size to a view is the smell — it means a new
one-off is being invented. Symbols sized with a semantic style (a small
placeholder glyph at `.title`) are fine and aren't part of this table.

**One role, one style.** The audit's actual finding wasn't the rarely-used
styles — it was that a *synopsis* was set three different ways: `.body` on the
detail page, `.callout` in the hero, `.subheadline` in the player's info card.
Same content, three sizes, no reason. All three are `.callout` now.

## Brand

The Twin Shores identity, from the `lagoon-branding` package. Three colors,
and **only** for branding — the lockup, progress fills, selection markers, the
onboarding wash. Everything else uses `.primary`/`.secondary`/`.tertiary`,
`.fill.tertiary`, and materials. The app is locked dark at the `WindowGroup`
root and its backgrounds stay black.

**Black has to be stated, not inherited.** `.preferredColorScheme(.dark)` gets
you the system's dark backing, which on tvOS is a lifted grey that also picks
up a colour cast from whatever sits behind it: measured at rgb(47, 45, 42) on
the Settings pages against rgb(0, 0, 0) everywhere else, which is why Settings
read as belonging to a different app. Any screen not covered edge to edge by
its own content needs an explicit `.background(Color.black.ignoresSafeArea())`.
`TVSettingsPage` and `SettingsView.splitLayout` carry it between them for the
whole settings hierarchy, including every page pushed from it; onboarding uses
`BrandBackground` instead.

| token | hex | package name | role |
| --- | --- | --- | --- |
| `.lagoonAqua` | `#2ED4C7` | Aqua | the mark's lower shore; the only brand color bright enough to accent against black |
| `.lagoonShore` | `#0D4A57` | **Lagoon Teal** | the mark's upper shore |
| `.lagoonNavy` | `#0B1D28` | Deep Navy | the wash under onboarding, over black |

The names deliberately diverge from the package. What it calls "Lagoon Teal"
is the dark `#0D4A57`, while this codebase has always used `lagoonTeal` for the
bright accent — one word for two colors is a trap, so the roles are named after
the mark instead.

**`AccentColor` stays white, and no brand colour may ever be assigned to it.**
This has now been got wrong twice. It is the system-wide tint, so setting it to
Aqua does not accent one thing — it repaints every button label, every list
row, and every control in the app, which is the opposite of "brand colour only
for branding". Jaagop's call, and a standing one: "simple and white like
Infuse" (HEL-50, and again during the HEL-97 refresh). If a control looks wrong
in white, the button *style* is the culprit — see `.glassProminent` below —
never the accent.

**Backgrounds.** The guidelines call Deep Navy "the default full-bleed field",
and `BrandBackground` is that literal reading — flat, full-bleed Deep Navy. All
three onboarding screens use it, so they read as one place rather than three
that happen to share a palette. Past onboarding, black is the ground Lagoon
plays content against and `MainTabView` onwards is unchanged. Deep Navy is
RGB(11, 29, 40), so this is not far from black to begin with.

On iOS, server entry and sign-in keep their native text fields directly on that
background, with plain styling, a subtle bottom divider, and a 44 pt minimum
touch height. Neither boxed `.roundedBorder` fields nor grey grouped Form rows
belong on these onboarding screens. The username keyboard advances to Password
with Next; password and server address offer Go. The content scrolls with the
keyboard and larger Dynamic Type. tvOS keeps its centered onboarding column
and glass action buttons.

`LagoonLockup` composes the mark rather than shipping one asset, because the
package has no dark-background lockup: its color lockup sets the wordmark in
Ink `#07161D`, invisible on black, and its white lockup flattens the two shores
into one silhouette. Color symbol + Light wordmark keeps both. Its proportions
are measured from the package's own lockups, which do not agree with each other
— the horizontal one sets the wordmark nearly twice as large relative to the
mark as the stacked one does, and centres it on cap height rather than on its
ink box.

`LagoonLockup` applies its own clear space — "equal to half the symbol height
on all sides", per the guidelines — rather than leaving it to call sites, which
had already broken the rule at every one of its four placements.

`scripts/import-brand-vectors.swift` brings the marks in and crops each PDF to
its ink, so a `.frame(height:)` sizes the mark and not the page's padding.
Re-run it, and re-measure the ratios, if the artwork changes shape.

The jellyfish is the secondary accent, and the package restricts it: "only as
punctuation in loading, empty-state, or atmospheric moments … small, one-color,
and low contrast." It appears across onboarding and nowhere else in the app —
Jaagop's call, for uniformity across the three screens, and further than the
letter of that rule goes. Held to the rest of it: one colour, small, and
0.15–0.30 opacity.

There it swims (`JellyfishSwimLayer`). Moving the supplied artwork along a path
would read as a sticker being dragged, so the mark is rebuilt as a parametric
path from the same geometry and deformed per frame. What sells it is that four
things are coupled:

- The beat pushes **up**. Lift takes the shape of the contraction, so the animal
  rises quickly while it squeezes and sinks slowly while it does not — it holds
  height only while working for it, the way someone treading water goes under
  the moment they stop. Measured on device: +138 px of rise over roughly a third
  of the beat, then a sink about two and a half times slower.
- Over a beat, lift and sink cancel exactly. Where it actually ends up is a
  separate, far slower drift, so it hovers rather than climbing off the screen.
- The bell narrows and elongates rather than scaling.
- The tentacles answer a slightly earlier moment than the bell, streaming out
  behind a surge and curling under on the sink.

Every value is a closed-form function of time, so nothing integrates frame to
frame and the motion cannot drift or desynchronise.

Placement is per screen (`JellyfishSwimLayer.School`), because the free water
is not the same on each: the connect and sign-in forms are a narrow centred
column with both flanks open, while the picker's rail owns the middle band and
grows rightwards as accounts are added.

Two further rules, both learned the hard way: the body stays upright and leans
only into its sideways drift — turned fully into its heading it swims flat on
its side, which reads as a dead one and stops being recognisable as the mark —
and every drift stays clear of both the centre column and the 5% a TV may
overscan, body width included.
`LagoonJellyfishAccent` remains as the still artwork, and is what Reduce Motion
falls back to.

## Iconography

SF Symbols, and **fill is not a free choice**. Three families, each internally
consistent:

| family | style | examples |
| --- | --- | --- |
| Navigation — tabs, library rows | **filled** | `house.fill`, `movieclapper.fill`, `rectangle.stack.badge.play.fill`, `gearshape.fill` |
| Transport — player controls | **filled** | `play.fill`, `pause.fill`, `forward.end.alt.fill` |
| Empty and error states | **outline** | `exclamationmark.triangle`, `play.slash`, `tray`, `wifi.exclamationmark` |

Filled for navigation is the platform convention and it is what survives being
read across a room. Outline for empty states keeps artwork from shouting —
those are pictures, not controls.

A literal "everything filled" is neither achievable nor desirable: `checkmark`,
`chevron.*`, `plus`, `minus`, `xmark`, `magnifyingglass` and `speedometer` are
strokes by construction and have no filled variant.

Anything the app *navigates to* takes its glyph from `ContentIcon`, not from a
string at the call site. The tab bar, the library picker row and Discover's
catalogue buttons had each spelled Movies and Shows themselves and drifted
apart — two of them outline, the rest filled.

**Shape is a selection criterion, not only meaning.** Measured at a common
point size, `house.fill` and `gearshape.fill` are the tab bar's fixed anchors
at 1.13 and 1.00 width-to-height and ~0.55 ink density; anything that strays
far from them reads as out of place, which is exactly how Movies looked.
`film.fill` measured 1.28 wide and 0.85 dense — simultaneously the widest and
the heaviest glyph in the bar — while `play.square.stack.fill` was 0.75, the
outlier at the opposite end, so the two sat beside each other mismatched in
both directions. The set is now 1.00–1.13 wide.

| tab | glyph | w/h | ink |
| --- | --- | --- | --- |
| Home | `house.fill` | 1.13 | 0.55 |
| Discover | `sparkle` | 1.00 | 0.28 |
| Shows | `rectangle.stack.badge.play.fill` | 1.10 | 0.65 |
| Movies | `movieclapper.fill` | 1.04 | 0.73 |
| Libraries | `square.grid.2x2.fill` | 1.00 | 0.81 |
| Search | `magnifyingglass` | 0.99 | 0.26 |
| Settings | `gearshape.fill` | 1.00 | 0.56 |

Shows is a stack because a series is a pile of episodes, which is also what
tells it apart from Movies at a glance; Libraries is therefore a grid rather
than a stack, so the two cannot be confused. Discover and Search are the two
light glyphs in the bar at 0.28 and 0.26 — that is what a sparkle and a
magnifier *are*, and forcing either heavier would make it something else.
Search is also the one navigation glyph with no filled variant to choose:
SF Symbols draws no solid magnifier, and the circled forms read as a button
rather than a tab.

`everyContentIconResolvesToARealSymbol` asserts each name is a real symbol on
the running OS: a missing one renders as nothing at all — no crash, no warning,
just a hole in the tab bar.

## Status glyph motion

Seerr's unsettled states animate their SF Symbol **while the thing they sit in
holds focus** (HEL-117): Processing turns its refresh arrows (`.rotate`),
a moving download bounces its arrow (`.bounce`), Pending fades (`.pulse`).
Settled states — available, declined, failed, removed, blocked — do not move.
A fact that wobbles reads as an error.

Focus-gated on purpose: twenty request cards animating at once is noise, one
animating because you are looking at it is the tvOS idiom. `SeerrStatusLabel`
reads `\.isFocused`, which reports the nearest focusable ancestor, so it works
unchanged inside a card's label and inside a button.

**Symbol effects are not assumed to honour Reduce Motion.** `SeerrStatusLabel`
gates on `accessibilityReduceMotion` itself, the same way `HeroSection` gates
its carousel. Verified by diffing screenshot bursts of the focused badge: five
of six frames differ with the setting off, one of six with it on, against a
static control region that never changes.

Symbol-effect availability on tvOS, if you reach for another one: `pulse`,
`bounce`, `variableColor` and `scale` are tvOS 17; `rotate`, `breathe` and
`wiggle` are tvOS 18; `drawOn`/`drawOff` are tvOS 26.

## Focus strategy

**No custom focus scaling anywhere.** Cards rely on the system `.card` button
style (lift/parallax/specular) via the `cardButtonStyle()` helper (`.plain`
on iOS).

**Artwork focus halo** (`artworkFocusHue`, HEL-139, tvOS only): the focused
card also casts a soft halo in its own artwork's colours, from the same
`ArtworkPalette` sampler the hero glow uses. It is strictly additive — the
system lift is still the whole of the movement, and the halo is grown with
negative padding rather than a scale so nothing in a card carries a
focus-driven transform. Sampling waits 180 ms for focus to settle, because
holding a direction walks a rail faster than artwork can be read, and the
palette cache holds 160 entries so a sweep does not evict what the hero
warmed. `MediaRail`'s own `ScrollView` carries `.scrollClipDisabled()`: without
it the halo is sliced square at the rail's bounds. Buttons use `.glass` — **everywhere, including primary actions**.
`.glassProminent` fills with the app's accent, and the accent is white
(Jaagop's call: "simple and white like Infuse"), so a prominent button is a
white pill the system then labels in white: invisible. The reference's own
Play and Trailer are plain glass pills too, so prominence comes from
position and order, never from a filled colour.

Revisited for **iOS specifically** on 2026-08-18 (HEL-50) and confirmed
uniform, because the two platforms hold the rule for different reasons and
only one of them is forced. On tvOS it is a hard constraint: the accent is
white, so a prominent fill at rest is indistinguishable from the focused
lozenge and the page reads as having two focused controls. On touch there is
no lozenge to collide with, so there it is purely Jaagop's call — and the
call is the same, one design language across both. Don't reopen it per
platform; `.glassProminent` stays unused app-wide.

**Focus drives nothing else.** The `.card` style's lift, parallax and
specular *is* the indication. The poster title reveal that used to live here
went with the overlay it revealed (HEL-51). Selection elsewhere is a
**weight** swap, not a border and not a color (see below).

**Never set a foreground color on a focusable control or on any ancestor of
one.** The focused lozenge picks its own label color to sit on the white
pill; an explicit `.foregroundStyle` propagates into the label, wins, and the
text disappears at exactly the moment it matters. This has bitten twice
(HEL-50): `.foregroundStyle(.white)` on the player's panel card, which
wrapped every track row, and `.primary`-vs-`.secondary` selection coloring on
the series season chips — `.primary` is white under this app's dark scheme,
so the *selected* chip was the invisible one. Express selection through
content (bold weight, a checkmark), and let hardcoded white stay where it
belongs: non-focusable text over video (transport title, timestamps, scrub
chip), which has no lozenge to fight.

**The prohibition is about the lozenge, not about focus.** It binds the
styles that *paint* one — `.glass` and the bare default `Button` — and there
`.secondary` inside a label is as wrong as `.white`, because it resolves to a
low-contrast grey on the white pill. It does **not** bind `.card`, whose
whole indication is lift, parallax and specular: label colours survive focus
untouched. So the poster caption, the landscape and episode card overlays and
the hero synopsis all keep `.secondary` inside their labels, correctly — a
full audit on 2026-08-18 (HEL-50) checked all 37 foreground overrides in the
app and every one is either non-focusable decoration or `.card` content.
Don't "fix" those.

**A tvOS `Form` row needs an explicit control style, or the same bug comes
back by another route (HEL-62).** The rule above is about foreground
overrides; this one isn't. A *default-styled* `Button` or `Toggle` inside a
tvOS `Form` does not flip its title colour under the focused white lozenge,
so the label renders white-on-white and vanishes — with no
`.foregroundStyle` anywhere near it. Oddly the row's trailing *value* flips
correctly, which is what makes it look like a colour bug rather than a
styling one.

Giving the control a real style restores the flip. That was the original
HEL-62 fix, and it still applies to any `Form` a future screen puts on tvOS
— but **Settings no longer has one**: it was rebuilt as a two-pane layout
(below), so `Form` is now an iOS-only shape in this app. `Toggle` also has
no `.button` style on tvOS at all, which is why the Playback HUD switch is a
native button stating itself with a checkmark — content, not chrome.

### Settings uses platform-native category navigation

Both platforms organize settings into Account, Playback, Audio, Subtitles,
Home Rows, Seerr, Advanced, and About, with Developer available in Debug.
The root is an index of destinations, not a form containing every control.

On tvOS, the left column is *identity, not navigation*: avatar, user, server,
host, and app version. A short category list on the right opens focused
`TVSettingsPage` destinations. Glass navigation rows and native menu pickers
retain the system's focus treatment and label colors.

On iOS, a native grouped Form starts with an Account row showing the active
user and server. Preferences groups Playback, Audio, Subtitles, and Home Rows;
Services contains Seerr; Application contains Advanced, Developer, and About.
Each row pushes a page in the Settings tab's existing NavigationStack, with
native back navigation and navigation-link pickers for longer choice lists.

Playback owns skipping, autoplay, and cellular quality. Audio owns audio
language defaults. Subtitles owns language defaults, missing-subtitle behavior,
search providers, and a separate Subtitle Appearance page with its preview.
Account actions and playback diagnostics are kept off the root. The same
account-scoped preference stores and persisted keys back the reorganized pages;
opening or navigating between categories must not change a saved preference.

## Components

- **Rails** (`MediaRail`): `.headline` title + `LazyHStack` at `cardSpacing`,
  gutter padding, asymmetric top/bottom padding for focus lift; the page
  ScrollView carries `.scrollClipDisabled()`.
  On iOS, 12 pt separates the heading from its cards and 40 pt separates
  the cards/captions from the next shelf heading. Home, Discover, Search,
  and episode/genre/collection rails share this rhythm; poster grids also
  leave 40 pt between rows. Horizontal card spacing stays unchanged.
- **Genre cards**: on tvOS, movie and show genre names are centered on both
  axes and can wrap onto two centered lines. Keep the title inside the card's
  24 pt padding and darken the artwork behind its center for contrast. The
  native `.card` focus treatment and rail focus headroom remain unchanged.
  iOS retains its bottom-leading single-line treatment.
- **Any horizontal ScrollView of focusable things** puts the gutter *inside*
  the scroll content, never on the ScrollView itself — a ScrollView clips at
  its own edges, and the focused lozenge is bigger than the resting frame, so
  a leading item gets its rounded end sliced flat. If the row sits inside an
  already-padded container (the season chips live in `DetailHeader`'s gutter),
  escape it with a matching negative padding on the ScrollView so the clip
  boundary lands at the screen edge. Zoom in on a *focused* leading item to
  check: the tell is a straight vertical edge where a capsule end should be.
- **Cards**: `PosterCard` (260×390, navigates), `LandscapeCard` (360×202,
  plays directly — used for Continue Watching / Next Up), `EpisodeCard`
  (320×180). All carry the teal `ItemProgressBar`, hidden at ≥95 % watched.
- **A poster's title goes *under* the artwork, never over it** (Jaagop,
  2026-08-17): a scrim and a headline across the bottom third cover the part
  of a poster its designer cared most about, and a poster is already a title
  card. `PosterCard` shows the name over the year beneath the art, in a
  fixed-height caption so grid rows stay aligned whatever the title length.
  The gap above that caption has to clear the **focus lift**, not merely look
  right at rest: `.card` scales the poster about a tenth, so a 390 pt one
  grows ~20 pt past its resting bottom edge and lands on the title. Same
  family as the ScrollView rule above — a focused card is bigger than the one
  you laid out.
  The landscape and episode cards still overlay, because a still is not a
  title card and the episode label is the only thing identifying it — worth
  revisiting together.
- **Library grid**: 5 columns on tvOS, not 6. The cards are fixed width, so a
  flexible column can't widen a gap without room to grow into — dropping a
  column is what actually buys the spacing, and the caption under each poster
  needs the vertical room too. On iOS, the 160 × 240 pt poster baseline gives
  typical portrait phones two columns; narrower layouts and larger text use
  fewer, while wider layouts fit more. The same baseline applies to poster
  rails, including More Like This, Search and Discover. It is a Lagoon design
  choice, not an Apple-prescribed poster size.
- **Hero** (`HeroSection`): a *contained* rounded panel, not a full-bleed
  banner, with the backdrop filling **all** of it. On iOS the 200 pt landscape
  banner anchors its title and two-line synopsis toward the bottom-left,
  with page dots centered below them. Text-only titles use at most two lines.
  It keeps its rounded clip and grows
  at larger Dynamic Type sizes so the shorter banner does not crush text.
  On tvOS it sets **no `clipShape` of its own** — the `.card` button style
  draws its plate at the system's corner radius, and a competing r32 clip
  left the plate's corners peeking out behind the panel's as a double edge
  when focused. The title is the
  item's own logo art via `TitleArtView` at `heroLogoHeight`, matching the
  detail pages. The mask that used to fade the artwork's leading third into
  flat material is gone (Jaagop: it read as a grey wash over a third of the
  image); legibility now comes from the same **leading wash** the detail pages
  use — darken only the column the text occupies and let the rest of the still
  be itself. On iOS a native horizontal paging ScrollView follows left/right
  swipes and settles on a full slide, with normal bounce at either end;
  vertical swipes still scroll the page. On tvOS Left/Right wraps through
  slides without replacing the focused `.card`; Up/Down still leaves the
  banner normally. Both Home and Discover use this shared behaviour.
  Auto-advances every 7 s while visible and idle, pre-warming adjacent artwork
  and palettes. Manual paging restarts the interval; tvOS focus, touch scrolling,
  hidden destinations, backgrounding, Reduce Motion and VoiceOver pause it.
  Reduce Motion still allows manual paging without added transition animations.
  tvOS text transitions asymmetrically (in: 0.3 s delayed, out: 0.2 s).
  **The whole banner is the link** — focus it, click it, get the detail page
  for whatever is on screen. It carried a "See more" button until 2026-08-17,
  which was a second thing to aim at for the one thing the banner already
  meant. Dots: 8 pt capsules, 24 pt when active. VoiceOver exposes the slide
  position and adjustable next/previous actions without removing activation.
  Selection follows the item's ID across refresh/reordering, falling back to
  the first slide only if that title disappears.
- **Ambient glow** (`AmbientGlowView` + `ArtworkPalette`): three radial
  gradients at fixed unit points from the artwork's dominant colors, blurred
  120, bleeding 80 pt past the hero panel. Palette extraction is a pure-Swift
  4-bit RGB histogram ranked by `count × (saturation+0.05) × (brightness+0.1)`
  (the floors stop letterbox bars from winning), sampled at 64×64 off-main,
  memoized per URL in `ArtworkPaletteCache`.
- **Detail pages** (HEL-46, built against Jaagop's Infuse reference — the
  earlier poster-left composition is gone): the backdrop **is** the artwork,
  full-bleed. On tvOS legibility comes from a **leading wash** (0.9 → clear by
  68 %) rather than a uniform scrim, because the info block is left-aligned:
  that keeps the right of the still vivid, which a scrim strong enough for
  text over busy artwork would flatten. There is no dark panel and **no
  scroll-linked dimming** — the latter was tried and cut
  (Jaagop: "not a big fan of the screen going black"), because moving focus
  into a rail jumps further in one press than any sensible ramp covers, so it
  read as a slam to black. The tvOS rails stay legible on their own: the
  leading wash covers the column the headings and names sit in, and the cards
  are opaque artwork. iOS uses the static vertical treatment described below.
  The hero space is a **scroll content margin, not a spacer view**: as a
  spacer it was non-focusable content above the first button, which left
  focus unable to climb back out — Up from Play did nothing and the tab bar
  stayed off-screen and unreachable. Order: title art, facts line, genres,
  ★ rating, synopsis, actions, then cast and related rails, sized so the
  cast heading is already on the first screen.
- **Series pages describe an episode, not the show** (Infuse behaviour): the
  header's label and synopsis come from whichever episode the rail has focus
  on, falling back to `Shows/NextUp?seriesId=` — the in-progress episode, or
  the next unwatched. Play, Resume and the watched toggle all act on that
  same subject, so the page always answers "what happens if I press Play".
  The title art stays the show's. The highlight is **not** cleared when focus
  leaves the rail — having browsed to E5, moving up to Play should start E5
  rather than snapping back — but it is cleared on a season change, since
  those episodes are gone. On iOS the header describes what's next, a native
  menu selects the season, and tapping an episode opens its own details before
  playback. tvOS still starts the focused episode directly.
- **Phone detail composition** (HEL-41): iOS keeps the same full-bleed artwork,
  but a top-to-bottom wash moves from photographic at the title to near-black
  before the rails. A horizontal wash cannot protect full-width phone text,
  and leaving the still equally vivid behind cast and episodes made the whole
  page read as wallpaper. Header and section spacing are tighter, title art is
  centered in the full-width phone column, Play leads a native large touch-action
  group, cast captions are phone-sized, and the final rail gets enough bottom
  runway to clear the floating tab bar.
  The shared metadata header uses `.controlSize(.large)` on iOS for Play,
  Resume, watched/favorite and synopsis buttons. The season picker retains its
  native menu presentation. Glass styling and system label sizing remain
  native, with 8 pt between the circular actions;
  `AdaptiveActionStack` still stacks actions when their labels don't fit.
  Apple's [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility)
  lists a 44 × 44 pt default iOS control size (28 × 28 pt minimum) and stresses
  spacing as well as size. Use generous native controls for these frequent
  actions, not the compact minimum, and verify with larger Dynamic Type too.
- **Facts line**: on tvOS this is one spaced row — runtime, year, a *boxed*
  certification (r4 outline), then plain capability tokens from
  `MediaSource.qualityTokens` ("4K  DV  TrueHD 7.1  Atmos"). iOS splits identity
  facts and playback capabilities into separate wrapping flows. Tokens move
  together where possible, but may wrap internally at accessibility sizes
  when a single value is wider than the viewport. Plain text, not
  capsules — outlined chips read far louder than the facts deserve. The
  vocabulary lives in `MediaQuality` so the player's facts line and the detail
  row can't disagree about what counts as 4K.
- **Title art** (`TitleArtView`): Jellyfin has a `Logo` — the title's own
  wordmark — for practically every film, and it is the title treatment on
  detail pages, with type as the fallback. Logos are transparent PNGs at
  wildly varying aspect ratios, so they get a box to fit inside
  (`logoMaxWidth` × `logoMaxHeight`) rather than a fixed frame; height is
  what makes a wide wordmark and a stacked one read as one design.
- **Cast** (`CastStrip`): circular portraits, name over role. A fixed
  non-focusable row on tvOS — there is no person screen to navigate to, and
  a rail you can focus but not act on is worse than a short honest one — and
  a scrolling one on iOS, where touch needs no focus.

### iPhone accessibility and browsing

- `PosterLayout` scales cards, caption space, and grid columns together with
  Dynamic Type. Decode and server image sizes use display-scale pixels, not
  point dimensions; a changed decode size also reloads `CachedAsyncImage`.
- `AdaptiveActionStack` stacks actions when their intrinsic widths do not fit.
  Its horizontal candidate measures both ideal width and height, including
  inside Forms. Native segmented pickers become menu pickers at accessibility
  sizes rather than truncating their choices.
- Phone synopses expand in place. Title artwork has a spoken title/header,
  and cast portraits are decorative within combined name/role elements.
  Text over phone backdrops uses a stronger wash and primary contrast.
- iPhone Close, Info, and Play/Pause use the native navigation toolbar, outside
  the video's tap gesture surface. The playback panel is a native sheet with a NavigationStack, Form,
  native picker and steppers, selected track semantics, and Done. The custom
  timeline exposes an adjustable playback position to VoiceOver, and transport
  controls remain visible while VoiceOver is enabled. tvOS keeps its mounted,
  focus-driven panel and existing remote commands.
- Home Rows uses native toggles and Edit/reorder on iPhone. System caption
  appearance hides the inactive Lagoon appearance controls.
- Search rails open full results through See All (in iPhone headings; rail-end
  cards on tvOS). `SearchResultsView` pages with Load More, preserves loaded
  results on errors, and advances using raw server cursors before filtering
  or deduplicating. Seerr identities include media type as well as TMDB id.

- **Overlays over credits** (HEL-66): anything the player floats during an
  episode's end titles — the Up Next card today — uses a system translucent
  material, never a black wash. Credits are white text on black, and a flat
  scrim lets them through at any opacity as *readable letters*; only blurring
  actually stops it. The track panel is a centered regular-material content
  sheet with Liquid Glass tabs and actions above/inside it; this preserves
  Apple's functional-layer hierarchy and avoids nesting glass inside glass.
  Its height is driven by the selected tab's content.

## Image loading

`CachedAsyncImage` + `ImageCache` replace `AsyncImage` entirely:

- synchronous cache probe in `init` → no placeholder flash on cached art,
- CGImageSource thumbnail decode off-main with `maxPixelSize` (cards ~400,
  hero/backdrops 1920, palette 120) and `ShouldCacheImmediately` so the
  render thread never decompresses JPEGs,
- NSCache capped at 200 images / 50 MB, in-flight loads coalesced per key.

Always pass a sensible `maxPixelSize` — requesting full-size art on a rail
card is the difference between smooth and stuttering focus scrolling.


## App artwork

Two paths, both writing the same catalogue:

- `scripts/generate-artwork.swift` draws the marks from code.
- `scripts/import-artwork.swift` takes supplied artwork and produces every
  asset from it. Use this when the design comes from outside.

```sh
scripts/import-artwork.swift --icon art/icon.png
scripts/import-artwork.swift --icon art/icon.png --topshelf art/banner.png
scripts/import-artwork.swift --back art/back.png --middle art/mid.png \
                            --front art/front.png --icon art/icon.png
```

**What to ask for when commissioning the art:**

| asset | size | notes |
| --- | --- | --- |
| iOS icon | 1024x1024 square | opaque; the system applies its own mask, so no rounded corners in the art |
| tvOS icon | **2560x1536 (5:3)** | tvOS icons are *not* square. A square source is fitted and centred on the palette background, which leaves a visible edge — supply 5:3 to avoid it |
| tvOS parallax layers | 2560x1536 each, **alpha** | optional. Back is the opaque scene; Middle and Front must be transparent apart from what should lift on focus |
| Top Shelf | 3840x1440 | wide banner, aspect-filled |
| Top Shelf Wide | 4640x1440 | ditto, wider still |

Everything is aspect-filled or fitted, never squashed. Layers are the only way
to get the tvOS focus parallax: a single flat image gives a valid but static
icon.

Keep the sources under `art/` (gitignored) and commit only the generated
catalogue, so the repository does not carry both.
