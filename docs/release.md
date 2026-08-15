# Releasing to TestFlight

Internal TestFlight only for now — no App Review involved, builds reach
testers minutes after processing. Tracked under HEL-44.

## One-time setup (App Store Connect / developer portal)

1. **Register devices** on team `9GLTW5844P` at developer.apple.com —
   at least one Apple TV and one iPhone. Without a device per platform,
   `xcodebuild archive` fails with *"team has no devices"* (verified).
   Apple TV pairing: Settings → Remotes and Devices → Remote App and
   Devices, then Xcode's Devices window on the same network.
2. **Create the app record**: App Store Connect → New App → platforms
   iOS **and** tvOS, bundle id `ee.helop.lagoon`. The store-facing name
   must be globally unique — "Lagoon" alone is likely taken; the home-screen
   name stays "Lagoon" regardless of the store name.
3. **Internal testers**: give each person an App Store Connect role
   (Users & Access), then add them to the internal group under the app's
   TestFlight tab. Up to 100 internal testers.
4. Optional, for scripted uploads: an **App Store Connect API key**
   (Users & Access → Integrations, App Manager role). Keep the `.p8`
   outside the repo.

## Cutting a build

```sh
scripts/testflight.sh
```

Bumps the build number (`agvtool next-version -all`), archives both
platforms into `build/testflight/`, then:

- with `ASC_KEY_PATH` / `ASC_KEY_ID` / `ASC_ISSUER_ID` exported: uploads
  both archives straight to App Store Connect (`ExportOptions.plist`,
  method `app-store-connect`, destination `upload`);
- without them: opens both archives in Xcode's Organizer — Distribute App
  → TestFlight Internal Only, twice.

Commit the build-number bump the script leaves in the working tree.
Marketing version bumps are manual: `xcrun agvtool new-marketing-version 0.2`.

## Facts already encoded in the project

- `ITSAppUsesNonExemptEncryption = NO` — no export-compliance prompt
  blocking each build in TestFlight.
- All icon slots are filled (HEL-31), including the 1280×768 App Store
  stack that upload validation requires.
- The ATS `NSAllowsArbitraryLoads` exception (HEL-42) does **not** block
  internal TestFlight — it only matters for external testing and App
  Review.
