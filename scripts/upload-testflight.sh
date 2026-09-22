#!/usr/bin/env bash
#
# Archives and uploads an internal TestFlight build without the Organizer.
# ExportOptions.plist stops the upload renumbering the version and build.
#
#   scripts/upload-testflight.sh both --dry-run      # print the commands only
#   scripts/upload-testflight.sh both --archive-only # archive, upload in Xcode
#   scripts/upload-testflight.sh tvos
#   scripts/upload-testflight.sh both
#
# --archive-only needs no App Store Connect key. It archives with the Sentry
# DSN and leaves the archives in the Organizer to upload by hand. Archive here,
# not in Xcode: LAGOON_SENTRY_DSN is empty in the project, so a GUI archive
# reports nothing.
#
# Uploading needs an App Store Connect API key (App Store Connect → Users and
# Access → Integrations → App Store Connect API), exported or in .env:
#
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ASC_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
#
# Keep the .p8 out of the repository. It is a credential for the whole account.
#
# Every run except --dry-run also needs the Sentry DSN:
#
#   LAGOON_SENTRY_DSN=https://<key>@<org>.ingest.de.sentry.io/<project>
#
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/Lagoon.xcodeproj/project.pbxproj"
options="$root/ExportOptions.plist"
build_dir="$root/build"

# Credentials from .env, if present. Exported values win.
env_file="$root/.env"
if [ -f "$env_file" ]; then
    if git -C "$root" ls-files --error-unmatch .env >/dev/null 2>&1; then
        echo "error: .env is tracked by git. It must never be committed." >&2
        echo "Run: git rm --cached .env" >&2
        exit 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#export }"
        case "$line" in ''|'#'*) continue ;; esac
        name="${line%%=*}"
        [ "$name" = "$line" ] && continue
        value="${line#*=}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        [ -n "${!name:-}" ] && continue
        export "$name=$value"
    done < "$env_file"
fi

usage() {
    echo "usage: upload-testflight.sh [tvos|ios|both] [--dry-run] [--archive-only]" >&2
    exit 1
}

platforms="${1:-both}"
shift || true

dry_run=""
archive_only=false
# Read every argument, in any order, so a misplaced --dry-run is never ignored.
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run="--dry-run" ;;
        --archive-only) archive_only=true ;;
        *) echo "error: unknown option $1" >&2; usage ;;
    esac
    shift
done

case "$platforms" in
    tvos) targets="tvOS" ;;
    ios)  targets="iOS" ;;
    both) targets="tvOS iOS" ;;
    *)    usage ;;
esac

version="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$project" | grep -o '[0-9.]*$')"
build="$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$')"

# Checked before the slow archive. ChangelogTests enforces the same rule, but
# only after a build.
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
    if [ "$archive_only" = false ]; then
        : "${ASC_KEY_ID:?set ASC_KEY_ID (see the header of this script)}"
        : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
        : "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
        [ -f "${ASC_KEY_PATH/#\~/$HOME}" ] || {
            echo "error: no key at $ASC_KEY_PATH" >&2; exit 1
        }
    fi
    : "${LAGOON_SENTRY_DSN:?set LAGOON_SENTRY_DSN (see the header of this script)}"
fi

run() {
    if [ "$dry_run" = "--dry-run" ]; then
        printf '  %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# The Organizer lists what is in its own archive directory.
organizer_dir="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
[ "$archive_only" = true ] && [ "$dry_run" != "--dry-run" ] && mkdir -p "$organizer_dir"

for platform in $targets; do
    if [ "$archive_only" = true ]; then
        archive="$organizer_dir/Lagoon ${platform} ${version} (${build}).xcarchive"
    else
        archive="$build_dir/Lagoon-${platform}.xcarchive"
    fi
    echo "── ${platform}"

    run xcodebuild archive \
        -project "$root/Lagoon.xcodeproj" \
        -scheme Lagoon \
        -destination "generic/platform=${platform}" \
        -archivePath "$archive" \
        -allowProvisioningUpdates \
        LAGOON_SENTRY_DSN="${LAGOON_SENTRY_DSN:-SENTRY_DSN}"

    if [ "$archive_only" = true ]; then
        echo "  archived to ${archive}"
        echo
        continue
    fi

    # destination=upload in the plist makes this upload instead of writing an .ipa.
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
elif [ "$archive_only" = true ]; then
    cat <<EOF
Archived ${version} (${build}) with the Sentry DSN, and nothing was uploaded.

Open Xcode, Window, Organizer. Both archives are under today's date.
Select one, Distribute App, App Store Connect, Upload.

Untick "Automatically manage version and build number" on the way through.
Left on, it renumbers the build at upload, which is the whole reason this
script and ExportOptions.plist exist. Verify App Store Connect shows
${version} (${build}) afterwards, not something higher.
EOF
else
    cat <<EOF
Uploaded. App Store Connect should show ${version} (${build}) once processing
finishes — if it shows a higher build, something renumbered it and
ExportOptions.plist is not being honoured.

Then run scripts/bump-build.sh for the next one.
EOF
fi
