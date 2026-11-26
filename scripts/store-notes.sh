#!/usr/bin/env bash
#
# Sends a build's CHANGELOG.md entry to App Store Connect as plain text, so
# TestFlight and the store say what the app's own What's New says.
#
#   scripts/store-notes.sh 124 testflight            # What to Test, on the build
#   scripts/store-notes.sh 124 appstore              # What's New, on the store version
#   scripts/store-notes.sh 124 appstore --dry-run    # look and print, write nothing
#
# Both cover iOS and tvOS. testflight waits for Apple to finish processing the
# build. appstore creates the store version when there is none, and leaves one
# that is in review or on sale alone.
#
# A refusal from Apple is a warning, not a failure: the build has already gone
# out and the text can be pasted by hand.
#
# Needs the App Store Connect API key, exported or in .env, as
# scripts/upload-testflight.sh describes: ASC_KEY_ID, ASC_ISSUER_ID and
# ASC_KEY_PATH.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
changelog="$root/CHANGELOG.md"
bundle_id=ee.helop.lagoon
api=https://api.appstoreconnect.apple.com/v1
# Apple's limit for both fields.
limit=4000

usage() {
    echo "usage: $(basename "$0") <build> <testflight|appstore> [--dry-run]" >&2
    exit 2
}

build="${1:-}"
target="${2:-}"
[[ "$build" =~ ^[0-9]+$ ]] || usage
[[ "$target" =~ ^(testflight|appstore)$ ]] || usage
case "${3:-}" in
    "") dry_run=false ;;
    --dry-run) dry_run=true ;;
    *) usage ;;
esac

ok() { printf '  \xe2\x9c\x93 %s\n' "$1"; }
note() { printf '  - %s\n' "$1"; }
die() { printf '\n  error: %s\n' "$1" >&2; exit 1; }
warn() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "::warning title=Store notes::$1"
    else
        printf '  ! %s\n' "$1"
    fi
}

# 1. The build's entry, found by its build number. The heading gives the version.
entry="$(awk -v build="$build" '
    /^## / { inside = ($0 ~ ("^## [0-9.]+ \\(" build "\\)$")) }
    inside { print }' "$changelog")"
[[ -n "$entry" ]] || die "no CHANGELOG.md entry for build ${build}"
version="$(printf '%s\n' "$entry" | sed -n -E '1s/^## ([0-9.]+) .*/\1/p')"

# 2. As plain text, since neither field shows Markdown: the headline, then each
#    category with its lines. The month goes, as the store dates a version itself.
text="$(printf '%s\n' "$entry" \
    | sed -E '1d; /^[A-Z][a-z]+ [0-9]{4}$/d; s/^\*\*(.*)\*\*$/\1/; s/^### //; s/^- /• /' \
    | cat -s | sed -e '1{/^$/d;}')"

echo
echo "Notes for ${version} (${build}):"
echo
printf '%s\n' "$text" | sed 's/^/    /'
echo

# The run's summary keeps a copy to paste from, whatever Apple answers.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Notes for %s (%s)\n\n```\n%s\n```\n' "$version" "$build" "$text" >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "${#text}" -gt "$limit" ]]; then
    warn "The notes are ${#text} characters and Apple takes ${limit}, so nothing was sent. Paste a shorter text by hand."
    exit 0
fi

# The key from .env, when there is one. Exported values win.
if [[ -f "$root/.env" ]]; then
    while IFS='=' read -r name value || [[ -n "$name" ]]; do
        case "$name" in
            ASC_KEY_ID|ASC_ISSUER_ID|ASC_KEY_PATH)
                value="${value%\"}"
                [[ -n "${!name:-}" ]] || export "$name=${value#\"}" ;;
        esac
    done < "$root/.env"
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID (see the header of scripts/upload-testflight.sh)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
key="${ASC_KEY_PATH/#\~/$HOME}"
[[ -f "$key" ]] || die "no key at ${ASC_KEY_PATH}"

base64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# One request to Apple's API. Prints the answer, or warns with Apple's reason
# and fails. Each one signs its own token, as a token lasts minutes and the
# wait for a build can outlast it.
call() {
    local method="$1" path="$2" body="${3:-}" now header claims signature answer status
    path="${path//\[/%5B}"
    path="${path//\]/%5D}"
    now="$(date +%s)"
    header="$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID" | base64url)"
    claims="$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' "$ASC_ISSUER_ID" "$now" $((now + 600)) | base64url)"
    # openssl wraps the signature's two numbers in DER, and a JWT wants them bare, 32 bytes each.
    signature="$(printf '%s.%s' "$header" "$claims" \
        | openssl dgst -sha256 -sign "$key" \
        | openssl asn1parse -inform DER \
        | awk -F: '/INTEGER/ { v = $NF; while (length(v) < 64) v = "0" v; printf "%s", substr(v, length(v) - 63) }' \
        | perl -e 'print pack("H*", <STDIN>)' | base64url)"

    set -- -sS --max-time 60 --retry 2 -X "$method" -w '\n%{http_code}' \
        -H "Authorization: Bearer $header.$claims.$signature"
    [[ -n "$body" ]] && set -- "$@" -H 'Content-Type: application/json' --data "$body"
    if ! answer="$(curl "$@" "$api$path")"; then
        warn "Could not reach App Store Connect for ${method} ${path%%\?*}" >&2
        return 1
    fi
    status="${answer##*$'\n'}"
    answer="${answer%$'\n'*}"
    if [[ "$status" != 2* ]]; then
        warn "Apple answered ${status} to ${method} ${path%%\?*}: $(jq -r '[.errors[]?.detail] | join(" ")' <<< "$answer" 2>/dev/null || true)" >&2
        return 1
    fi
    printf '%s\n' "$answer"
}

# Writes the text to each localization in a list, unless it already says so.
# Prints how many the list had.
write_each() {
    local type="$1" where="$2" list="$3" id locale same count=0
    while IFS=$'\t' read -r id locale same; do
        count=$((count + 1))
        if [[ "$same" = true ]]; then
            ok "${where} (${locale}) already has it" >&2
        elif [[ "$dry_run" = true ]]; then
            note "would write ${where} (${locale})" >&2
        elif call PATCH "/${type}/${id}" "$(jq -n --arg type "$type" --arg id "$id" --arg text "$text" \
            '{data: {type: $type, id: $id, attributes: {whatsNew: $text}}}')" > /dev/null; then
            ok "${where} (${locale}) written" >&2
        fi
    done < <(jq -r --arg text "$text" \
        '.data[] | [.id, .attributes.locale, ((.attributes.whatsNew // "") == $text)] | @tsv' <<< "$list")
    echo "$count"
}

# What to Test belongs to the build, which exists only once Apple has
# processed the upload.
what_to_test() {
    local platform="$1" name="$2" found id state list
    while :; do
        found="$(call GET "/builds?filter[app]=${app_id}&filter[version]=${build}&filter[preReleaseVersion.platform]=${platform}&fields[builds]=processingState&limit=1")" || return 0
        id="$(jq -r '.data[0].id // empty' <<< "$found")"
        state="$(jq -r '.data[0].attributes.processingState // empty' <<< "$found")"
        case "$state" in
            VALID) break ;;
            FAILED|INVALID)
                warn "Apple marked the ${name} build ${state}, so it has no What to Test"
                return 0 ;;
        esac
        if [[ "$dry_run" = true ]] || [[ "$(date +%s)" -ge "$deadline" ]]; then
            warn "Apple has not finished processing the ${name} build, so its What to Test was not written. Paste it by hand, or run this again."
            return 0
        fi
        sleep 30
    done

    list="$(call GET "/builds/${id}/betaBuildLocalizations?fields[betaBuildLocalizations]=locale,whatsNew&limit=50")" || return 0
    [[ "$(write_each betaBuildLocalizations "${name} What to Test" "$list")" = 0 ]] || return 0
    if [[ "$dry_run" = true ]]; then
        note "would write ${name} What to Test (${locale})"
    elif call POST /betaBuildLocalizations "$(jq -n --arg locale "$locale" --arg text "$text" --arg id "$id" \
        '{data: {type: "betaBuildLocalizations", attributes: {locale: $locale, whatsNew: $text},
          relationships: {build: {data: {type: "builds", id: $id}}}}}')" > /dev/null; then
        ok "${name} What to Test (${locale}) written"
    fi
}

# What's New belongs to the store version, which is made here when it is
# missing, so the text is waiting when the build is selected and submitted.
whats_new() {
    local platform="$1" name="$2" found id state list
    found="$(call GET "/apps/${app_id}/appStoreVersions?filter[platform]=${platform}&filter[versionString]=${version}&fields[appStoreVersions]=appVersionState&limit=1")" || return 0
    id="$(jq -r '.data[0].id // empty' <<< "$found")"
    state="$(jq -r '.data[0].attributes.appVersionState // empty' <<< "$found")"
    if [[ -z "$id" ]]; then
        if [[ "$dry_run" = true ]]; then
            note "would create the ${name} version ${version} and write its What's New"
            return 0
        fi
        found="$(call POST /appStoreVersions "$(jq -n --arg platform "$platform" --arg version "$version" --arg app "$app_id" \
            '{data: {type: "appStoreVersions", attributes: {platform: $platform, versionString: $version},
              relationships: {app: {data: {type: "apps", id: $app}}}}}')")" || return 0
        id="$(jq -r '.data.id' <<< "$found")"
        state="$(jq -r '.data.attributes.appVersionState // empty' <<< "$found")"
        ok "${name} version ${version} created"
    fi

    # Text sent to a version in review or on sale would be refused, or worse, kept.
    case "$state" in
        ""|PREPARE_FOR_SUBMISSION|DEVELOPER_REJECTED|REJECTED|METADATA_REJECTED|INVALID_BINARY) ;;
        *)
            note "the ${name} version ${version} is ${state}, so its text is left alone"
            return 0 ;;
    esac

    list="$(call GET "/appStoreVersions/${id}/appStoreVersionLocalizations?fields[appStoreVersionLocalizations]=locale,whatsNew&limit=50")" || return 0
    [[ "$(write_each appStoreVersionLocalizations "${name} What's New" "$list")" != 0 ]] \
        || warn "The ${name} version ${version} has no language to write What's New in"
}

apps="$(call GET "/apps?filter[bundleId]=${bundle_id}&fields[apps]=bundleId,primaryLocale")" || exit 0
app_id="$(jq -r --arg bundle "$bundle_id" '[.data[] | select(.attributes.bundleId == $bundle)][0].id // empty' <<< "$apps")"
locale="$(jq -r --arg bundle "$bundle_id" '[.data[] | select(.attributes.bundleId == $bundle)][0].attributes.primaryLocale // "en-US"' <<< "$apps")"
if [[ -z "$app_id" ]]; then
    warn "App Store Connect lists no app with the bundle id ${bundle_id}"
    exit 0
fi

deadline=$(($(date +%s) + 1800))
for platform in IOS TV_OS; do
    case "$platform" in IOS) name=iOS ;; *) name=tvOS ;; esac
    if [[ "$target" = testflight ]]; then
        what_to_test "$platform" "$name"
    else
        whats_new "$platform" "$name"
    fi
done

[[ "$dry_run" = false ]] || { echo; echo "  (dry run, nothing was written)"; }
