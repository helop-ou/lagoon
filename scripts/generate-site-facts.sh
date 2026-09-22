#!/usr/bin/env bash
#
# Regenerates the website's app-facts.json from this repository.
#
# Generated from DeviceProfile and the declared version, so the site cannot
# claim a codec the app never offers or name a build nobody shipped
# (docs/release.md forbids overstating format support). The Jellyfin versions,
# availability and prose stay hand-written in the site.
#
#   scripts/generate-site-facts.sh           # regenerate the file
#   scripts/generate-site-facts.sh --check   # fail if it is out of date
#
# The website is expected beside this checkout. Override with
# LAGOON_WEBSITE_PATH, and the simulator with LAGOON_SITE_FACTS_DESTINATION.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
website="${LAGOON_WEBSITE_PATH:-$repo/../lagoon-website}"
target="$website/src/lib/content/app-facts.json"
destination="${LAGOON_SITE_FACTS_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=latest}"

check=false
[ "${1:-}" = "--check" ] && check=true

[ -d "$website" ] || {
    echo "error: no website checkout at $website" >&2
    echo "Set LAGOON_WEBSITE_PATH if it lives somewhere else." >&2
    exit 1
}
[ -d "$(dirname "$target")" ] || {
    echo "error: $(dirname "$target") does not exist" >&2
    exit 1
}

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! xcodebuild test \
    -scheme Lagoon \
    -destination "$destination" \
    -only-testing:LagoonTests/SiteFactsDocTests \
    >"$log" 2>&1; then
    echo "error: the generator test failed" >&2
    tail -40 "$log" >&2
    exit 1
fi

generated="$(grep -o 'SITE_FACTS_DOC .*' "$log" | head -1 | cut -d' ' -f2-)"
if [ -z "$generated" ] || [ ! -f "$generated" ]; then
    echo "error: the generator did not report an output file" >&2
    exit 1
fi

if [ "$check" = true ]; then
    if [ ! -f "$target" ]; then
        echo "error: $target does not exist. Run scripts/generate-site-facts.sh" >&2
        exit 1
    fi
    if diff -u "$target" "$generated"; then
        echo "app-facts.json is current"
    else
        echo >&2
        echo "error: the website's app-facts.json is out of date." >&2
        echo "Run scripts/generate-site-facts.sh and commit it in the website repository." >&2
        exit 1
    fi
else
    cp "$generated" "$target"
    echo "wrote $target"
    echo
    echo "Commit it in the website repository; this checkout does not own that file."
fi
