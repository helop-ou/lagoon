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
| `posterWidth` (2:3) | 260 | 140 |
| `landscapeWidth` (16:9) | 360 | 240 |
| `heroHeight` | 540 | 340 |
| `gridColumns` | 6 | 3 |
| rail focus headroom | top 40 / bottom 80 | 6 / 10 |

Shared radii: card 12, card artwork 10, badge 6, hero panel 32, progress bar
6 pt capsule. `Motion`: fast 0.2 / standard 0.4 / slow 0.6 / crossfade 0.8.

Brand colors — **only** for branding (wordmark, progress fills, onboarding
wash): `.lagoonTeal` `#4AD1C7`, `.lagoonDeep` `#082E44`. Everything else uses
`.primary`/`.secondary`/`.tertiary`, `.fill.tertiary`, and materials. The app
is locked dark at the `WindowGroup` root.

## Focus strategy

**No custom focus scaling anywhere.** Cards rely on the system `.card` button
style (lift/parallax/specular) via the `cardButtonStyle()` helper (`.plain`
on iOS). Buttons use `.glass` — **everywhere, including primary actions**.
`.glassProminent` fills with the app's accent, and the accent is white
(Jaagop's call: "simple and white like Infuse"), so a prominent button is a
white pill the system then labels in white: invisible. The reference's own
Play and Trailer are plain glass pills too, so prominence comes from
position and order, never from a filled colour. Focus drives only:

- the title reveal on poster cards (`opacity`, 0.25 s ease),
- nothing else — selection elsewhere is a **weight** swap, not a border and
  not a color (see below).

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

## Components

- **Rails** (`MediaRail`): `.headline` title + `LazyHStack` at `cardSpacing`,
  gutter padding, asymmetric top/bottom padding for focus lift; the page
  ScrollView carries `.scrollClipDisabled()`.
- **Cards**: `PosterCard` (260×390, navigates), `LandscapeCard` (360×202,
  plays directly — used for Continue Watching / Next Up), `EpisodeCard`
  (320×180). All share the bottom scrim gradient
  (`.black.opacity(0.85) → clear`) and the teal `ItemProgressBar`, hidden at
  ≥95 % watched.
- **Hero** (`HeroSection`): a *contained* rounded panel (r32, `.thinMaterial`),
  not a full-bleed banner. The backdrop is trailing-aligned and **masked**
  (clear→white over the leading 35 %) so it dissolves into the material —
  no scrim. Auto-advances every 7 s after pre-warming the next image and
  palette; text transitions asymmetrically (in: 0.3 s delayed, out: 0.2 s)
  while the CTA stays outside the transition. Dots: 8 pt capsules, 24 pt when
  active.
- **Ambient glow** (`AmbientGlowView` + `ArtworkPalette`): three radial
  gradients at fixed unit points from the artwork's dominant colors, blurred
  120, bleeding 80 pt past the hero panel. Palette extraction is a pure-Swift
  4-bit RGB histogram ranked by `count × (saturation+0.05) × (brightness+0.1)`
  (the floors stop letterbox bars from winning), sampled at 64×64 off-main,
  memoized per URL in `ArtworkPaletteCache`.
- **Detail pages** (HEL-46, built against Jaagop's Infuse reference — the
  earlier poster-left composition is gone): the backdrop **is** the artwork,
  full-bleed and barely dimmed. Legibility comes from a **leading wash**
  (0.9 → clear by 68 %) rather than a uniform scrim, because the info block
  is left-aligned: that keeps the right of the still vivid, which a scrim
  strong enough for text over busy artwork would flatten. There is no dark
  panel and **no scroll-linked dimming** — the latter was tried and cut
  (Jaagop: "not a big fan of the screen going black"), because moving focus
  into a rail jumps further in one press than any sensible ramp covers, so it
  read as a slam to black. The rails stay legible on their own: the leading
  wash covers the column the headings and names sit in, and the cards are
  opaque artwork.
  The hero space is a **scroll content margin, not a spacer view**: as a
  spacer it was non-focusable content above the first button, which left
  focus unable to climb back out — Up from Play did nothing and the tab bar
  stayed off-screen and unreachable. Order: title art, facts line, genres,
  ★ rating, synopsis, actions, then cast and related rails, sized so the
  cast heading is already on the first screen.
- **Facts line**: one spaced row — runtime, year, a *boxed* certification
  (r4 outline), then plain capability tokens from `MediaSource.qualityTokens`
  ("4K  DV  TrueHD 7.1  Atmos"): resolution, dynamic range, the best audio in
  the file, Atmos when present. Plain text, not capsules — outlined chips
  read far louder than the facts deserve. The vocabulary lives in
  `MediaQuality` so the player's facts line and the detail row can't disagree
  about what counts as 4K.
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

## Image loading

`CachedAsyncImage` + `ImageCache` replace `AsyncImage` entirely:

- synchronous cache probe in `init` → no placeholder flash on cached art,
- CGImageSource thumbnail decode off-main with `maxPixelSize` (cards ~400,
  hero/backdrops 1920, palette 120) and `ShouldCacheImmediately` so the
  render thread never decompresses JPEGs,
- NSCache capped at 200 images / 50 MB, in-flight loads coalesced per key.

Always pass a sensible `maxPixelSize` — requesting full-size art on a rail
card is the difference between smooth and stuttering focus scrolling.
