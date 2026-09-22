#!/usr/bin/env bash
#
# Creates the GitHub release for a build that has already gone out.
#
# Run it last, after the build is uploaded and accepted. The release (not just
# a tag) is what carries GitHub's source archive, which is how someone with a
# binary gets the corresponding source for the vendored FFmpeg libraries.
#
#   scripts/publish-release.sh 108              # tags 0.2.0-108
#   scripts/publish-release.sh 108 --dry-run    # print what it would do
#   scripts/publish-release.sh 108 --rev a1b2c3d
#
# --rev tags a revision other than HEAD: use the one the archive was built from.
# --no-prerelease marks a full release. Otherwise anything below 1.0 is a
# pre-release.
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

ok() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
warn() { printf '  ! %s\n' "$1"; }
note() { printf '  - %s\n' "$1"; }
die() { printf '\n  error: %s\n' "$1" >&2; exit 1; }

# Tags read <version>-<build>. The build number keeps them unique.
version="$(grep -m1 -o 'MARKETING_VERSION = [0-9.]*' "$project" | grep -o '[0-9.]*$')"
tag="${version}-${want_build}"

echo
echo "Publishing ${tag}"
echo

# 1. Tooling, before anything slow.
command -v gh >/dev/null 2>&1 || die "gh is not installed"
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh is not authenticated for github.com. Run: gh auth login"
slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || die "this checkout has no GitHub remote gh can resolve"
ok "gh authenticated for ${slug}"

# 2. A dirty tree means the revision being tagged is not what was built.
[ -z "$(git -C "$root" status --porcelain)" ] || die "working tree is not clean"
ok "working tree clean"

# 3. The build must be the one the project declares, or the tag names a binary
#    nobody built.
values="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$' | sort -u)"
[ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = "1" ] \
    || die "CURRENT_PROJECT_VERSION differs across configurations: $(echo $values)"
[ "$values" = "$want_build" ] \
    || die "the project declares build ${values}, not ${want_build}"
ok "project declares ${version} (${want_build})"

# 4. Same rule as the upload script and ChangelogTests; last chance before public.
grep -A 2 "version: \"${version}\"" "$changelog" | grep -q "build: \"${want_build}\"" \
    || die "no Changelog entry for ${version} (${want_build})"
ok "changelog entry exists for ${version} (${want_build})"

# 5. The release body comes from CHANGELOG.md, so it must match Changelog.swift.
"$root/scripts/generate-changelog.sh" --check >/dev/null \
    || die "CHANGELOG.md is out of date. Run scripts/generate-changelog.sh"
ok "CHANGELOG.md is current"

notes="$("$root/scripts/generate-changelog.sh" --notes "$want_build")" \
    || die "could not read the notes for build ${want_build}"
ok "release notes read for build ${want_build}"

# 6. A re-tag cannot be undone: anyone who fetched keeps the old revision.
if git -C "$root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "${tag} already exists locally"
fi
if [ -n "$(git -C "$root" ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null)" ]; then
    die "${tag} already exists on the remote"
fi
ok "${tag} is unused"

# 7. gh creates the tag through the API, so the remote must have the revision.
sha="$(git -C "$root" rev-parse --verify "${rev}^{commit}")" \
    || die "cannot resolve revision ${rev}"
git -C "$root" fetch --quiet origin || die "could not reach origin"
if ! git -C "$root" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
    die "${rev} (${sha:0:9}) is not on origin/main yet. Push before releasing."
fi
ok "${sha:0:9} is on origin/main"

# 8. The website (a separate repository) restates the version and formats.
#    Warn, do not stop, if it is behind. Never report a check that could not
#    run as passing.
site_out=""
site_status=0
site_out="$("$root/scripts/generate-site-facts.sh" --check 2>&1)" || site_status=$?
if [ "$site_status" -eq 0 ]; then
    ok "the website's facts are current"
elif printf '%s' "$site_out" | grep -q "no website checkout"; then
    note "no website checkout beside this one, so its facts were not checked"
elif printf '%s' "$site_out" | grep -q "out of date\|does not exist"; then
    warn "the website's facts are behind this build"
    echo "      Run scripts/generate-site-facts.sh, then commit and deploy"
    echo "      lagoon-website. The site keeps serving the old version until"
    echo "      it is redeployed. Releasing anyway."
else
    # Not the raw output: a missing simulator prints every destination.
    warn "could not check the website's facts, so they may be behind"
    echo "      Run scripts/generate-site-facts.sh --check to see why."
fi

# 9. The archived revision is not recorded, so show the commits since the
#    build-number bump and let a human confirm.
bump="$(git -C "$root" log --format=%H -S"CURRENT_PROJECT_VERSION = ${want_build};" \
    --pickaxe-regex -1 -- Lagoon.xcodeproj/project.pbxproj 2>/dev/null || true)"
if [ -n "$bump" ] && [ "$bump" != "$sha" ]; then
    ahead="$(git -C "$root" rev-list --count "${bump}..${sha}" 2>/dev/null || echo "?")"
    echo
    echo "  ! ${sha:0:9} is ${ahead} commit(s) past the build ${want_build} bump (${bump:0:9}):"
    git -C "$root" log --oneline -10 "${bump}..${sha}" | sed 's/^/      /'
    [ "$ahead" -gt 10 ] 2>/dev/null && echo "      ... and $((ahead - 10)) more"
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

# The pre-release badge keeps it from being served as Latest.
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
