# HEL-143: privacy and release preparation

Archived validation/audit record. Dates, ticket states, and results below apply
to the recorded work. Use the [current guides](../README.md) and
[release checklist](../release.md#public-release) for ongoing work.

September 7, 2026. Implementation based on `0a63c4c`, version 0.1 (90).
**In Progress.** This pass implements required-reason manifests and local-network
recovery, records native artifact evidence, and prepares website copy. It does
not complete the licensing, App Privacy, public website or distribution decisions.

## Required-reason API inventory

The app's resource is `Lagoon/PrivacyInfo.xcprivacy`. Its four categories cover
both first-party code and the native code statically linked into that executable.
The Top Shelf extension has its own resource and no declared required-reason
APIs: after HEL-141 it only reads a local, credential-free snapshot and local
artwork. It neither accesses UserDefaults nor makes network requests. Its
archived executable has no matching C API or NSUserDefaults imports.

| Executable/category | Source evidence | Reason and use |
| --- | --- | --- |
| App: UserDefaults | `@AppStorage` preferences; `SessionStore`, `RecentSearchStore`, `AccountLocalData`; app-group legacy cleanup in `TopShelfStore` | `CA92.1` app-private preferences; `1C8F.1` the app's own shared-group defaults |
| App: FileTimestamp | `PlaybackCache.removeStaleDirectories` uses `contentModificationDateKey`; native FFmpeg imports `stat`/`fstat`/`lstat` | `C617.1` app/container file metadata; stale cache cleanup. Native import presence is broader than the runtime paths used by Lagoon. |
| App: DiskSpace | `PlaybackCache` reads `systemFreeSize` to set a cache budget; `fstatfs` supplies block allocation accounting | `E174.1` capacity-sensitive writing and cache eviction |
| App: SystemBootTime | `PlaybackCache`, `FFmpegDemuxer`, `SoftwareVideoDecoder`, `MetalFrameConverter`, `DiscImage`, playback controls and timing diagnostics use `systemUptime` | `35F9.1` elapsed durations and deadlines; raw boot-time values are not transmitted |
| Top Shelf | `ContentProvider.swift`: `Data(contentsOf:)`, file existence checks and snapshot decoding | Empty API category list; do not copy the app's categories into an unrelated executable |

These reason codes were checked against Apple's [required-reason API list](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
Reassess the reasons whenever file access, diagnostics, app-group usage or native
build options change. No active-keyboard API use was found.

`scripts/inventory-native-dependencies.py` inspects all 8 binary targets and
55 declared slices, including Catalyst, visionOS and macOS slices that this app
does not ship. [The generated inventory](../reference/native-dependency-inventory.json) records
package URL/checksum pins, per-slice binary hashes/types and required-reason C
imports. On iOS arm64, libavformat imports `fstat`, `lstat`, `stat` and
libavutil imports `fstat`; the other six (including the new libdovi target,
HEL-145) have no matches in the scanned
C-symbol set. This is an aid to review, not exhaustive dynamic
coverage or an Objective-C selector analysis.

FFmpeg's local file protocol/mapping code accounts for its metadata imports.
Lagoon supplies playback through its scoped byte source and app-owned caches.
libavformat carries no network stack, so certificate trust is URLSession's
system evaluation. Lagoon does not configure arbitrary CA/certificate/key
files. Adding those features requires reviewing file-access
reasons before shipping; the import scan alone cannot establish permitted use.

Both manifests declare no tracking. **The app manifest currently covers
required-reason APIs only:** `NSPrivacyCollectedDataTypes` is deliberately absent
until the service-retention assessment below is completed. It must not be used
as evidence for an App Store “Data Not Collected” answer. The extension declares
an empty collection list because its snapshot remains on device. Apple's
[manifest guidance](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
and [App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
require assessing collection and linkage, including relevant third parties.

## Local-network permission and recovery

`NSLocalNetworkUsageDescription` explains connections to the Jellyfin and Seerr
servers the viewer chooses. No Bonjour service enumeration, multicast entitlement
or broad ATS exception was added. The common plist also includes the text in the
tvOS bundle; tvOS does not show this permission prompt.

On iOS, a failed connectivity request can open a bounded TCP diagnostic connection
to the same requested origin. Only Network.framework's explicit
`currentPath.unsatisfiedReason == .localNetworkDenied` becomes a permission error.
No application data or credentials are sent by that connection. Cancellation,
certificate errors and authentication failures do not trigger it; an offline
server is not presumed to mean permission denial. See Apple's
[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

Jellyfin setup retains the address, shows **Open Settings**, and allows an explicit
Connect retry after returning. A confirmed denial stops alternate scheme/port
probes. Seerr setup and saved-connection restoration expose the same guidance,
with retry using the saved address if restoration finished after the view opened.
Generation checks prevent an outgoing account's late diagnosis from changing
the new account's client. URLSession waits for connectivity during an initial
permission decision; failures remain bounded (15 seconds for the Jellyfin public
probe, Seerr's existing 20-second operation deadline, up to one second for diagnosis).

### Physical acceptance still required

On fresh physical iPhone **and** iPad installs, use an owned LAN Jellyfin/Seerr
fixture. Verify Allow reaches sign-in; Deny shows the recovery guidance; opening
Settings and re-enabling permission allows retry without retyping the endpoint.
Repeat for a saved Seerr connection. Check offline Wi-Fi/server failures and an
untrusted HTTPS certificate do not get mislabeled as permission denial. Confirm
cancellation/navigation does not install a late connection. Do not reset the
owner's app or privacy settings to manufacture a fresh state.

The simulator test injects only the denial *diagnosis*, in DEBUG and for the exact
loopback fixture origin after a real URLSession connectivity error. It verifies
the UI/Settings round trip, not the OS prompt or real Network path diagnosis.

## Data flows to reconcile with App Privacy

| Feature/recipient | Data leaving the app | Local retention and release decision |
| --- | --- | --- |
| Viewer-selected Jellyfin server | Login credentials/Quick Connect, account and stable device identity, requested titles, searches, playback progress and actions | Tokens in Keychain; account metadata/preferences locally. Server-side history/log retention belongs to the chosen operator. Document whether any operator is a developer service/partner. |
| Viewer-selected Seerr | Server requests, Jellyfin authentication/Quick Connect exchange or entered credentials, Seerr session, searches, requests/moderation actions | Cookies in Keychain per Jellyfin account and Seerr origin; local pairing/preferences. Confirm deployment retention and identity linkage. |
| TMDB image CDN | Artwork paths, ordinary connection/IP information | `SeerrClient.imageURL` directs image requests to `image.tmdb.org`; app image cache. Check current CDN retention/terms before final labels. |
| Direct OpenSubtitles integration | None; removed under HEL-146 | The optional per-device integration was removed on privacy-policy grounds: OpenSubtitles' REST terms require one API key per application and ban apps that ask users to supply their own, which is what the shipped design did. No data leaves the app for this feature; subtitle search now relies solely on the selected Jellyfin server's permission-gated routes. |
| Jellyfin-provided subtitles | Subtitle/search/download requests through the selected Jellyfin server | Provider behavior is the server's, configured by its administrator. Do not imply every provider request goes directly from Lagoon. |
| Recent searches/cache | No additional upload merely to persist recent search history or buffer media; original search/media requests still go to their services | Search history scoped by account, owned media/image caches, account cleanup from HEL-141 |
| tvOS Top Shelf | None from the extension | App creates sanitized artwork/snapshot in its group; opt-out and account-scoped publication; no extension credentials |
| Diagnostics/support | Local logs and benchmark durations; user-shared support material and Apple-provided crash/test feedback if enabled | No analytics/ad SDK found. Verify actual receipt, retention and deletion policies for Apple reports and the future support channel. Do not promise that logs contain no personal information. No first-party media request built by the app carries the Jellyfin access token in its URL any more (`MediaRequestAuthorization` sends it as an `Authorization` header instead), so CFNetwork's unified-log record of a failed task's full URL can no longer expose it. |

Potential label categories requiring decisions include User ID, Device ID,
Search History, Product Interaction, and diagnostic/support data. Account-linked
server data is not anonymous simply because Lagoon has no analytics backend.
Conversely, on-device-only storage and data immediately discarded after servicing
a request are not automatically reportable collection under Apple's definition.
Do not fill the manifest or App Store Connect with guessed retention claims.

## Native licensing and encryption assessment

All 8 input frameworks contain static archives. Fresh iOS/tvOS app executables
have no load commands for these native frameworks. Small dynamic framework
executables in Xcode's product packaging do not establish dynamic linkage of the
actual libraries. The obligations must follow the static inputs and app linkage.
libavformat was rebuilt on the transport spike branch (September 8); the other native binaries are unchanged. No GCC was invoked. The notice half of what follows — each component's version, licence name, copyright and exact source tag — now ships in-app as `Lagoon/Models/Acknowledgements.swift` with the licence texts bundled under `Resources/Licenses`; the Materials status column below is a separate, still-open concern and is unaffected by that.

| Component | Version evidence | Materials status |
| --- | --- | --- |
| libavcodec, libavutil, libswresample | FFmpeg 8.1.2, MPVKit release `1.0.0`, immutable package ZIP hashes. Configured upstream with `--enable-version3` (their `config.h` records `CONFIG_VERSION3 1`), so `avcodec_license()` still answers LGPL v3-or-later even though no v3-only component is linked into them | Rebuild these three in-repo without `--enable-version3` (the libavformat script already builds the whole tree) for an unambiguous LGPL-2.1-or-later record; corresponding source, build changes and per-component flags still need a retained release bundle. |
| libavformat | Owned FFmpeg n8.1.2, built without networking (`scripts/build-ffmpeg-format.py`, transport spike); `BUILD.json` records `network: false` and `license: LGPL-2.1-or-later`; source SHA-256, compiler/flags and per-file artifact hashes | Build script and license texts retained; corresponding-source distribution and application relinking kit are not complete. |
| dav1d | Owned 1.5.4 with arm64 assembly | Build script retained; add immutable source digest, matching source archive and BSD notices. |
| lcms2 | Header `LCMS_VERSION=2170`, upstream release 2.17.0 | Retain matching source/build provenance and MIT notices. |
| uavs3d | Pinned binary release `1.2.1-fix` | Release label is not a complete source commit; resolve upstream changes and retain BSD notices. |
| libdovi | dovi_tool's `dolby_vision` crate 3.4.0, dual-licensed MIT/Apache-2.0 (MIT option elected); vendored prebuilt from superuser404notfound/LibDovi tag 2.1.0, per-slice hashes in `Packages/LagoonFFmpeg/Artifacts/Libdovi.README.md` (HEL-145) | A notice for quietvoid (dovi_tool/LibDovi's author) is required in acknowledgements. Materials: retain the upstream source tag and LibDovi's build recipe (`build.sh`) — this repo has no Rust toolchain, so it cannot rebuild libdovi itself. |

`--enable-version3` is gone from the FFmpeg build: since the transport spike
(September 8), libavformat is built without networking and without GnuTLS, so
the repo-built libavformat records **LGPL-2.1-or-later** rather than
LGPL-v3-or-later, and the GnuTLS/GMP/nettle/hogweed rows above no longer
apply. The three MPVKit-built libraries still carry upstream's
`--enable-version3` election in their binaries until they are rebuilt here. That does not by itself finish compliance — a generic LGPL-2.1
attribution copied from a website is still insufficient without the matching
source and build changes the license requires. Do not assume optional GPL
code listed in FFmpeg's LICENSE was enabled: the owned build does not enable
GPL/nonfree. Verify the other linked component builds too.
[FFmpeg's checklist](https://www.ffmpeg.org/legal.html) emphasizes matching sources
and build changes; [LGPL 2.1 section 6](https://www.gnu.org/licenses/old-licenses/lgpl-2.1)
governs combined works and the application code/materials needed for relinking.

The concrete candidate solution for the current static engine is a versioned
recipient bundle containing exact library sources, patches/configurations,
copyright/license texts, the necessary Lagoon application object code or source,
and tested commands to recombine/relink with modified libraries. The distribution
terms must permit the applicable modification/reverse-engineering rights. Resolve
installation information, signing and App Store distribution compatibility before
choosing this route. Validate a modified-library relink on a clean machine.
This is a proposed implementation route, **not an approved compliance decision**;
attribution alone and source links to moving upstream branches do not finish it.

Encryption evidence: as of the transport spike (September 8), the app no
longer bundles a non-Apple TLS or bignum implementation — GnuTLS, nettle/hogweed
and GMP are gone along with libavformat's network stack. Transport encryption
for media now goes through Apple's URLSession, alongside the existing
Keychain/Security.framework use, which is the ordinary "uses only
OS-provided encryption" case for the export-compliance declaration. That is
an assessment worth recording here, not a legal conclusion by itself: still
record the applicable US classification/exemption, reporting obligations and
intended territories before affirming `ITSAppUsesNonExemptEncryption=NO` or
changing it. France remains undecided. Check Apple's [encryption documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
and [export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
against the actual release and retain the supporting assessment/documents.

## Website, integration and release decisions

The website is built in the separate `lagoon-website` repository (September 10,
2026) and not yet published. The [website brief](website/README.md) records
`lagoon.helop.ee` as the proposed starting address and what remains before
publication; domain control and the support contact still need confirmation.
[Privacy copy](website/privacy.md) and [support copy](website/support.md) were the
local drafts for it and are superseded by the pages in the website repository. In-app acknowledgements and
pre-login access to legal information are done, closing the in-app half of
the readiness audit's A06: Settings → About → Legal and the signed-out
"About Lagoon" action both work today. Publishing the privacy/support pages
and filling in `LegalDestinations` with their live URLs remain open; until
then, Settings shows only the rows whose URL is set. The same approved
content must populate App Store Connect, including its tvOS privacy-policy
text.

A16 is resolved by exclusion (HEL-146, September 8): the direct OpenSubtitles
integration and its per-device API key were removed rather than given a
verified consumer arrangement. Subtitle search now relies solely on Jellyfin's
permission-gated remote-subtitle routes, and Settings shows the account's
permission state.

Use [the public checklist](../release.md#public-release) for metadata, review
fixtures, signed validation and an explicitly separate public export. HEL-143
remains In Progress while these decisions and implementation steps remain open.

## Validation

- iOS Simulator 26.5: **527 tests / 59 suites**, zero failures,
  `/private/tmp/lagoon-hel143-complete-ios.xcresult`.
- tvOS Simulator 26.5: **551 tests / 61 suites**, zero failures,
  `/private/tmp/lagoon-hel143-complete-tvos.xcresult`.
- The existing opt-in native TLS matrix/allocation stress cases are skipped in
  these normal suites; their separate HEL-142 evidence remains in that ticket's
  validation record. No new compiler warnings were found in the changed code;
  existing concurrency warnings elsewhere remain.
- New unit coverage checks denial classification, offline/security/cancellation
  boundaries, cancellation of diagnosis, and stopping alternate-address attempts
  followed by successful retry of the original endpoint.
- iPhone UI: **one combined journey passed**, including Jellyfin denial → Settings
  → retry/sign-in; Seerr initial denial/retry; and relaunch with a saved Seerr
  server followed by denial/retry. Result bundle:
  `/private/tmp/lagoon-hel142-validation/20260907-230020/iOS/Recovery.xcresult`.
  Screenshots are exported alongside it and visually reviewed. Seerr recovery
  guidance appears directly below the server details, before sign-in controls.
  The fixture uses synthetic media and
  accounts; its disposable simulator is deleted afterward.
- Both unsigned device **archives** passed:
  `/private/tmp/lagoon-hel143-reviewed-ios.xcarchive` and
  `/private/tmp/lagoon-hel143-final-tvos.xcarchive`. The validator confirms the
  app manifest, tvOS extension manifest, purpose text, version consistency and
  narrow ATS configuration. The DEBUG denial-origin hook is absent from Release.
- Validator negative fixtures rejected missing app/extension manifests, an
  unapproved reason, mismatched extension build, broad ATS and empty iOS purpose.
- The paired iPhone was disconnected with DDI services unavailable when checked.
  No physical iPad or Apple TV was available. Physical permission acceptance,
  signed archive/App Store validation and Xcode Organizer privacy-report review
  remain pending; unsigned archive checks do not establish those results.

Repeat with available simulator identifiers/paths:

```sh
xcodebuild test -scheme Lagoon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LagoonTests
xcodebuild test -scheme Lagoon -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' -only-testing:LagoonTests
python3 scripts/test-session-recovery.py --local-network --work /private/tmp/lagoon-session-validation
python3 scripts/inventory-native-dependencies.py --artifacts /path/to/DerivedData/SourcePackages/artifacts --report /private/tmp/native-inventory.json
python3 scripts/validate-release-privacy.py /path/to/Lagoon.xcarchive --report /private/tmp/privacy-packaging.json
```
