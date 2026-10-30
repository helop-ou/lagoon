# Release

The single release checklist. Builds go to external TestFlight testers
through the public link. The App Store has more gates below. Simulator
results and unsigned archives do not complete those gates.

## Cutting a build, start to finish

The whole sequence. Read the linked sections before doing it the first time.
[Public release](#public-release) has further gates this list does not cover.

```sh
#  1. pull requests add viewer-visible lines to Changelog.unreleased
#  2. Actions, Release, prepare: pick the bump, write the headline
#  3. merge the release pull request it opens, once its checks pass
scripts/generate-site-facts.sh                    #  4. the website's facts
#  5. Actions, Release, upload
#  6. add the build to the external group, wait for review
#  7. Actions, Release, publish
```

1. **[Collect the notes](#version-and-changelog)** as work lands. A pull
   request adds its lines to `Changelog.unreleased` and never touches the
   build number, the version or a shipped entry.
2. **[Prepare](#releasing-from-ci).** Choose patch for fixes only, minor for
   new features, major for a significant rework, and write the headline. The
   action opens a pull request that turns the unreleased notes into the new
   entry, advances the build and version, and regenerates `CHANGELOG.md`.
3. **Merge it.** Its checks build both platforms and run both unit suites.
   Once merged, `main` declares the build that will ship.
4. **[Regenerate the website's facts](#version-and-changelog)** from `main`
   and commit them in `lagoon-website`. The site serves the old version until
   its own, separate deploy.
5. **[Upload](#releasing-from-ci)** from `main`. It records the revision it
   archived.
6. **Add the build to the external group** in App Store Connect and wait for
   [Beta App Review](#external-testflight).
7. **[Publish the release](#release-tags)**, after acceptance.

Without the workflow, `scripts/prepare-release.sh <bump> "<headline>"` stamps
the same files locally for you to commit through a pull request, and
[Internal TestFlight](#internal-testflight) covers uploading from a Mac.

## Version and changelog

**Build number.** Lagoon owns its build numbers, and only the prepare step
advances them, once per build that will be distributed. It calls
`scripts/bump-build.sh`, which moves all configurations and the app and Top
Shelf together and rejects backwards numbering and configuration drift. The
build number, not the version, identifies a binary. About shows both as
`0.2.0 (107)`.

**Marketing version.** Always `MAJOR.MINOR.PATCH`: major for a significant
rework, minor for new features, patch for fixes only. It borrows semantic
versioning's shape, not its promise, since Lagoon has no API. (A package
extracted from this repo would use real semver.) Prepare takes the bump and
writes `MARKETING_VERSION` in both configurations of
`Lagoon.xcodeproj/project.pbxproj`. **Never use `xcrun agvtool
new-marketing-version`**: with `GENERATE_INFOPLIST_FILE = YES` the version
keys come from build settings, so agvtool reports success and changes
nothing.

**Unreleased notes.** A change a viewer would notice adds its line to
`Changelog.unreleased` in
[`Changelog.swift`](../Lagoon/Features/Settings/Changelog.swift), in the pull
request that makes the change. Anything there has not shipped, so nobody has
to ask whether the top entry is still open. Prepare moves the lines into a new
entry with the version, build, release month and headline, and empties the
list. Entries are newest first. Tests require the installed version and
build to have an entry, and hold unreleased lines to the same rules. Builds
from before the changelog are not reconstructed.

Prepare refuses while the build `main` declares has never been uploaded,
since that build is still the next release. It also refuses when there are no
unreleased notes.

- One line per noticeable improvement, most useful first. Describe the fixed
  symptom and any setup needed.
- One short sentence, two only when setup needs saying: what changed, never
  why or how. Causes and caveats go in the commit.
- No ticket keys, filenames, internal refactors, tests, docs, or fixes to
  work that never shipped. No em dashes. `ChangelogTests` enforces this.
- Notes are written per change and collected per release, not generated from
  commits.
- About groups each build's notes as **New features**, **Improvements** or
  **Bug fixes**. Keep related notes under the category a viewer would
  notice, in that order. About badges the installed build.

### The published changelog

[`CHANGELOG.md`](../CHANGELOG.md) is generated from `Changelog.entries` by
`scripts/generate-changelog.sh`, which prepare runs. Unreleased notes are not
in it. Never edit it by hand. The About screen, the
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
unique and is what viewers see in About and quote in bug reports. The version
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

It tags the revision `scripts/upload-testflight.sh` recorded when it archived
the build (`build/archived-<build>.sha`, local to the machine that uploaded).
Without a record it tags `HEAD`, and if that is past the commit that set the
build number, it asks. Pass `--rev` to name the archived revision yourself.
It asks even then, so run it in a terminal. Piped or from an agent, it stops.
The version and build come from the tagged revision, so an earlier build can
be published after the project has moved on.

**A shipped build without a release blocks the next upload.**
`scripts/upload-testflight.sh` lists every changelog entry newer than the
newest published release, other than the build being uploaded, and refuses to
start while there is one. Publish it first. `--dry-run` shows the list and
carries on.

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

1. Merge the release pull request from prepare, so `main` declares the build
   and has its changelog entry.
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
- These can go in `.env` (copy [`.env.example`](../.env.example)). Exported
  values override it. The script refuses to run if `.env` is staged.

### Archiving in Xcode switches diagnostics off

**A build archived by Xcode reports nothing, silently.**

`LagoonInfo.plist` sets `LagoonSentryDSN` to `$(LAGOON_SENTRY_DSN)`, and the
project leaves that setting empty. `upload-testflight.sh` fills it at archive
time. Xcode does not. `DiagnosticsConfiguration.resolveDSN` treats an empty or
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

Live since 0.2.1 (109), approved for iOS and tvOS on 2026-09-24. Testers
join the external group "Lagoonies Beta" through its public link, which the
website carries.

Adding a build to an external group submits it to Beta App Review under the
full App Review Guidelines. Uploading alone never does. Apple reviews a
platform's first build, and later ones usually pass without review. iOS and
tvOS are separate binaries under one record and are reviewed separately.

**A build exported through the internal flow can never reach external
testing.** `testFlightInternalTestingOnly=true` is a property of the upload,
and no existing build can be promoted. `scripts/upload-testflight.sh
--external` uploads a build that can go to an external group, and [the
release workflow](#releasing-from-ci) always does. Adding it to a group, and
so to Beta App Review, stays a manual step in App Store Connect.

Required before submitting:

- A working privacy policy: a **URL** for iOS, policy **text** in App Store
  Connect for tvOS. See [Website](#website).
- Beta App Description and a feedback email. tvOS testers cannot send in-app
  feedback or screenshots, so that address is their only channel.
- App Review Information: contact details and sign-in credentials, since the
  app shows nothing until a server is configured.
- Age rating and content rights (app-level, and content rights covers showing
  third-party content).
- Export compliance, already met by `ITSAppUsesNonExemptEncryption=NO`.

A reviewer needs a reachable server and account, and there is no demo mode
outside `#if DEBUG`. `demo.jellyfin.org/stable` is rights-cleared and nothing
auto-connects to it, but it is a third party's server and an outage during
review looks like a broken app. Review notes should:

- give username and password, not Quick Connect
- say Seerr is optional and will show its connect prompt
- say requests go to the user's own Jellyseerr, and downloads come from their
  own server under that account's policy

Distributing to testers outside the team counts as distribution for licence
purposes. See the native-component gate under [Public
release](#public-release).

## Releasing from CI

`.github/workflows/release.yml` runs only when started by hand (Actions,
Release, Run workflow). Its jobs use the `release` environment, which only
`main` may use, so a run from any other branch never gets the secrets. It has
four actions:

- **prepare** runs `scripts/prepare-release.sh` with the chosen bump and
  headline, which stamps the release as [above](#version-and-changelog),
  then pushes `chore/release-<version>` and opens its pull request. It acts
  through a token minted from the release GitHub App, because a pull request
  opened with the workflow's own token never starts the checks `main`
  requires.
- **trial** archives and signs both platforms with `--export-only`. Nothing
  is uploaded or kept, since artifacts of a public repository are public. Run
  it after a signing or Xcode change.
- **upload** runs `scripts/upload-testflight.sh both --external`, then pushes
  `refs/archived/<build>` to record the revision it archived. The upload
  script's checks all apply, including the [release guard](#release-tags).
- **publish** runs `scripts/publish-release.sh`, which tags the recorded
  revision. Run it once the build is accepted. Leave the build empty for the
  build `main` declares, or give an earlier one.

Signing goes through the App Store Connect API key, so the runner needs no
certificates. The secrets belong to the `release` environment (Settings,
Environments, release), never to the repository:

| Secret | Value |
| --- | --- |
| `ASC_KEY_ID` | The API key's id |
| `ASC_ISSUER_ID` | The issuer id from the same page |
| `ASC_KEY_P8` | The full contents of the `.p8` file |
| `LAGOON_SENTRY_DSN` | As in `.env` |
| `RELEASE_APP_CLIENT_ID` | The release GitHub App's client id |
| `RELEASE_APP_PRIVATE_KEY` | The full contents of a private key generated for that app |

The release app belongs to `helop-ou`, has no webhook, and holds Contents and
Pull requests read and write. It acts only on the repositories it is installed
on, so another project reuses it by installing it there and adding the same
two secrets. Its tokens last an hour and are minted per run, so nothing
expires. When prepare fails to push or open its pull request, check that the
app is still installed on this repository.

The key needs the Admin role. App Manager can upload, but the runner has no
certificates, so the key must also create the development certificate the
archive signs with and use the cloud-managed distribution certificate. Each run
may leave another "Created via API" development certificate in the account, so
check the Certificates list now and then. The workflow runs on the same `xcode-27` image and Xcode as the
[tests](standards.md#continuous-integration), so move both together.

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
  resources, and checks the entries against the binary targets the native
  inventory records. It fails until the inventory matches the pin, so
  regenerate the inventory in the same change that moves the pin.
- Some pinned prebuilt native frameworks lack usable dSYMs. The resulting
  upload warning limits native symbolication. Tell it apart from missing app
  or extension symbols by reading the actual archive warnings.

A separate assessment covers data flow, native licensing, encryption and the
required-reason API. It is a point-in-time snapshot. Reconcile it with the
actual release before making declarations. The [native
inventory](reference/native-dependency-inventory.json) is generated by
`scripts/inventory-native-dependencies.py` from the engine checkout SwiftPM
resolved, and records that engine's version and revision. The script refuses
a checkout other than the one `Package.resolved` pins. Keep exact input hashes
and build records with the candidate.

## Public release

The App Store takes the same upload as external testers. A build the
[upload action](#releasing-from-ci) sends is external-eligible, and that also
makes it a build an App Store version can select. Only an internal-only upload
is shut out of both. There is no separate public export. These gates apply to
the exact build that will be submitted, not an earlier one.

### Decisions before a public candidate

- [x] Licence selected and applied: **MPL-2.0** for Lagoon's own code, with
  the Lagoon name and brand assets carved out of the grant. Chosen for
  attribution rather than reciprocity. It matches Swiftfin and
  jellyfin-sdk-swift and avoids the GPL's conflict with App Store terms.
  `LICENSE` carries the canonical text verbatim, `TRADEMARKS.md` the
  carve-out, and `CODE_OF_CONDUCT.md` the Contributor Covenant.
- [ ] Deliver the corresponding-source, notices and relinking materials for
  every native component. FFmpeg is statically linked, so the shared-library
  route is unavailable. Publishing the source is the cheapest way to
  discharge this and removes the per-release burden. Since engine 1.0.2 all
  four FFmpeg libraries are built by the engine from checksum-pinned source
  without `--enable-version3`, and are LGPL-2.1-or-later, and dav1d, lcms2
  and uavs3d are built there too. libdovi is the one component vendored
  prebuilt, because it needs a Rust toolchain. In place: every engine release
  attaches FFmpeg's corresponding source (upstream tarball, patch, build
  script and configure records). Each artifact ships its licence, libdovi's
  with its Rust crates. The FFmpeg notice links that release and credits the
  Independent JPEG Group, whose DCT code is in libavcodec. Both repositories
  have been public since 2026-09-23, before the first external build. Owed:
  the FFmpeg line on the website's download pages. Whether the App Store's
  usage rules are a further restriction under LGPL-2.1 §10 is a legal
  judgement, not an engineering one. VLC for iOS ships the same arrangement.
- [ ] Record the encryption classification and territories, including
  France, in App Store Connect. The build already declares
  `ITSAppUsesNonExemptEncryption=NO`, and the answers must agree with it.
- [ ] Approve the App Privacy labels in App Store Connect and review the
  Organizer privacy report. The app manifest already declares diagnostic and
  performance data, unlinked and not used for tracking. The labels must say
  the same, as must the Settings footer and the privacy page.
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
- [ ] Complete physical acceptance. The device checks owed by shipped work
  are done. Owed: the local-network permission journey on a fresh iPhone and
  iPad install, an accessibility pass per device class, and long playback
  with repeated start and stop on hardware.

### The release candidate

**The marketing version is part of the binary.** App Store Connect only lets
a version select a build whose `CFBundleShortVersionString` matches it, so a
0.x build can never be submitted as 1.0. Prepare the candidate with a major
bump, and it reaches external testers as 1.0.0. A fix found after that is a
patch, and the App Store version follows whichever build is submitted.

1. **Prepare and merge** as for any build ([Cutting a
   build](#cutting-a-build-start-to-finish)). The release pull request's
   checks run both unit suites on that revision.
2. **Run the UI and hardware journeys** that apply on the merged revision.
   Archive runs no tests. Keep the result bundles with device, OS, media and
   server details.
3. **Check the packaging.** The upload action keeps no archive, because
   artifacts of a public repository are public. Archive the same revision
   locally with `scripts/upload-testflight.sh both --archive-only`, then run
   `python3 scripts/validate-release-privacy.py <archive>` on both and review
   the Organizer privacy report, icons, Top Shelf artwork and symbols. The
   script checks resources and basic bundle consistency. It is not Apple's
   validation or legal approval.
4. **Upload, test and publish** as for any build: the upload action, the
   external group, then the publish action once Beta App Review accepts it.
   The tag is how a recipient finds the corresponding source, which the
   native licences require, so the build is published before it is
   submitted and needs no second tag.
5. **Submit.** In App Store Connect, create the version for iOS and for tvOS,
   select the uploaded build on each, complete the [review
   package](#review-package) and submit. Check the build number and platform
   on each before submitting. Beta App Review and App Store review are
   separate, so passing one says nothing about the other.

Keep per-slice dependency hashes and build records with the submitted build,
and regenerate the inventory if an input changes.

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
  submission and release. Record the review result and follow up on App Store
  warnings.

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
  rights-cleared screenshots, and the App Store destination. Keep site and
  store copy consistent with the actual formats, devices, server setup and
  subtitle permissions.
- The site links the external group's public TestFlight link
  (`site.testflight` in `lagoon-website`). Closing or replacing that group
  means changing the site in the same sitting.
