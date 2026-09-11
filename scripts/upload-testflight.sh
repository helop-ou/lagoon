#!/usr/bin/env bash
#
# Archives and uploads an internal-TestFlight build without the Organizer.
#
# The Organizer's preset tiles ("Use recommended settings…") skip the options
# pages, and the default there rewrites the version and build number on the way
# out — which is how the project came to say build 1 while ~43 tvOS builds
# existed. ExportOptions.plist pins that off in a committed file instead of
# leaving it to a checkbox someone has to remember (HEL-94).
#
#   scripts/upload-testflight.sh both --dry-run   # print the commands only
#   scripts/upload-testflight.sh tvos
#   scripts/upload-testflight.sh both
#
# Authentication uses an App Store Connect API key, since xcodebuild cannot
# reuse Xcode's signed-in account non-interactively. Create one under
# App Store Connect → Users and Access → Integrations → App Store Connect API
# and export:
#
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ASC_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
#
# Keep the .p8 out of the repository. It is a credential for the whole account.
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/Lagoon.xcodeproj/project.pbxproj"
options="$root/ExportOptions.plist"
build_dir="$root/build"

platforms="${1:-both}"
dry_run="${2:-}"
[ "${dry_run}" = "--dry-run" ] || [ -z "${dry_run}" ] || {
    echo "usage: upload-testflight.sh [tvos|ios|both] [--dry-run]" >&2; exit 1
}

case "$platforms" in
    tvos) targets="tvOS" ;;
    ios)  targets="iOS" ;;
    both) targets="tvOS iOS" ;;
    *)    echo "usage: upload-testflight.sh [tvos|ios|both] [--dry-run]" >&2; exit 1 ;;
esac

version="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$project" | grep -o '[0-9.]*$')"
build="$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$')"

# Pre-flight, because an archive takes minutes and a missing changelog entry is
# the easy thing to forget. ChangelogTests enforces the same rule, but only
# once something has been built.
changelog="$root/Lagoon/Features/Settings/Changelog.swift"
if ! grep -A 2 "version: \"${version}\"" "$changelog" | grep -q "build: \"${build}\""; then
    cat >&2 <<EOF
error: no Changelog entry for ${version} (${build}).

Add one at the top of Lagoon/Features/Settings/Changelog.swift, then commit it with the
build-number bump. Shipping a build nobody wrote notes for is the thing this
whole setup exists to prevent.
EOF
    exit 1
fi

echo "Lagoon ${version} (${build}) → TestFlight internal, for: ${targets}"
echo

if [ "$dry_run" != "--dry-run" ]; then
    : "${ASC_KEY_ID:?set ASC_KEY_ID (see the header of this script)}"
    : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
    : "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
    [ -f "${ASC_KEY_PATH/#\~/$HOME}" ] || { echo "error: no key at $ASC_KEY_PATH" >&2; exit 1; }
fi

run() {
    if [ "$dry_run" = "--dry-run" ]; then
        printf '  %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

for platform in $targets; do
    archive="$build_dir/Lagoon-${platform}.xcarchive"
    echo "── ${platform}"

    run xcodebuild archive \
        -project "$root/Lagoon.xcodeproj" \
        -scheme Lagoon \
        -destination "generic/platform=${platform}" \
        -archivePath "$archive" \
        -allowProvisioningUpdates

    # With destination=upload in the plist this uploads rather than writing an
    # .ipa, so there is nothing to hand off afterwards.
    run xcodebuild -exportArchive \
        -archivePath "$archive" \
        -exportOptionsPlist "$options" \
        -exportPath "$build_dir/export-${platform}" \
        -allowProvisioningUpdates \
        -authenticationKeyID "${ASC_KEY_ID:-KEY_ID}" \
        -authenticationKeyIssuerID "${ASC_ISSUER_ID:-ISSUER_ID}" \
        -authenticationKeyPath "${ASC_KEY_PATH:-KEY_PATH}"
    echo
done

if [ "$dry_run" = "--dry-run" ]; then
    echo "(dry run — nothing was built or uploaded)"
else
    cat <<EOF
Uploaded. App Store Connect should show ${version} (${build}) once processing
finishes — if it shows a higher build, something renumbered it and
ExportOptions.plist is not being honoured.

Then run scripts/bump-build.sh for the next one.
EOF
fi
