#!/bin/bash
# Builds TestFlight candidates for both platforms: bumps the build number,
# archives tvOS + iOS, then uploads to App Store Connect when an API key is
# provided, or hands the archives to Xcode's Organizer when not.
#
# Scripted upload needs an App Store Connect API key (App Manager role):
#   ASC_KEY_PATH=~/keys/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX \
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-... scripts/testflight.sh
#
# Prerequisites (once): a registered device per platform on the team (else
# archiving fails with "team has no devices") and the ee.helop.lagoon app
# record in App Store Connect. See docs/release.md.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=build/testflight
PLATFORMS=(tvOS iOS)

xcrun agvtool next-version -all
echo "Marketing version: $(xcrun agvtool what-marketing-version -terse1), build: $(xcrun agvtool what-version -terse)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

for platform in "${PLATFORMS[@]}"; do
    echo "==> Archiving $platform"
    xcodebuild archive \
        -scheme Lagoon \
        -destination "generic/platform=$platform" \
        -archivePath "$BUILD_DIR/Lagoon-$platform.xcarchive" \
        -allowProvisioningUpdates \
        -quiet
done

if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    for platform in "${PLATFORMS[@]}"; do
        echo "==> Uploading $platform to App Store Connect"
        xcodebuild -exportArchive \
            -archivePath "$BUILD_DIR/Lagoon-$platform.xcarchive" \
            -exportOptionsPlist ExportOptions.plist \
            -allowProvisioningUpdates \
            -authenticationKeyPath "$ASC_KEY_PATH" \
            -authenticationKeyID "$ASC_KEY_ID" \
            -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    done
    echo "Uploaded. Builds appear in TestFlight after processing (~10 min)."
else
    echo "No ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID set."
    echo "Opening archives in Xcode — use Organizer: Distribute App → TestFlight Internal Only."
    for platform in "${PLATFORMS[@]}"; do
        open "$BUILD_DIR/Lagoon-$platform.xcarchive"
    done
fi

# Remind about the version bump sitting in the working tree.
echo "Remember to commit the build-number bump: git add -A && git commit -m 'chore: bump build number (HEL-44)'"
