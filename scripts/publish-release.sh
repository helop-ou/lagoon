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
# Without --rev it tags the revision recorded when the build was archived:
# build/archived-<build>.sha from scripts/upload-testflight.sh, or the
# refs/archived/<build> ref the release workflow pushes. HEAD if neither.
# --no-prerelease marks a full release. Otherwise anything below 1.0 is a
# pre-release.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

want_build="${1:-}"
[[ "$want_build" =~ ^[0-9]+$ ]] || {
    echo "usage: $(basename "$0") <build> [--dry-run] [--rev <sha>] [--no-prerelease]" >&2
    exit 2
}
shift

dry_run=false
rev=""
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

record="$root/build/archived-${want_build}.sha"
recorded=false
if [ -z "$rev" ] && [ -f "$record" ]; then
    rev="$(cat "$record")"
    recorded=true
elif [ -z "$rev" ]; then
    remote_record="$(git -C "$root" ls-remote origin "refs/archived/${want_build}" 2>/dev/null | cut -f1)"
    if [ -n "$remote_record" ]; then
        git -C "$root" fetch --quiet origin "refs/archived/${want_build}" || die "could not fetch refs/archived/${want_build}"
        rev="$remote_record"
        recorded=true
    fi
fi
rev="${rev:-HEAD}"
sha="$(git -C "$root" rev-parse --verify "${rev}^{commit}" 2>/dev/null)" \
    || die "cannot resolve revision ${rev}"

# Read from the revision being tagged, not the working tree, so an earlier
# build can still be published after the project has moved on.
project_text="$(git -C "$root" show "${sha}:Lagoon.xcodeproj/project.pbxproj")" \
    || die "cannot read the project at ${sha:0:9}"

changelog_text="$(git -C "$root" show "${sha}:CHANGELOG.md")" \
    || die "cannot read CHANGELOG.md at ${sha:0:9}"

# Tags read <version>-<build>. The build number keeps them unique.
version="$(printf '%s\n' "$project_text" | grep -m1 -o 'MARKETING_VERSION = [0-9.]*' | grep -o '[0-9.]*$')"
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
values="$(printf '%s\n' "$project_text" | grep -o 'CURRENT_PROJECT_VERSION = [0-9]*' | grep -o '[0-9]*$' | sort -u)"
[ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = "1" ] \
    || die "CURRENT_PROJECT_VERSION differs across configurations: $(echo $values)"
[ "$values" = "$want_build" ] \
    || die "${sha:0:9} declares build ${values}, not ${want_build}"
ok "${sha:0:9} declares ${version} (${want_build})"
[ "$recorded" = true ] && ok "tagging the revision recorded when build ${want_build} was archived"

# 4. Same rule as the upload script and ChangelogTests. Last chance before public.
#    The body is the build's section, trimmed of blank lines at both ends.
notes="$(printf '%s\n' "$changelog_text" | awk -v heading="## ${version} (${want_build})" '
    /^## / { inside = ($0 == heading); next }
    inside { lines[++n] = $0 }
    END {
        first = 1; while (first <= n && lines[first] == "") first++
        last = n; while (last >= first && lines[last] == "") last--
        for (i = first; i <= last; i++) print lines[i]
    }')"
[ -n "$notes" ] || die "no CHANGELOG.md entry for ${version} (${want_build})"
ok "release notes read for ${version} (${want_build})"

# 5. A re-tag cannot be undone: anyone who fetched keeps the old revision.
if git -C "$root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    die "${tag} already exists locally"
fi
if [ -n "$(git -C "$root" ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null)" ]; then
    die "${tag} already exists on the remote"
fi
ok "${tag} is unused"

# 6. gh creates the tag through the API, so the remote must have the revision.
git -C "$root" fetch --quiet origin || die "could not reach origin"
if ! git -C "$root" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
    die "${rev} (${sha:0:9}) is not on origin/main yet. Push before releasing."
fi
ok "${sha:0:9} is on origin/main"

# 7. The archived revision is not recorded, so show the commits since the
#    build-number bump and let a human confirm.
# The oldest match: the newest is the next bump, which removed the number.
bump="$(git -C "$root" log --format=%H -S"CURRENT_PROJECT_VERSION = ${want_build};" \
    --pickaxe-regex -- Lagoon.xcodeproj/project.pbxproj 2>/dev/null | tail -1 || true)"
if [ "$recorded" = false ] && [ -n "$bump" ] && [ "$bump" != "$sha" ]; then
    ahead="$(git -C "$root" rev-list --count "${bump}..${sha}" 2>/dev/null || echo "?")"
    echo
    echo "  ! ${sha:0:9} is ${ahead} commit(s) past the build ${want_build} bump (${bump:0:9}):"
    git -C "$root" log --oneline -10 "${bump}..${sha}" | sed 's/^/      /'
    [ "$ahead" -gt 10 ] 2>/dev/null && echo "      ... and $((ahead - 10)) more"
    echo
    echo "    Tag the revision the archive was actually built from. Pass --rev"
    echo "    if that is not ${sha:0:9}."
    if [ "$dry_run" = false ]; then
        [ -t 0 ] || die "this needs a yes from a terminal. Run it in one, not through a pipe or an agent."
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
