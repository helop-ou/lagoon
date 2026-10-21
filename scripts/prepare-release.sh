#!/usr/bin/env bash
#
# Opens the next release: the unreleased notes become a new Changelog entry,
# the build number and marketing version advance, and CHANGELOG.md is
# regenerated. The release workflow's prepare action runs it with --open-pr.
#
#   scripts/prepare-release.sh patch "Up Next shows how long is left."
#   scripts/prepare-release.sh minor "…" --dry-run   # print the entry only
#   scripts/prepare-release.sh minor "…" --open-pr   # commit, push, open the PR
#
# The headline is the one line About and the GitHub release lead with.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/Lagoon.xcodeproj/project.pbxproj"
changelog="$root/Lagoon/Features/Settings/Changelog.swift"

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

# Moves the unreleased sections into a new top entry and empties them.
stamp() {
    python3 -I - "$changelog" "$next_version" "$next_build" "$released" "$headline" "$1" <<'PYTHON'
import sys

path, version, build, released, headline, write = sys.argv[1:7]
lines = open(path, encoding="utf-8").read().split("\n")

opening = "    static let unreleased: [ChangelogSection] = ["
start = next((i for i, line in enumerate(lines) if line.startswith(opening)), None)
if start is None:
    sys.exit("error: Changelog.unreleased not found")
if lines[start] == opening + "]":
    sys.exit("error: there are no unreleased notes to release")
end = lines.index("    ]", start)
body = [("        " + line) if line else line for line in lines[start + 1:end]]

escaped = headline.replace("\\", "\\\\").replace('"', '\\"')
entry = [
    "        ChangelogEntry(",
    f'            version: "{version}",',
    f'            build: "{build}",',
    f'            released: "{released}",',
    f'            headline: "{escaped}",',
    "            sections: [",
    *body,
    "            ]",
    "        ),",
]

lines[start:end + 1] = [opening + "]"]
anchor = lines.index("    static let entries: [ChangelogEntry] = [")
lines[anchor + 1:anchor + 1] = entry

if write == "write":
    open(path, "w", encoding="utf-8").write("\n".join(lines))
else:
    print("\n".join(entry))
PYTHON
}

echo "Lagoon ${version} (${build}) -> ${next_version} (${next_build})"
echo

if [ "$mode" = --dry-run ]; then
    stamp print
    echo
    echo "(dry run, nothing was changed)"
    exit 0
fi

[ -z "$(git -C "$root" status --porcelain)" ] || die "the working tree is not clean"
stamp write
"$root/scripts/bump-build.sh" --set "$next_build" >/dev/null
sed -i '' "s/MARKETING_VERSION = ${version};/MARKETING_VERSION = ${next_version};/g" "$project"
grep -q "MARKETING_VERSION = ${next_version};" "$project" || die "could not set MARKETING_VERSION"
"$root/scripts/generate-changelog.sh"

if [ "$mode" != --open-pr ]; then
    echo "Stamped ${next_version} (${next_build}). Review, then commit."
    exit 0
fi

branch="chore/release-${next_version//./-}"
subject="chore: release ${next_version} (${next_build})"
git -C "$root" switch --create "$branch"
git -C "$root" add "$changelog" "$project" "$root/CHANGELOG.md"
git -C "$root" commit --quiet --message "$subject"
git -C "$root" push --quiet --set-upstream origin "$branch"
gh pr create --base main --head "$branch" --title "$subject" \
    --body "$(printf 'Changes:\n- Release %s (%s)' "$next_version" "$next_build")"
