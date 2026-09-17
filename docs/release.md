# Release

This is the single release checklist. The repository's upload tooling targets
internal TestFlight. Public distribution has additional gates below; recorded
simulator results and unsigned archives do not complete them.

## Version and changelog

Lagoon owns its build numbers. Bump only when preparing a build to distribute,
not for every commit. Run `scripts/bump-build.sh` to advance all configurations
and the app/Top Shelf together; `--set <number>` selects an explicit higher
number. The script rejects backwards numbering and configuration drift.
Marketing version changes use `xcrun agvtool new-marketing-version <version>`.

Write the matching entry in
[`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift) before archiving. Entries
are newest first and contain the version, build, release month, headline, and
viewer-visible changes. Tests require the installed version/build to have an
entry. Builds before the changelog's introduction are not reconstructed from
commit messages.

Write one line per noticeable improvement, with the most useful first. Describe
a fixed symptom and any setup needed. Omit ticket keys, filenames, internal
refactors, tests, docs, and fixes to work that never shipped. Do not use em
dashes; `ChangelogTests` enforces this. Release notes are written for a release,
not generated per commit. Each build's notes are grouped in the About screen as
**New features**, **Improvements**, or **Bug fixes**. Keep related notes together
under the category that best describes what a viewer will notice. The installed
build is badged in About.

## Internal TestFlight

One-time setup uses the development team recorded as `DEVELOPMENT_TEAM` in the
project file and bundle ID `ee.helop.lagoon` for both platforms. The App Store
Connect record must include both platforms. Xcode may need a registered
physical device to create initial development profiles; connect a device or
register its UDID in the portal.

1. Choose the revision, bump the build, and write its changelog entry.
2. Run iOS and tvOS unit suites, including `ChangelogTests`, plus the UI and
   physical journeys relevant to the changes. Archive does not run tests.
3. Archive separately for generic tvOS and iOS devices in Xcode. Use the
   internal-only TestFlight distribution flow.
4. Keep **Automatically manage version and build number unchecked**. Verify
   the uploaded platform and build match the repository, then retain the
   archives, app/extension dSYMs, and validation results.

The CLI uses the same committed policy:

```sh
scripts/upload-testflight.sh both --dry-run
scripts/upload-testflight.sh tvos
scripts/upload-testflight.sh both
```

The script checks the version/changelog before archiving.
[`ExportOptions.plist`](../ExportOptions.plist) sets
`testFlightInternalTestingOnly=true` and
`manageAppVersionAndBuildNumber=false`. Keep those settings for this flow.
The API-key environment is `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH`;
the `.p8` belongs outside the repository. `LAGOON_SENTRY_DSN` is required too
(HEL-187): the DSN is not tracked in source, so the script passes it to
`xcodebuild archive` as a build setting and the app reads it back from its
Info.plist. A build archived without it reports nothing at all, which is why
the script refuses to run rather than warning. GUI distribution remains
available, but an Organizer archive carries no DSN.

## External TestFlight

HEL-185. Adding a build to an external group submits it to Beta App Review
against the full App Review Guidelines. Uploading never triggers review by
itself. Apple reviews the first build of a platform; later builds usually pass
without one, and Apple does not publish the threshold. iOS and tvOS are separate
binaries under one app record, so each is reviewed on its own.

**A build exported through the internal flow above can never reach external
testing.** `ExportOptions.plist` pins `testFlightInternalTestingOnly=true`,
which is not a label but a property of the upload. External testing needs the
separate public export configuration described under
[Public export procedure](#public-export-procedure) and a fresh archive; no
existing build can be promoted.

Required before submitting:

- A working privacy policy. iOS takes a **URL**, tvOS takes privacy policy
  **text** in App Store Connect. See [Website](#website).
- Beta App Description, and a feedback email. tvOS testers cannot send in-app
  feedback or screenshots, so that address is their only channel.
- App Review Information: contact details, and sign-in credentials, which are
  unavoidable because the app shows nothing before a server is configured.
- Age rating and content rights, both app-level. Content rights covers
  displaying third-party content.
- Export compliance, already satisfied by `ITSAppUsesNonExemptEncryption=NO`.

A reviewer needs a reachable Jellyfin server and an account; there is no demo
mode outside `#if DEBUG`. `demo.jellyfin.org/stable` is rights-cleared and
nothing in the app auto-connects to it, but it is a third party's server and an
outage during review reads as a broken app. Review notes should give
username/password rather than Quick Connect, say that Seerr is optional and will
show its connect prompt, and state that requests reach the user's own Jellyseerr
and downloads come from the user's own server under that account's policy.

Distributing to testers outside the team is distribution for licence purposes;
see the native-component gate under [Public release](#public-release).

## Project declarations and native inputs

The project currently declares `ITSAppUsesNonExemptEncryption=NO`, local-network
usage text, and local-network ATS access without an arbitrary-load exception.
These values are implementation facts, not a completed public-release approval.
The app and Top Shelf have distinct privacy manifests; review the reasons when
file access, diagnostics, app-group use, or native build options change. The
app manifest declares diagnostic and performance data collection for the
automatic failure reports (HEL-159); App Store Connect's privacy answers and
the Settings footer must match the [diagnostics reference](reference/playback/diagnostics.md#tester-controls-and-disclosure).
Before a TestFlight round, confirm the Sentry project's quota and the
*Prevent Storing of IP Addresses* setting there.

New native dependencies need an acknowledgement entry, bundled license text,
and matching provenance. `AcknowledgementsTests` checks the notice resources.
Some pinned prebuilt native frameworks lack usable dSYMs: an upload warning for
those inputs limits native symbolication and must be distinguished from missing
app or extension symbols. Review the actual archive warnings.

HEL-143 records the data-flow, native licensing, encryption, and
required-reason API assessment behind these values.
The [native inventory](reference/native-dependency-inventory.json)
is generated by `scripts/inventory-native-dependencies.py`; keep exact input
hashes and build records with the candidate. That historical assessment must
be reconciled with the actual release before making distribution declarations.

## Public release

HEL-143. These gates remain separate from the internal TestFlight procedure.
Check them against the final signed candidate, not an earlier audit revision.

### Decisions before a public candidate

- [x] Licence selected (HEL-158): **MPL-2.0** for Lagoon's own code, with the
  Lagoon name and brand assets carved out of the grant. Chosen for attribution
  rather than reciprocity; it matches Swiftfin and jellyfin-sdk-swift and avoids
  the GPL's conflict with App Store terms. Decided, not applied: the repository
  still has no `LICENSE` file.
- [ ] Deliver/test the corresponding-source, notices and relinking materials for
  every native component. FFmpeg is statically linked, so the shared-library
  route is unavailable. Publishing the source (HEL-158) discharges this most
  cheaply and removes the per-release burden; HEL-190 removes LGPL-3.0 entirely
  by rebuilding the three MPVKit binaries without `--enable-version3`. Whether
  any route satisfies the licence for App Store distribution is a legal
  judgement, not an engineering one.
- [ ] Record encryption classification and territories, including France; align
  build declarations and retain any required documentation.
- [ ] Approve data collection/retention answers, complete the app's collection
  manifest and App Privacy labels, and generate/review Xcode's privacy report.
- [x] Direct OpenSubtitles removed (HEL-146); subtitle search relies on Jellyfin.
- [x] In-app legal and acknowledgements access exists before login and in About.
- [ ] Publish privacy/support pages with the selected domain, publisher identity
  and monitored contact; fill `LegalDestinations` with verified URLs and check
  their iPhone/iPad and tvOS presentation. See [Website](#website).
- [ ] Complete HEL-144 physical acceptance, including the permission journey from
  HEL-143 and pending HEL-141/142 device checks.

### Prepare and verify the exact release

1. Select the final source revision, deliberate marketing version and next unused
   repository-owned build number; write the corresponding changelog entry.
2. Explicitly run the iOS and tvOS unit suites and applicable UI/hardware journeys.
   Archive does **not** automatically run those tests. Retain result bundles and
   device/OS/media/server details for that revision.
3. Archive separately for generic iOS and tvOS devices using the distribution
   team/signing configuration. Keep both archives and their app/extension dSYMs.
   Verify signing identities, profiles, app-group entitlements, bundle identifiers,
   deployment targets, app/extension versions and the intended device support.
4. Run `python3 scripts/validate-release-privacy.py /path/to/Lagoon.xcarchive`
   for both archives. Generate the Organizer privacy report and validate the
   signed archives with Xcode. Review icons/Top Shelf artwork, frameworks, native
   symbols and any App Store validation messages. The script checks resources
   and basic bundle consistency; it is not Apple's validation or legal approval.
5. Retain per-slice dependency hashes/build records with the exact release and
   regenerate the inventory if an input changes. Match the recipient license/
   source/relink package to those same inputs.

### Public export procedure

Keep `ExportOptions.plist` and `scripts/upload-testflight.sh` internal-only.
After the decisions above, make a **separate** public export configuration with
`method=app-store-connect`, `destination=export`,
`testFlightInternalTestingOnly=false`, `manageAppVersionAndBuildNumber=false`
and `uploadSymbols=true`, plus the verified team/signing choices. Compare these
options with `xcodebuild -help` from the release Xcode installation before using
them. Export a local reviewable artifact from each signed archive first.

Use Organizer's App Store Connect distribution flow or a separately reviewed
public upload command for those candidates. Verify the resulting build numbers
and platform assignments in App Store Connect. External TestFlight review and
App Store submission are separate actions; an internal-only uploaded build
cannot be repurposed as a public candidate.

### Review package

- [ ] Store name, subtitle, description, keywords and support/privacy URLs match
  the release; no unverified claims of universal format/HDR/server support.
- [ ] Current age-rating, content rights and applicable trader declarations are
  completed by the publisher for the actual app and territories.
- [ ] Screenshots cover the supported devices and use rights-cleared artwork and
  media. Do not expose a household library, tokens or private server addresses.
- [ ] Review notes explain the Jellyfin server requirement, supported sign-in,
  Seerr/subtitle setup and any hardware-specific behavior.
- [ ] Provide a reliable, maintained review server with a non-administrator
  account and rights-cleared media. Test access from outside the developer's LAN.
  Keep its private credentials out of the repository and public website.
- [ ] A publisher has reviewed the final candidate and explicitly authorized its
  upload/submission/release. Record processing/review results and follow up on
  any App Store warnings rather than treating an unsigned archive as acceptance.

## Website

The site source and maintained copy live in the separate `lagoon-website`
repository (the sibling checkout is `../lagoon-website`). It contains the
prerendered SvelteKit site and Cloudflare configuration.

Publication remains a release task: confirm the domain (proposed
`lagoon.helop.ee`), publisher/contact, DNS, current rights-cleared screenshots,
and the App Store/TestFlight destination. Check the live privacy and support
pages before filling `Lagoon/Features/Settings/LegalDestinations.swift` and App Store
Connect. Those URLs are currently nil so the app cannot link to unpublished
pages. Keep the site and store copy consistent with the actual supported
formats, devices, server setup, and subtitle permissions.
