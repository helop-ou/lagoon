# Public 1.0 candidate checklist

HEL-143. This is a separate procedure from the internal-only TestFlight upload.
No public export, upload, release or App Store Connect declarations have been
performed by the privacy implementation pass.

## Decisions before a public candidate

- [ ] Complete the licensing decision and deliver/test the corresponding-source,
  notices and relinking materials for every native component.
- [ ] Record encryption classification and territories, including France; align
  build declarations and retain any required documentation.
- [ ] Approve data collection/retention answers, complete the app's collection
  manifest and App Privacy labels, and generate/review Xcode's privacy report.
- [ ] Resolve the direct OpenSubtitles consumer arrangement or exclude it from
  public 1.0, then update UI, tests, privacy and support copy to match.
- [ ] Publish privacy/support pages with the selected domain, publisher identity
  and monitored contact. Add privacy/support/acknowledgements access before login
  and in About; verify iPhone/iPad and tvOS presentation.
- [ ] Complete HEL-144 physical acceptance, including the permission journey from
  HEL-143 and pending HEL-141/142 device checks.

## Prepare and verify the exact release

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

## Public export procedure

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

## Review package

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
