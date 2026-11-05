#!/usr/bin/env bash
#
# Opens the next release: CHANGELOG.md's Unreleased notes become the next
# build's entry, and the build number and marketing version advance. The
# release workflow's prepare action runs it with --open-pr.
#
#   scripts/prepare-release.sh patch "Up Next shows how long is left."
#   scripts/prepare-release.sh minor "…" --dry-run   # print the entry only
#   scripts/prepare-release.sh minor "…" --open-pr   # commit, push, open the PR
#
# The headline is the one line What's New and the GitHub release lead with.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/Lagoon.xcodeproj/project.pbxproj"
changelog="$root/CHANGELOG.md"

usage() {
    echo "usage: $(basename "$0") <major|minor|patch> <headline> [--dry-run | --open-pr]" >&2
    exit 2
}

bump="${1:-}"
headline="${2:-}"
[[ "$bump" =~ ^(major|minor|patch)$ ]] || usage
[ -n "$headline" ] || usage
mode="${3:-}"
case "$mode" in ""|--dry-run|--open-pr) ;; *) usage ;; esac

die() { echo "error: $*" >&2; exit 1; }

[[ "$headline" != *$'\n'* ]] || die "the headline must be one line"
[[ "$headline" != *"—"* ]] || die "the headline has an em dash. Use a comma, a colon or a full stop."

version="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$project" | grep -o '[0-9.]*$')"
build="$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MARKETING_VERSION \"$version\" is not MAJOR.MINOR.PATCH"

# A build that never went out would be skipped, leaving a hole in the notes.
if [ -z "$(git -C "$root" ls-remote origin "refs/archived/${build}" "refs/tags/*-${build}" 2>/dev/null)" ]; then
    die "build ${build} was never uploaded, so it is still the next release. Upload it before preparing another."
fi

IFS=. read -r major minor patch <<<"$version"
case "$bump" in
    major) next_version="$((major + 1)).0.0" ;;
    minor) next_version="${major}.$((minor + 1)).0" ;;
    patch) next_version="${major}.${minor}.$((patch + 1))" ;;
esac
next_build="$((build + 1))"
released="$(LC_ALL=C date +'%B %Y')"

# Writes CHANGELOG.md with the Unreleased notes moved into a new entry below
# an empty Unreleased heading.
stamp() {
    HEADING="## ${next_version} (${next_build})" RELEASED="$released" HEADLINE="$headline" awk '
        !done && $0 == "## Unreleased" { inside = 1; print; print ""; next }
        inside && /^## / {
            print ENVIRON["HEADING"]; print ""
            print ENVIRON["RELEASED"]; print ""
            print "**" ENVIRON["HEADLINE"] "**"; print ""
            for (i = first; i <= last; i++) print body[i]
            print ""
            inside = 0; done = 1
        }
        inside {
            body[++n] = $0
            if ($0 != "") { if (!first) first = n; last = n }
            if ($0 ~ /^- /) notes++
            next
        }
        { print }
        END {
            if (!done) { print "error: CHANGELOG.md has no Unreleased section above a build" > "/dev/stderr"; exit 1 }
            if (!notes) { print "error: there are no unreleased notes to release" > "/dev/stderr"; exit 1 }
        }
    ' "$changelog"
}

echo "Lagoon ${version} (${build}) -> ${next_version} (${next_build})"
echo

stamped="$(mktemp)"
trap 'rm -f "$stamped"' EXIT
stamp >"$stamped"

if [ "$mode" = --dry-run ]; then
    awk -v heading="## ${next_version} (${next_build})" \
        '$0 == heading { inside = 1 } inside && /^## / && $0 != heading { exit } inside' "$stamped"
    echo
    echo "(dry run, nothing was changed)"
    exit 0
fi

[ -z "$(git -C "$root" status --porcelain)" ] || die "the working tree is not clean"
cp "$stamped" "$changelog"
"$root/scripts/bump-build.sh" --set "$next_build" >/dev/null
perl -pi -e "s/MARKETING_VERSION = \Q${version}\E;/MARKETING_VERSION = ${next_version};/g" "$project"
grep -q "MARKETING_VERSION = ${next_version};" "$project" || die "could not set MARKETING_VERSION"

if [ "$mode" != --open-pr ]; then
    echo "Stamped ${next_version} (${next_build}). Review, then commit."
    exit 0
fi

branch="chore/release-${next_version//./-}"
subject="chore: release ${next_version} (${next_build})"
git -C "$root" switch --create "$branch"
git -C "$root" add "$changelog" "$project"
git -C "$root" commit --quiet --message "$subject"
git -C "$root" push --quiet --set-upstream origin "$branch"
gh pr create --base main --head "$branch" --title "$subject" \
    --body "$(printf 'Changes:\n- Release %s (%s)' "$next_version" "$next_build")"
