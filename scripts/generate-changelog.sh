#!/usr/bin/env bash
#
# Regenerates CHANGELOG.md from Changelog.entries.
#
# The in-app changelog is the source of truth and this file is a rendering of
# it. They serve different readers, which is why the data does not simply move
# here: the About screen is curated product copy, and ChangelogTests gates
# that the declared build has an entry, enforces category order and bans em
# dashes. None of that survives in a Markdown file nobody parses, and parsing
# Swift source to render a settings screen would be worse.
#
# The renderer lives in the test target because that is the only place with
# access to Changelog, and a simulator test cannot write into the repository,
# so it writes to its own tmp and prints the path for us to copy.
#
#   scripts/generate-changelog.sh             # regenerate the document
#   scripts/generate-changelog.sh --check     # fail if it is out of date
#   scripts/generate-changelog.sh --notes 107 # print one build's notes
#
# --notes prints to stdout for pasting into a GitHub release, and defaults to
# the newest build when no number is given.
#
# Override the simulator with LAGOON_CHANGELOG_DOC_DESTINATION.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/CHANGELOG.md"
destination="${LAGOON_CHANGELOG_DOC_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"

check=false
notes=false
build=""
case "${1:-}" in
    --check) check=true ;;
    --notes) notes=true; build="${2:-}" ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--check | --notes [build]]" >&2; exit 2 ;;
esac

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

if [ "$notes" = true ]; then
    # Build headings are the only level-two headings, which a test pins, so
    # splitting on them cannot catch a category by accident. Trims the blank
    # lines off both ends, because this is pasted into a release body.
    body="$(awk -v want="$build" '
        /^## / {
            inside = (want == "" && !seen) || index($0, "(" want ")") > 0
            if (inside) seen = 1
            next
        }
        inside { print }
    ' "$generated" | awk '{ lines[NR] = $0 }
        END { first = 1; while (first <= NR && lines[first] == "") first++
              last = NR; while (last >= first && lines[last] == "") last--
              for (i = first; i <= last; i++) print lines[i] }')"

    # An unknown build would otherwise print nothing and succeed, which is a
    # silent empty release body rather than a mistake somebody notices.
    if [ -z "$body" ]; then
        echo "error: no changelog entry for build ${build:-(newest)}" >&2
        exit 1
    fi
    printf '%s\n' "$body"
    exit 0
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
