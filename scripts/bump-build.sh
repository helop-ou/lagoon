#!/usr/bin/env bash
#
# Bumps CURRENT_PROJECT_VERSION in the Xcode project.
#
# Lagoon owns its build number rather than letting Xcode assign one at upload,
# so that the repository can say what shipped as what, the changelog entry can
# be written before the build goes out, and ChangelogTests can actually gate on
# it. Turning that off is a checkbox in Xcode's upload sheet — "Automatically
# manage version and build number" must stay unchecked.
#
# The setting lives at project level, so one value covers the app and the Top
# Shelf extension, which App Store Connect requires to match.
#
#   scripts/bump-build.sh            # next build
#   scripts/bump-build.sh --set 60   # jump to a specific number
#
set -euo pipefail

project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Lagoon.xcodeproj/project.pbxproj"
[ -f "$project" ] || { echo "error: $project not found" >&2; exit 1; }

values="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$' | sort -u)"
if [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" != "1" ]; then
    echo "error: CURRENT_PROJECT_VERSION differs across configurations:" >&2
    printf '  %s\n' $values >&2
    echo "The app and the Top Shelf extension must ship the same build number." >&2
    exit 1
fi

current="$values"
case "${1:-}" in
    --set)
        next="${2:?usage: bump-build.sh --set <number>}"
        [[ "$next" =~ ^[0-9]+$ ]] || { echo "error: --set needs a number" >&2; exit 1; }
        # App Store Connect rejects a build number that does not increase, and
        # only per platform — so going backwards locally is a mistake that only
        # surfaces at upload.
        if [ "$next" -le "$current" ]; then
            echo "error: $next is not above the current $current" >&2
            exit 1
        fi
        ;;
    "") next=$((current + 1)) ;;
    *)  echo "usage: bump-build.sh [--set <number>]" >&2; exit 1 ;;
esac

sed -i '' "s/CURRENT_PROJECT_VERSION = ${current};/CURRENT_PROJECT_VERSION = ${next};/g" "$project"

marketing="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$project" | grep -o '[0-9.]*$')"
echo "Build ${current} -> ${next} (version ${marketing})"
echo
echo "Next: add a ChangelogEntry for ${marketing} (${next}) at the top of"
echo "Lagoon/Features/Settings/Changelog.swift, then commit both. ChangelogTests fails"
echo "until that entry exists."
