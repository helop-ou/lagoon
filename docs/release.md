# Releasing to TestFlight

Internal TestFlight only for now — no App Review involved, builds reach
testers minutes after processing. Tracked under HEL-44.

## One-time setup (App Store Connect / developer portal)

1. **Register devices** on team `9GLTW5844P` at developer.apple.com —
   at least one Apple TV and one iPhone. Without a device per platform,
   archiving fails with *"team has no devices"* (verified).
   Apple TV pairing: Settings → Remotes and Devices → Remote App and
   Devices, then Xcode's Devices window on the same network.
2. **Create the app record**: App Store Connect → New App → platforms
   iOS **and** tvOS, bundle id `ee.helop.lagoon`. The store-facing name
   must be globally unique — "Lagoon" alone is likely taken; the home-screen
   name stays "Lagoon" regardless of the store name.
3. **Internal testers**: give each person an App Store Connect role
   (Users & Access), then add them to the internal group under the app's
   TestFlight tab. Up to 100 internal testers.

## Cutting a build (Xcode GUI, same flow as Moony Weather)

Once per platform (the multiplatform target archives separately for
tvOS and iOS):

1. Select an **Any tvOS Device** destination → Product → **Archive**.
2. Organizer → Distribute App → **TestFlight Internal Only**.
3. Repeat with an **Any iOS Device** destination.

**Build numbers bump themselves at upload** — Xcode's distribute flow
manages the version/build number against App Store Connect and stamps the
next free build number onto the upload. `CURRENT_PROJECT_VERSION` in the
project stays at `1` on purpose (exactly like moony-weather); don't hand-bump
it. Marketing version changes are deliberate and manual:
`xcrun agvtool new-marketing-version 0.2` (or edit `MARKETING_VERSION`).

## Facts already encoded in the project

- `ITSAppUsesNonExemptEncryption = NO` — no export-compliance prompt
  blocking each build in TestFlight.
- All icon slots are filled (HEL-31), including the 1280×768 App Store
  stack that upload validation requires.
- ATS enables `NSAllowsLocalNetworking` so home-LAN Jellyfin servers remain
  reachable. The app does not enable the broad `NSAllowsArbitraryLoads`
  exception.
- **"Upload Symbols Failed" warnings for the Lib*.framework artifacts are
  expected and harmless.** The FFmpeg binary artifacts originally sourced
  from MPVKit's release ship with no dSYMs
  anywhere (verified against the release assets), so App Store Connect
  can't symbolicate crash frames inside those libraries — the build still
  uploads and processes, and Lagoon's own code symbolicates normally from
  the archive's dSYM. HEL-48 M6 slimming (2026-08-17) cut the set from
  ~28 frameworks to the 11 the engine actually links
  (`Packages/LagoonFFmpeg`); the rest of the warnings only go away if we
  ever build FFmpeg ourselves with dSYMs kept.
