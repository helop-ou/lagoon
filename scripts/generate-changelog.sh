#!/usr/bin/env bash
#
# Regenerates CHANGELOG.md from Changelog.entries, the source of truth.
#
# The renderer is a test (ChangelogDocTests), the only place with access to
# Changelog. It writes to its own tmp and prints the path; this copies it.
#
#   scripts/generate-changelog.sh             # regenerate the document
#   scripts/generate-changelog.sh --check     # fail if it is out of date
#   scripts/generate-changelog.sh --notes 107 # print one build's notes
#
# --notes reads the committed CHANGELOG.md, so it needs no simulator. Run
# --check first to trust it. It defaults to the newest build.
#
# Override the simulator with LAGOON_CHANGELOG_DOC_DESTINATION.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/CHANGELOG.md"
destination="${LAGOON_CHANGELOG_DOC_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=latest}"

check=false
notes=false
build=""
case "${1:-}" in
    --check) check=true ;;
    --notes) notes=true; build="${2:-}" ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--check | --notes [build]]" >&2; exit 2 ;;
esac

if [ "$notes" = true ]; then
    [ -f "$target" ] || { echo "error: $target does not exist yet" >&2; exit 1; }
    # Build headings are the only level-two headings (a test pins this).
    # Blank lines are trimmed off both ends for the release body.
    body="$(awk -v want="$build" '
        /^## / {
            inside = (want == "" && !seen) || index($0, "(" want ")") > 0
            if (inside) seen = 1
            next
        }
        inside { print }
    ' "$target" | awk '{ lines[NR] = $0 }
        END { first = 1; while (first <= NR && lines[first] == "") first++
              last = NR; while (last >= first && lines[last] == "") last--
              for (i = first; i <= last; i++) print lines[i] }')"

    # Otherwise an unknown build gives a silent empty release body.
    if [ -z "$body" ]; then
        echo "error: no changelog entry for build ${build:-(newest)}" >&2
        exit 1
    fi
    printf '%s\n' "$body"
    exit 0
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! xcodebuild test \
    -scheme Lagoon \
    -destination "$destination" \
    -only-testing:LagoonTests/ChangelogDocTests \
    >"$log" 2>&1; then
    echo "error: the generator test failed" >&2
    tail -40 "$log" >&2
    exit 1
fi

generated="$(grep -o 'CHANGELOG_DOC .*' "$log" | head -1 | cut -d' ' -f2-)"
if [ -z "$generated" ] || [ ! -f "$generated" ]; then
    echo "error: the generator did not report an output file" >&2
    exit 1
fi

if [ "$check" = true ]; then
    if diff -u "$target" "$generated"; then
        echo "CHANGELOG.md is current"
    else
        echo >&2
        echo "error: CHANGELOG.md is out of date. Run scripts/generate-changelog.sh" >&2
        exit 1
    fi
else
    cp "$generated" "$target"
    echo "wrote CHANGELOG.md ($(wc -l < "$target" | tr -d ' ') lines)"
fi
