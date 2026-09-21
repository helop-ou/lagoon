#!/usr/bin/env bash
#
# Creates the GitHub release for a build that has already gone out.
#
# This is the last step of a release, not the first. It runs after the build is
# uploaded and accepted, and it records a binary that exists rather than
# announcing one about to be made. A tag on its own only reaches the Tags tab;
# the release object is what appears under Releases, and GitHub attaches the
# source archive to it, which is how someone holding a binary obtains the
# corresponding source for the vendored FFmpeg libraries.
#
#   scripts/publish-release.sh 108
#   scripts/publish-release.sh 108 --dry-run    # print what it would do
#   scripts/publish-release.sh 108 --rev a1b2c3d
#
# Everything before the release itself is a guard, because the mistakes here
# are silent and permanent: a tag on whatever main has drifted to rather than
# the revision that was archived, notes that do not match the build, or a
# release nobody notices is missing. A published tag is hard to take back.
#
# --no-prerelease marks it as a full release. Otherwise anything below 1.0 is
# a pre-release, which is what external testing is.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$root/Lagoon.xcodeproj/project.pbxproj"
changelog="$root/Lagoon/Features/Settings/Changelog.swift"

want_build="${1:-}"
[[ "$want_build" =~ ^[0-9]+$ ]] || {
    echo "usage: $(basename "$0") <build> [--dry-run] [--rev <sha>] [--no-prerelease]" >&2
    exit 2
}
shift

dry_run=false
rev="HEAD"
prerelease=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --rev) rev="${2:?--rev needs a revision}"; shift ;;
        --no-prerelease) prerelease="no" ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

tag="build-${want_build}"
ok() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
die() { printf '\n  error: %s\n' "$1" >&2; exit 1; }

echo
echo "Publishing ${tag}"
echo

# 1. The tooling, before anything slow runs.
command -v gh >/dev/null 2>&1 || die "gh is not installed"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh is not authenticated for github.com. Run: gh auth login"
slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || die "this checkout has no GitHub remote gh can resolve"
ok "gh authenticated for ${slug}"

# 2. A dirty tree means the revision being tagged is not what was built.
[ -z "$(git -C "$root" status --porcelain)" ] || die "working tree is not clean"
ok "working tree clean"

# 3. The build number has to be the one the project declares, or the tag names
#    a binary nobody built. bump-build.sh guarantees one value across
#    configurations; this catches being asked for a different build entirely.
values="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$' | sort -u)"
[ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = "1" ] \
    || die "CURRENT_PROJECT_VERSION differs across configurations: $(echo $values)"
[ "$values" = "$want_build" ] \
    || die "the project declares build ${values}, not ${want_build}"
version="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$project" | grep -o '[0-9.]*$')"
ok "project declares ${version} (${want_build})"

# 4. Same rule the upload script and ChangelogTests enforce, restated here
#    because this is the last chance to catch it before it is public.
grep -A 2 "version: \"${version}\"" "$changelog" | grep -q "build: \"${want_build}\"" \
    || die "no Changelog entry for ${version} (${want_build})"
ok "changelog entry exists for ${version} (${want_build})"

# 5. The release body is read straight out of CHANGELOG.md, so it is only
#    trustworthy if that file still matches Changelog.swift.
"$root/scripts/generate-changelog.sh" --check >/dev/null \
    || die "CHANGELOG.md is out of date. Run scripts/generate-changelog.sh"
ok "CHANGELOG.md is current"

notes="$("$root/scripts/generate-changelog.sh" --notes "$want_build")" \
    || die "could not read the notes for build ${want_build}"
ok "release notes read for build ${want_build}"

# 6. Re-tagging a published release is the one thing that cannot be undone
#    cleanly, because anyone who already fetched keeps the old revision.
if git -C "$root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "${tag} already exists locally"
fi
if [ -n "$(git -C "$root" ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null)" ]; then
    die "${tag} already exists on the remote"
fi
ok "${tag} is unused"

# 7. gh creates the tag through the API, so the revision has to be one the
#    remote already has. This is the guard that catches an unpushed main.
sha="$(git -C "$root" rev-parse --verify "${rev}^{commit}")" \
    || die "cannot resolve revision ${rev}"
git -C "$root" fetch --quiet origin || die "could not reach origin"
if ! git -C "$root" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
    die "${rev} (${sha:0:9}) is not on origin/main yet. Push before releasing."
fi
ok "${sha:0:9} is on origin/main"

# 8. Which revision was archived is not recorded anywhere, so the best we can
#    do is point at the commit that set this build number and let a human say
#    whether the archive came from further along.
bump="$(git -C "$root" log --format=%H -S"CURRENT_PROJECT_VERSION = ${want_build};" \
    --pickaxe-regex -1 -- Lagoon.xcodeproj/project.pbxproj 2>/dev/null || true)"
if [ -n "$bump" ] && [ "$bump" != "$sha" ]; then
    ahead="$(git -C "$root" rev-list --count "${bump}..${sha}" 2>/dev/null || echo "?")"
    echo
    echo "  ! ${sha:0:9} is ${ahead} commit(s) past the build ${want_build} bump (${bump:0:9}):"
    git -C "$root" log --oneline "${bump}..${sha}" | sed 's/^/      /'
    echo
    echo "    Tag the revision the archive was actually built from. Pass --rev"
    echo "    if that is not ${sha:0:9}."
    if [ "$dry_run" = false ]; then
        [ -t 0 ] || die "cannot confirm without a terminal. Pass --rev explicitly."
        printf "    Tag %s anyway? [y/N] " "${sha:0:9}"
        read -r reply
        case "$reply" in [yY]*) ;; *) die "stopped" ;; esac
    fi
fi

# Anything below 1.0 is a pre-release. External testing is exactly that, and
# the badge keeps it from being served as Latest.
if [ -z "$prerelease" ]; then
    case "$version" in 0.*) prerelease="yes" ;; *) prerelease="no" ;; esac
fi

set -- gh release create "$tag" --repo "$slug" --target "$sha" \
    --title "${version} (${want_build})" --notes-file -
[ "$prerelease" = "yes" ] && set -- "$@" --prerelease

echo
if [ "$dry_run" = true ]; then
    echo "  would run: $*"
    echo
    echo "  with this body:"
    printf '%s\n' "$notes" | sed 's/^/      /'
    echo
    echo "  (dry run, nothing was tagged or published)"
    exit 0
fi

printf '%s\n' "$notes" | "$@"
echo
echo "  Fetch the tag it created: git fetch --tags origin"
