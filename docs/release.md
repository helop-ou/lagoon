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

## Changelog (HEL-94)

Settings → About → Changelog shows every shipped build. It is a hand-written
list, not something generated from git: a changelog answers what changed *for
the viewer*, which a few hundred `feat:`/`fix:` subjects do not.

The list is `Changelog.entries` in `Lagoon/Models/Changelog.swift`, newest
first. **Adding a release is one entry at the top:**

```swift
ChangelogEntry(
    version: "0.2",            // CFBundleShortVersionString / MARKETING_VERSION
    build: "7",                // CFBundleVersion — what Xcode set at upload
    released: "September 2026", // month, not a day
    headline: "One line on what this build is about.",
    changes: [
        "One user-visible change per line.",
        "Write for a viewer, not a reviewer — no ticket keys, no file names.",
    ]
),
```

Version and build together identify the entry, because TestFlight assigns a
new build number to every upload while the marketing version stays put. The
entry whose version *and* build match the running bundle is badged
**Installed** in the panel.

## Build numbers are owned by the repository

**Xcode's "Automatically manage version and build number" must stay unchecked
in the upload sheet.** Lagoon sets its own `CURRENT_PROJECT_VERSION`, because
letting Xcode assign one at upload meant the repository could not say what
shipped as what: the project said build 1 while roughly 43 tvOS builds and 20
iOS builds existed, from the same setting, on two sequences that had silently
diverged. Nothing could match a changelog entry to a build, and the test below
would have been gating a number nobody shipped.

The setting is project-level, so one value covers the app and the Top Shelf
extension — App Store Connect requires those to match.

The sequence restarted at **50** (clear of both platforms' high-water marks;
App Store Connect only requires the number to increase per platform, so the
gap on iOS is fine). Before archiving:

```sh
scripts/bump-build.sh          # next build
scripts/bump-build.sh --set 60 # jump to a specific number
```

It refuses to go backwards and refuses to run if the configurations have
drifted apart. Commit the bump together with the changelog entry.

`ChangelogTests.theBuildThisProjectDeclaresHasChangelogNotes` fails when the
declared version and build have no entry, so a build cannot reach TestFlight
without someone having written what changed in it. `LagoonTests` is app-hosted,
so the test reads the app bundle's real values.

If a build somehow ships without notes, `Changelog.runningBuildIsListed()`
still detects it at runtime: the About row reads "This build isn't listed" and
the panel says so at the top. A list that quietly omits the build someone is
running is worse than one that admits the gap.

Builds between 1 and 50 predate all of this and are not itemised.

### Turning the renumbering off

In the Organizer this is a per-upload checkbox, **"Manage version and build
number"**, and only the **Custom** method shows it — every other tile is
labelled "Use recommended settings…", which means Xcode answers the options
pages itself and the default is on. There is no project setting for it.

So: Distribute App → **Custom** → App Store Connect → Upload → untick it on the
options page. Confirm afterwards that App Store Connect shows the same build
number the repository declares. A higher one means it was still on.

## Uploading from the command line

`scripts/upload-testflight.sh` does the same thing without the checkbox,
because `ExportOptions.plist` pins the setting in a committed file:

```sh
scripts/upload-testflight.sh both --dry-run   # print the commands only
scripts/upload-testflight.sh tvos
scripts/upload-testflight.sh both
```

It refuses to start if the declared version and build have no changelog entry —
the same rule `ChangelogTests` enforces, checked before spending minutes on an
archive rather than after.

`ExportOptions.plist` sets `testFlightInternalTestingOnly`, which does more
than default to internal: the build **cannot** be added to an external group at
all, so it can never reach Beta App Review. Uploading never triggers review
either way; that only happens when a build is submitted to an external group.
Every key in the file is verified present in Xcode 26.6's IDEDistribution
framework.

Authentication uses an App Store Connect API key, because `xcodebuild` cannot
reuse Xcode's signed-in account non-interactively. Create one under **App Store
Connect → Users and Access → Integrations → App Store Connect API**, then:

```sh
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
```

**Keep the `.p8` out of the repository** — it is a credential for the whole
account, and it cannot be re-downloaded after issue.

The GUI flow above remains perfectly fine; this exists so the setting is
enforced by a file rather than by remembering a checkbox.
