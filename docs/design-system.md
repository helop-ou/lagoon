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
on iOS). Buttons use `.glassProminent` for the one primary action per screen
and `.glass` for everything else. Focus drives only:

- the title reveal on poster cards (`opacity`, 0.25 s ease),
- nothing else — selection elsewhere is a weight/color swap, not a border.

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
- **Detail pages**: blurred-dimmed backdrop with leading readability wash;
  poster (r14, single allowed shadow) + info column; prose capped at 760 pt
  while the button row is exempt so wide labels never wrap.

## Image loading

`CachedAsyncImage` + `ImageCache` replace `AsyncImage` entirely:

- synchronous cache probe in `init` → no placeholder flash on cached art,
- CGImageSource thumbnail decode off-main with `maxPixelSize` (cards ~400,
  hero/backdrops 1920, palette 120) and `ShouldCacheImmediately` so the
  render thread never decompresses JPEGs,
- NSCache capped at 200 images / 50 MB, in-flight loads coalesced per key.

Always pass a sensible `maxPixelSize` — requesting full-size art on a rail
card is the difference between smooth and stuttering focus scrolling.
