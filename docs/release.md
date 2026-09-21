# Release

This is the single release checklist. The repository's upload tooling targets
internal TestFlight. Public distribution has additional gates below. Recorded
simulator results and unsigned archives do not complete those gates.

## Version and changelog

Lagoon owns its build numbers. Bump only when preparing a build to distribute,
not for every commit. Run `scripts/bump-build.sh` to advance all
configurations and the app/Top Shelf together. Pass `--set <number>` to select
an explicit higher number. The script rejects backwards numbering and
configuration drift.

The marketing version is `MAJOR.MINOR.PATCH`, three components always. Major
is a significant rework of how the app works, minor is new features, and patch
is a release that only fixes things. This is semantic versioning's shape
rather than its promise: Lagoon exposes no API, so no compatibility guarantee
is implied, and the size of the change for a viewer is what picks the
component. A reusable package extracted from this repository would use real
semantic versioning, because it would have real dependents.

The build number, not the marketing version, identifies a binary. One
marketing version spans many builds, and About shows both as `0.1.0 (107)`.

Change the marketing version by editing `MARKETING_VERSION` in both
configurations of `Lagoon.xcodeproj/project.pbxproj`, or in Xcode's target
editor. **Do not use `xcrun agvtool new-marketing-version`.** This project
sets `GENERATE_INFOPLIST_FILE = YES`, so the version keys are synthesised from
the build settings and are absent from the partial Info.plist files agvtool
edits. It reports success, changes nothing, and fails parsing the setting
itself with `Cannot find "Lagoon.xcodeproj/../YES"`.

Write the matching entry in
[`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift) before
archiving. Entries are newest first and contain the version, build, release
month, headline, and viewer-visible changes. Tests require the installed
version/build to have an entry. Builds before the changelog's introduction are
not reconstructed from commit messages.

Write one line per noticeable improvement, with the most useful first.
Describe a fixed symptom and any setup needed. Omit ticket keys, filenames,
internal refactors, tests, docs, and fixes to work that never shipped. Do not
use em dashes. `ChangelogTests` enforces this. Release notes are written for a
release, not generated per commit. Each build's notes are grouped in the About
screen as **New features**, **Improvements**, or **Bug fixes**. Keep related
notes together under the category that best describes what a viewer will
notice. The installed build is badged in About.

## Internal TestFlight

One-time setup uses the development team recorded as `DEVELOPMENT_TEAM` in the
project file, and bundle ID `ee.helop.lagoon` for both platforms. The App
Store Connect record must include both platforms. Xcode may need a registered
physical device to create initial development profiles. Connect a device, or
register its UDID in the portal.

1. Choose the revision, bump the build, and write its changelog entry.
2. Run iOS and tvOS unit suites, including `ChangelogTests`, plus the UI and
   physical journeys relevant to the changes. Archive does not run tests.
3. Archive separately for generic tvOS and iOS devices in Xcode. Use the
   internal-only TestFlight distribution flow.
4. Keep **Automatically manage version and build number** unchecked. Verify
   the uploaded platform and build match the repository, then retain the
   archives, app/extension dSYMs, and validation results.

The CLI uses the same committed policy:

```sh
scripts/upload-testflight.sh both --dry-run
scripts/upload-testflight.sh tvos
scripts/upload-testflight.sh both
```

The script checks the version and changelog before archiving.
[`ExportOptions.plist`](../ExportOptions.plist) sets
`testFlightInternalTestingOnly=true` and
`manageAppVersionAndBuildNumber=false`. Keep those settings for this flow. The
API-key environment is `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`. The
`.p8` file belongs outside the repository.

`LAGOON_SENTRY_DSN` is required too. The DSN is not tracked in source, so the
script passes it to `xcodebuild archive` as a build setting, and the app reads
it back from its Info.plist. A build archived without it reports nothing at
all, which is why the script refuses to run rather than warning. GUI
distribution remains available, but an Organizer archive carries no DSN.

## External TestFlight

Adding a build to an external group submits it to Beta App Review against the
full App Review Guidelines. Uploading never triggers review by itself. Apple
reviews the first build of a platform. Later builds usually pass without one,
and Apple does not publish the threshold. iOS and tvOS are separate binaries
under one app record, so each is reviewed on its own.

**A build exported through the internal flow above can never reach external
testing.** `ExportOptions.plist` pins `testFlightInternalTestingOnly=true`,
which is a property of the upload, not just a label. External testing needs
the separate public export configuration described under [Public export
procedure](#public-export-procedure), and a fresh archive. No existing build
can be promoted.

Required before submitting:

- A working privacy policy. iOS takes a **URL**. tvOS takes privacy policy
  **text** in App Store Connect. See [Website](#website).
- Beta App Description, and a feedback email. tvOS testers cannot send in-app
  feedback or screenshots, so that address is their only channel.
- App Review Information: contact details, and sign-in credentials. The
  credentials are unavoidable because the app shows nothing before a server is
  configured.
- Age rating and content rights, both app-level. Content rights covers
  displaying third-party content.
- Export compliance, already satisfied by `ITSAppUsesNonExemptEncryption=NO`.

A reviewer needs a reachable Jellyfin server and an account. There is no demo
mode outside `#if DEBUG`. `demo.jellyfin.org/stable` is rights-cleared, and
nothing in the app auto-connects to it, but it is a third party's server, and
an outage during review reads as a broken app. Review notes should give
username/password rather than Quick Connect, say that Seerr is optional and
will show its connect prompt, and state that requests reach the user's own
Jellyseerr and downloads come from the user's own server under that account's
policy.

Distributing to testers outside the team is distribution for licence purposes.
See the native-component gate under [Public release](#public-release).

## Project declarations and native inputs

The project currently declares `ITSAppUsesNonExemptEncryption=NO`,
local-network usage text, and local-network ATS access without an
arbitrary-load exception. These values are implementation facts, not a
completed public-release approval. The app and Top Shelf have distinct privacy
manifests. Review the reasons when file access, diagnostics, app-group use, or
native build options change.

The app manifest declares diagnostic and performance data collection for the
automatic failure reports. App Store Connect's privacy answers and the
Settings footer must match the [diagnostics
reference](reference/playback/diagnostics.md#tester-controls-and-disclosure).
Before a TestFlight round, confirm the Sentry project's quota and the *Prevent
Storing of IP Addresses* setting there.

New native dependencies need an acknowledgement entry, bundled license text,
and matching provenance. `AcknowledgementsTests` checks the notice resources.
Some pinned prebuilt native frameworks lack usable dSYMs. An upload warning
for those inputs limits native symbolication, and must be distinguished from
missing app or extension symbols. Review the actual archive warnings.

A separate assessment behind these values covers data-flow, native licensing,
encryption, and the required-reason API. The [native
inventory](reference/native-dependency-inventory.json) is generated by
`scripts/inventory-native-dependencies.py`. Keep exact input hashes and build
records with the candidate.

That assessment is a snapshot from one point in time. Reconcile it against
the actual release before making distribution declarations.

## Public release

These gates remain separate from the internal TestFlight procedure.

Check them against the final signed candidate, not an earlier audit
revision.

### Decisions before a public candidate

- [x] Licence selected and applied: **MPL-2.0** for Lagoon's own code, with
  the Lagoon name and brand assets carved out of the grant. Chosen for
  attribution rather than reciprocity. It matches Swiftfin and
  jellyfin-sdk-swift, and avoids the GPL's conflict with App Store terms.
  `LICENSE` carries the canonical text verbatim, `TRADEMARKS.md` the
  carve-out, and `CODE_OF_CONDUCT.md` the Contributor Covenant.
- [ ] Deliver and test the corresponding-source, notices and relinking
  materials for every native component. FFmpeg is statically linked, so the
  shared-library route is unavailable. Publishing the source discharges this
  most cheaply and removes the per-release burden. A separate change removes
  LGPL-3.0 entirely by rebuilding the three MPVKit binaries without
  `--enable-version3`. Whether any route satisfies the licence for App Store
  distribution is a legal judgement, not an engineering one.
- [ ] Record encryption classification and territories, including France.
  Align build declarations, and retain any required documentation.
- [ ] Approve data collection/retention answers, complete the app's collection
  manifest and App Privacy labels, and generate/review Xcode's privacy report.
- [x] Direct OpenSubtitles integration removed. Subtitle search relies on
  Jellyfin.
- [x] In-app legal and acknowledgements access exists before login and in
  About.
- [ ] Publish privacy/support pages with the selected domain, publisher
  identity and monitored contact, and enter the same URLs in App Store
  Connect. The pages are live, `LegalDestinations` carries them, and the
  iPhone and iPad rows open in Safari. Still owed: the tvOS rows seen on a
  television rather than in a render, the code scanned with a phone, and App
  Store Connect, which takes a URL for iOS but the policy text pasted in for
  tvOS. See [Website](#website).
- [ ] Complete physical acceptance testing, including the permission journey
  from the assessment above, and outstanding device checks.

### Prepare and verify the exact release

1. Select the final source revision, a deliberate marketing version, and the
   next unused repository-owned build number. Write the corresponding
   changelog entry.
2. Explicitly run the iOS and tvOS unit suites and the applicable UI/hardware
   journeys. Archive does **not** automatically run those tests. Retain result
   bundles and device/OS/media/server details for that revision.
3. Archive separately for generic iOS and tvOS devices, using the distribution
   team/signing configuration. Keep both archives and their app/extension
   dSYMs. Verify signing identities, profiles, app-group entitlements, bundle
   identifiers, deployment targets, app/extension versions and the intended
   device support.
4. Run `python3 scripts/validate-release-privacy.py /path/to/Lagoon.xcarchive`
   for both archives. Generate the Organizer privacy report, and validate the
   signed archives with Xcode. Review icons/Top Shelf artwork, frameworks,
   native symbols and any App Store validation messages. The script checks
   resources and basic bundle consistency. It is not Apple's validation or
   legal approval.
5. Retain per-slice dependency hashes and build records with the exact
   release, and regenerate the inventory if an input changes. Match the
   recipient license/source/relink package to those same inputs.

### Public export procedure

Keep `ExportOptions.plist` and `scripts/upload-testflight.sh` internal-only.
After the decisions above, make a **separate** public export configuration
with `method=app-store-connect`, `destination=export`,
`testFlightInternalTestingOnly=false`, `manageAppVersionAndBuildNumber=false`
and `uploadSymbols=true`, plus the verified team/signing choices. Compare
these options with `xcodebuild -help` from the release Xcode installation
before using them. Export a local reviewable artifact from each signed archive
first.

Use Organizer's App Store Connect distribution flow, or a separately reviewed
public upload command, for those candidates. Verify the resulting build
numbers and platform assignments in App Store Connect. External TestFlight
review and App Store submission are separate actions. An internal-only
uploaded build cannot be repurposed as a public candidate.

### Review package

- [ ] Store name, subtitle, description, keywords and support/privacy URLs
  match the release. No unverified claims of universal format/HDR/server
  support.
- [ ] Current age-rating, content rights and applicable trader declarations
  are completed by the publisher for the actual app and territories.
- [ ] Screenshots cover the supported devices and use rights-cleared artwork
  and media. Do not expose a household library, tokens or private server
  addresses.
- [ ] Review notes explain the Jellyfin server requirement, supported sign-in,
  Seerr/subtitle setup and any hardware-specific behavior.
- [ ] Provide a reliable, maintained review server with a non-administrator
  account and rights-cleared media. Test access from outside the developer's
  LAN. Keep its private credentials out of the repository and public website.
- [ ] A publisher has reviewed the final candidate, and explicitly authorized
  its upload/submission/release. Record processing/review results, and follow
  up on any App Store warnings rather than treating an unsigned archive as
  acceptance.

## Website

The site source and maintained copy live in the separate `lagoon-website`
repository. The sibling checkout is `../lagoon-website`. It contains the
prerendered SvelteKit site and Cloudflare configuration.

The site is live on `lagoon.helop.dev`, on the same `helop.dev` as the support
and security contact. The `.dev` TLD is HSTS-preloaded, so an address a viewer
types from the Apple TV screen cannot resolve over plaintext HTTP.

`Lagoon/Features/Settings/LegalDestinations.swift` carries the published
`/privacy/` and `/support/` addresses, and App Store Connect has to be given
the same two, because a reviewer checks one against the other. A destination
whose page is not published stays nil and its row disappears rather than
pointing at an address that does not answer.

Still a release task: publisher identity and a monitored contact, current
rights-cleared screenshots, and the App Store/TestFlight destination. Keep the
site and store copy consistent with the actual supported formats, devices,
server setup, and subtitle permissions.
