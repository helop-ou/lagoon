#!/usr/bin/env bash
#
# Regenerates docs/codec-support.md from DeviceProfile.everything.
#
# Generated so the table matches the profile Lagoon sends Jellyfin
# (docs/release.md forbids overstating supported formats). The renderer is a
# test (CodecSupportDocTests); it writes to its own tmp and prints the path,
# and this copies it.
#
#   scripts/generate-codec-support.sh           # regenerate the document
#   scripts/generate-codec-support.sh --check   # fail if it is out of date
#
# Override the simulator with LAGOON_CODEC_DOC_DESTINATION.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$repo/docs/codec-support.md"
destination="${LAGOON_CODEC_DOC_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=latest}"

check=false
[ "${1:-}" = "--check" ] && check=true

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! xcodebuild test \
    -scheme Lagoon \
    -destination "$destination" \
    -only-testing:LagoonTests/CodecSupportDocTests \
    >"$log" 2>&1; then
    echo "error: the generator test failed" >&2
    tail -40 "$log" >&2
    exit 1
fi

generated="$(grep -o 'CODEC_SUPPORT_DOC .*' "$log" | head -1 | cut -d' ' -f2-)"
if [ -z "$generated" ] || [ ! -f "$generated" ]; then
    echo "error: the generator did not report an output file" >&2
    exit 1
fi

if [ "$check" = true ]; then
    if diff -u "$target" "$generated"; then
        echo "docs/codec-support.md is current"
    else
        echo >&2
        echo "error: docs/codec-support.md is out of date. Run scripts/generate-codec-support.sh" >&2
        exit 1
    fi
else
    cp "$generated" "$target"
    echo "wrote docs/codec-support.md ($(wc -l < "$target" | tr -d ' ') lines)"
fi
