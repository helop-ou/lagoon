# Release

The single release checklist. The upload tooling targets internal TestFlight;
public distribution has more gates below. Simulator results and unsigned
archives do not complete those gates.

## Cutting a build, start to finish

The whole sequence. Read the linked sections before doing it the first time.
[Public release](#public-release) has further gates this list does not cover.

```sh
scripts/bump-build.sh                             #  1. next build number
#  2. write the entry in Changelog.swift, by hand
scripts/generate-changelog.sh                     #  3. regenerate CHANGELOG.md
scripts/generate-site-facts.sh                    #  4. the website's facts
xcodebuild -scheme Lagoon -destination 'generic/platform=tvOS Simulator' build
xcodebuild -scheme Lagoon -destination 'generic/platform=iOS Simulator' build
xcodebuild test -scheme Lagoon \                  #  5. both builds, then tests
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
#  6. commit, one change per commit, and push
cp .env.example .env                              #  7. once: fill in the DSN
scripts/upload-testflight.sh both --archive-only  #  8. archive with the DSN
#  9. upload in Xcode's Organizer, then wait for acceptance
scripts/publish-release.sh <build>                # 10. tag and publish
```

1. **[Bump the build](#version-and-changelog)**, only for something you will
   distribute. Decide the marketing version here: minor for new features,
   patch for fixes only.
2. **Write the changelog entry** for a viewer, not a reader of the diff.
   `ChangelogTests` fails until the declared build has one.
3. **[Regenerate `CHANGELOG.md`](#the-published-changelog).** It becomes the
   release body in step 10.
4. **[Regenerate the website's facts](#version-and-changelog)** and commit
   them in `lagoon-website`. The site serves the old version until its own,
   separate deploy.
5. **Build both platforms and run the unit suite.** Archiving runs no tests.
6. **Commit and push.** Step 10 refuses a revision the remote lacks.
7. **Fill in `.env`**, once per checkout. See
   [`.env.example`](../.env.example); the shell still overrides it.
8. **[Archive](#internal-testflight)** with `--archive-only` when uploading
   through Xcode, because an Xcode-made archive has diagnostics off.
9. **Upload** with **Automatically manage version and build number**
   unticked, and wait for App Store Connect to accept the build.
10. **[Publish the release](#release-tags)**, after acceptance, not before.

## Version and changelog

**Build number.** Lagoon owns its build numbers. Bump only for a build you
will distribute, not per commit. `scripts/bump-build.sh` advances all
configurations and the app and Top Shelf together; `--set <number>` picks an
explicit higher number. It rejects backwards numbering and configuration
drift. The build number, not the version, identifies a binary; About shows
both as `0.2.0 (107)`.

**Marketing version.** Always `MAJOR.MINOR.PATCH`: major for a significant
rework, minor for new features, patch for fixes only. It borrows semantic
versioning's shape, not its promise, since Lagoon has no API. (A package
extracted from this repo would use real semver.)

Change it by editing `MARKETING_VERSION` in both configurations of
`Lagoon.xcodeproj/project.pbxproj`, or in Xcode's target editor. **Never with
`xcrun agvtool new-marketing-version`**: with `GENERATE_INFOPLIST_FILE = YES`
the version keys come from build settings, so agvtool reports success and
changes nothing.

**Changelog entry.** Write it in
[`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift) before
archiving. Entries are newest first, with version, build, release month,
headline and viewer-visible changes. Tests require the installed version and
build to have an entry. Builds from before the changelog are not
reconstructed.

- One line per noticeable improvement, most useful first. Describe the fixed
  symptom and any setup needed.
- One short sentence, two only when setup needs saying: what changed, never
  why or how. Causes and caveats go in the commit.
- No ticket keys, filenames, internal refactors, tests, docs, or fixes to
  work that never shipped. No em dashes. `ChangelogTests` enforces this.
- Notes are written per release, not generated per commit.
- About groups each build's notes as **New features**, **Improvements** or
  **Bug fixes**; keep related notes under the category a viewer would
  notice. About badges the installed build.

### The published changelog

[`CHANGELOG.md`](../CHANGELOG.md) is generated from `Changelog.swift` by
`scripts/generate-changelog.sh`; never edit it by hand. The About screen, the
Markdown file and the GitHub release body are three renderings of one source,
so they cannot disagree. `ChangelogTests` checks what it can: the declared
build has an entry, categories are in order, no em dashes.

```sh
scripts/generate-changelog.sh             # regenerate the document
scripts/generate-changelog.sh --check     # fail if it is out of date
scripts/generate-changelog.sh --notes 107 # print one build's notes
```

`--notes` prints to stdout for a release body, and fails rather than printing
nothing when the build has no entry.

### Release tags

Tag a build when it is distributed, and only then, just as build numbers
advance only for builds that go out.

Tags read `<version>-<build>`, e.g. `0.2.0-107`. The build number makes them
unique and is what viewers see in About and quote in bug reports; the version
says what it shipped as. A tag is never renamed when the marketing version
moves.

```sh
scripts/publish-release.sh 107
scripts/publish-release.sh 107 --dry-run    # print what it would do
```

**A tag alone only reaches the Tags tab.** A GitHub release is a separate
object, so `git push origin 0.2.0-107` looks done and publishes nothing. The
script creates tag and release together, takes the body from `CHANGELOG.md`,
and marks anything below 1.0 a pre-release.

Run it after the build is uploaded and accepted. Its guards exist because
these mistakes are silent and a published tag is hard to withdraw. It refuses:

- a dirty tree
- a build number the project does not declare
- a missing changelog entry
- a `CHANGELOG.md` that has drifted from `Changelog.swift`
- a tag already in use
- a revision the remote does not have yet

If the revision is ahead of the commit that set the build number, it asks,
because which revision was archived is not recorded. Pass `--rev` when the
archive came from something other than `HEAD`.

It **warns** without stopping when the website's generated facts are behind
the build, or could not be checked. The fix is
`scripts/generate-site-facts.sh`, then a commit and deploy in
`lagoon-website`.

Tags are how someone holding a binary finds its source, which the vendored
FFmpeg licence requires. See the native-component gate under [Public
release](#public-release).

Tagging starts at the first published build. Earlier builds were never
distributed outside the team, so none is tagged retroactively. The history was
rewritten before publication, so revisions quoted in older records are
invalid, but the build bumps are still findable if a backfill is ever wanted.
The Releases tab stays limited to builds that went out.

## Internal TestFlight

One-time setup: the team in `DEVELOPMENT_TEAM` in the project file, bundle ID
`ee.helop.lagoon` for both platforms, and an App Store Connect record with
both platforms. Xcode may need a registered physical device (connected, or its
UDID in the portal) to create the first development profiles.

1. Choose the revision, bump the build and write its changelog entry.
2. Run the iOS and tvOS unit suites, including `ChangelogTests`, plus the UI
   and physical journeys relevant to the changes. Archive runs no tests.
3. Archive separately for generic tvOS and iOS devices. Use the internal-only
   TestFlight distribution flow.
4. Keep **Automatically manage version and build number** unchecked. Check
   the uploaded platform and build match the repository, and keep the
   archives, app and extension dSYMs, and validation results.

The CLI applies the same policy:

```sh
scripts/upload-testflight.sh both --dry-run      # print the commands only
scripts/upload-testflight.sh both --archive-only # archive, upload in Xcode
scripts/upload-testflight.sh both                # archive and upload
```

- The script checks the version and changelog before archiving.
- [`ExportOptions.plist`](../ExportOptions.plist) sets
  `testFlightInternalTestingOnly=true` and
  `manageAppVersionAndBuildNumber=false`. Keep both for this flow.
- API key environment: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`. The
  `.p8` file stays outside the repository.
- These can go in `.env` (copy [`.env.example`](../.env.example)); exported
  values override it. The script refuses to run if `.env` is staged.

### Archiving in Xcode switches diagnostics off

**A build archived by Xcode reports nothing, silently.**

`LagoonInfo.plist` sets `LagoonSentryDSN` to `$(LAGOON_SENTRY_DSN)`, and the
project leaves that setting empty. `upload-testflight.sh` fills it at archive
time; Xcode does not. `DiagnosticsConfiguration.resolveDSN` treats an empty or
unexpanded value as no DSN and installs no sink. This is deliberate:
reporting is on in Release, so a tracked DSN would let any checkout spend the
project's quota.

To upload through the Organizer and keep diagnostics, archive with the script:

```sh
export LAGOON_SENTRY_DSN=…
scripts/upload-testflight.sh both --archive-only
```

`--archive-only` needs **no App Store Connect key** (only export uses it). It
archives both platforms into the Organizer's folder for today, named like
`Lagoon tvOS 0.2.0 (107)`, and stops. Then Xcode › Window › Organizer ›
Distribute App, unticking **Automatically manage version and build number**.

To check what a build carries:

```sh
plutil -p "<archive>/Products/Applications/Lagoon.app/Info.plist" | grep DSN
```

An empty string means that build reports nothing.

## External TestFlight

Adding a build to an external group submits it to Beta App Review under the
full App Review Guidelines; uploading alone never does. Apple reviews a
platform's first build, and later ones usually pass without review. iOS and
tvOS are separate binaries under one record and are reviewed separately.

**A build exported through the internal flow can never reach external
testing.** `testFlightInternalTestingOnly=true` is a property of the upload.
External testing needs the [public export
configuration](#public-export-procedure) and a fresh archive; no existing
build can be promoted.

Required before submitting:

- A working privacy policy: a **URL** for iOS, policy **text** in App Store
  Connect for tvOS. See [Website](#website).
- Beta App Description and a feedback email. tvOS testers cannot send in-app
  feedback or screenshots, so that address is their only channel.
- App Review Information: contact details and sign-in credentials, since the
  app shows nothing until a server is configured.
- Age rating and content rights (app-level; content rights covers showing
  third-party content).
- Export compliance, already met by `ITSAppUsesNonExemptEncryption=NO`.

A reviewer needs a reachable server and account; there is no demo mode outside
`#if DEBUG`. `demo.jellyfin.org/stable` is rights-cleared and nothing
auto-connects to it, but it is a third party's server and an outage during
review looks like a broken app. Review notes should:

- give username and password, not Quick Connect
- say Seerr is optional and will show its connect prompt
- say requests go to the user's own Jellyseerr, and downloads come from their
  own server under that account's policy

Distributing to testers outside the team counts as distribution for licence
purposes. See the native-component gate under [Public
release](#public-release).

## Project declarations and native inputs

- The project declares `ITSAppUsesNonExemptEncryption=NO`, local-network
  usage text, and local-network ATS access without an arbitrary-load
  exception. These are implementation facts, not a public-release approval.
- The app and Top Shelf have separate privacy manifests. Review their reasons
  when file access, diagnostics, app-group use or native build options
  change.
- The app manifest declares diagnostic and performance data collection for
  automatic failure reports. App Store Connect's privacy answers and the
  Settings footer must match the [diagnostics
  reference](reference/playback/diagnostics.md#tester-controls-and-disclosure).
- Before a TestFlight round, check the Sentry project's quota and its
  *Prevent Storing of IP Addresses* setting.
- A new native dependency needs an acknowledgement entry, bundled licence
  text and matching provenance. `AcknowledgementsTests` checks the notice
  resources.
- Some pinned prebuilt native frameworks lack usable dSYMs. The resulting
  upload warning limits native symbolication; tell it apart from missing app
  or extension symbols by reading the actual archive warnings.

A separate assessment covers data flow, native licensing, encryption and the
required-reason API. It is a point-in-time snapshot; reconcile it with the
actual release before making declarations. The [native
inventory](reference/native-dependency-inventory.json) is generated by
`scripts/inventory-native-dependencies.py` from the engine checkout SwiftPM
resolved, and records that engine's version and revision. The script refuses
a checkout other than the one `Package.resolved` pins. Keep exact input hashes
and build records with the candidate.

## Public release

These gates are separate from internal TestFlight. Check them against the
final signed candidate, not an earlier audit revision.

### Decisions before a public candidate

- [x] Licence selected and applied: **MPL-2.0** for Lagoon's own code, with
  the Lagoon name and brand assets carved out of the grant. Chosen for
  attribution rather than reciprocity; it matches Swiftfin and
  jellyfin-sdk-swift and avoids the GPL's conflict with App Store terms.
  `LICENSE` carries the canonical text verbatim, `TRADEMARKS.md` the
  carve-out, and `CODE_OF_CONDUCT.md` the Contributor Covenant.
- [ ] Deliver and test the corresponding-source, notices and relinking
  materials for every native component. FFmpeg is statically linked, so the
  shared-library route is unavailable; publishing the source is the cheapest
  way to discharge this and removes the per-release burden. Since engine
  1.0.2 all four FFmpeg libraries are built by the engine from
  checksum-pinned source without `--enable-version3`, and are
  LGPL-2.1-or-later; dav1d, lcms2 and uavs3d are built there too. libdovi is
  the one component vendored prebuilt, because it needs a Rust toolchain.
  In place: every engine release attaches FFmpeg's corresponding source
  (upstream tarball, patch, build script and configure records); each
  artifact ships its licence, libdovi's with its Rust crates; the FFmpeg
  notice links that release and credits the Independent JPEG Group, whose
  DCT code is in libavcodec. Owed: this repository and the engine's public,
  since relinking relies on their source, before any external build; the
  FFmpeg line on the website's download pages. Whether the App Store's usage
  rules are a further restriction under LGPL-2.1 §10 is a legal judgement,
  not an engineering one; VLC for iOS ships the same arrangement.
- [ ] Record encryption classification and territories, including France.
  Align build declarations and keep any required documentation.
- [ ] Approve data collection and retention answers, complete the app's
  collection manifest and App Privacy labels, and generate and review Xcode's
  privacy report.
- [x] Direct OpenSubtitles integration removed. Subtitle search relies on
  Jellyfin.
- [x] In-app legal and acknowledgements are reachable before login and in
  About.
- [ ] Publish privacy and support pages with the selected domain, publisher
  identity and monitored contact, and enter the same URLs in App Store
  Connect. Done: the pages are live, `LegalDestinations` carries them, and the
  iPhone and iPad rows open in Safari. Owed: the tvOS rows seen on a
  television, the code scanned with a phone, and App Store Connect (a URL for
  iOS, the pasted policy text for tvOS). See [Website](#website).
- [ ] Complete physical acceptance testing, including the permission journey
  from the assessment above, and the outstanding device checks.

### Prepare and verify the exact release

1. Select the final source revision, a deliberate marketing version and the
   next unused build number. Write the changelog entry and regenerate
   `CHANGELOG.md` with `scripts/generate-changelog.sh`.
2. Run the iOS and tvOS unit suites and the applicable UI and hardware
   journeys explicitly; archive does **not** run them. Keep result bundles and
   device, OS, media and server details for that revision.
3. Archive separately for generic iOS and tvOS devices with the distribution
   team and signing. Keep both archives and their app and extension dSYMs.
   Verify signing identities, profiles, app-group entitlements, bundle
   identifiers, deployment targets, app and extension versions and intended
   device support.
4. Run `python3 scripts/validate-release-privacy.py /path/to/Lagoon.xcarchive`
   for both archives. Generate the Organizer privacy report and validate the
   signed archives in Xcode. Review icons and Top Shelf artwork, frameworks,
   native symbols and App Store validation messages. The script checks
   resources and basic bundle consistency; it is not Apple's validation or
   legal approval.
5. Keep per-slice dependency hashes and build records with the exact release,
   and regenerate the inventory if an input changes. Match the recipient
   licence, source and relink package to those same inputs.

### Public export procedure

Keep `ExportOptions.plist` and `scripts/upload-testflight.sh` internal-only.
After the decisions above, create a **separate** public export configuration
with:

- `method=app-store-connect`
- `destination=export`
- `testFlightInternalTestingOnly=false`
- `manageAppVersionAndBuildNumber=false`
- `uploadSymbols=true`
- the verified team and signing choices

Compare these options with `xcodebuild -help` from the release Xcode before
using them. Export a local reviewable artifact from each signed archive
first.

Upload those candidates through Organizer's App Store Connect flow or a
separately reviewed public upload command. Verify build numbers and platform
assignments in App Store Connect. External TestFlight review and App Store
submission are separate actions. An internal-only upload can never become a
public candidate.

Once the build is accepted, run `scripts/publish-release.sh <build>` to tag
the exact archived revision and publish the release (see [Release
tags](#release-tags)); pass `--rev` if that revision is not `HEAD`. Without
it a recipient cannot identify the corresponding source, which the native
licences require. GitHub attaches that source archive to the release.

### Review package

- [ ] Store name, subtitle, description, keywords and support/privacy URLs
  match the release. No unverified claims of universal format, HDR or server
  support.
- [ ] Age rating, content rights and applicable trader declarations are
  completed by the publisher for the actual app and territories.
- [ ] Screenshots cover the supported devices and use rights-cleared artwork
  and media, with no household library, tokens or private server addresses.
- [ ] Review notes explain the Jellyfin server requirement, supported
  sign-in, Seerr and subtitle setup, and any hardware-specific behavior.
- [ ] A reliable, maintained review server with a non-administrator account
  and rights-cleared media, reachable from outside the developer's LAN. Its
  credentials stay out of the repository and the public website.
- [ ] A publisher has reviewed the final candidate and explicitly authorized
  upload, submission and release. Record processing and review results, and
  follow up on App Store warnings; an unsigned archive is not acceptance.

## Website

- The site lives in the separate `lagoon-website` repository (sibling
  checkout `../lagoon-website`): a prerendered SvelteKit site with Cloudflare
  configuration.
- It is live at `lagoon.helop.dev`, on the same `helop.dev` as the support
  and security contact. `.dev` is HSTS-preloaded, so an address typed from the
  Apple TV screen cannot resolve over plain HTTP.
- `Lagoon/Features/Settings/LegalDestinations.swift` carries the published
  `/privacy/` and `/support/` addresses. App Store Connect must get the same
  two, because a reviewer compares them. An unpublished destination stays nil
  and its row disappears.
- Still owed: publisher identity and a monitored contact, current
  rights-cleared screenshots, and the App Store/TestFlight destination. Keep
  site and store copy consistent with the actual formats, devices, server
  setup and subtitle permissions.
