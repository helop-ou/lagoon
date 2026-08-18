#!/bin/bash
# Frame-loss bench harness (HEL-64).
#
# Runs the in-app frame-loss bench (Settings → Debug → Frame-Loss Bench)
# against one item at one seeded position, N times, in the tvOS simulator —
# and prints the per-run results plus a summary. This encodes the
# measurement discipline that caught two false positives on HEL-64:
#
#   * same title, same seeded position, same media-time window every run;
#   * the simulator is left completely untouched during a window
#     (screenshots force render captures and corrupt the numbers);
#   * 3+ runs, because single runs are meaningless at this effect size.
#
# The app side does the measuring (10 s warmup + 60 s window keyed on
# media time, result as a "Bench Result" signpost + HUD line); this script
# just seeds, launches, waits, and reads the signpost back out of the
# unified log. A/B experiments toggle app defaults between runs with
# --set, e.g.:
#
#   scripts/framedrop-bench.sh --item <id> --position 300 --runs 3 \
#       --server https://fixture.example.eu --user Development \
#       --set debug.stripDoviEL=true
#
# The password is prompted for (or taken from LAGOON_BENCH_PASS) so it
# never lands in the repo or shell history. The app must already be
# installed on the target simulator and signed into the same server.
# Real-hardware runs can't be scripted this way — there, read the same
# result from the HUD's Bench line after leaving the scene untouched.

set -euo pipefail

BUNDLE_ID="ee.helop.lagoon"
SUBSYSTEM="ee.helop.lagoon"

item=""
position=300
runs=3
udid="booted"
server="${LAGOON_BENCH_SERVER:-https://fixture.example.eu}"
user="${LAGOON_BENCH_USER:-Development}"
pass="${LAGOON_BENCH_PASS:-}"
warmup=10
window=60
slack=35
declare -a sets=()

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --item) item="$2"; shift 2 ;;
        --position) position="$2"; shift 2 ;;
        --runs) runs="$2"; shift 2 ;;
        --udid) udid="$2"; shift 2 ;;
        --server) server="$2"; shift 2 ;;
        --user) user="$2"; shift 2 ;;
        --set) sets+=("$2"); shift 2 ;;
        --window) window="$2"; shift 2 ;;   # informational: the app owns the window
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "$item" ]] || { echo "--item <jellyfin item id> is required" >&2; usage; }
if [[ -z "$pass" ]]; then
    read -r -s -p "Password for $user on $server: " pass; echo
fi

# --- authenticate -----------------------------------------------------------
auth=$(curl -sf -X POST "$server/Users/AuthenticateByName" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="LagoonBench", Device="CLI", DeviceId="lagoon-bench", Version="1.0"' \
    -d "{\"Username\":\"$user\",\"Pw\":\"$pass\"}")
token=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessToken"])' <<<"$auth")
userid=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["User"]["Id"])' <<<"$auth")
echo "authenticated as $user"

# --- apply A/B defaults -----------------------------------------------------
# The bench itself and the HUD are always forced on: without them there is
# no result to read.
xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.playbackHUD -bool true >/dev/null
xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.frameLossBench -bool true >/dev/null
for kv in "${sets[@]:-}"; do
    [[ -n "$kv" ]] || continue
    key="${kv%%=*}"; value="${kv#*=}"
    xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" "$key" -bool "$value" >/dev/null
    echo "default $key = $value"
done

# --- runs -------------------------------------------------------------------
ticks=$(python3 -c "print(int($position * 10_000_000))")
wait_seconds=$((warmup + window + slack))
results=()

press_menu() {
    osascript -e 'tell application "Simulator" to activate' \
              -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
}

for run in $(seq 1 "$runs"); do
    # Seed the resume point server-side; the deep link resumes from it.
    curl -sf -X POST "$server/UserItems/$item/UserData" \
        -H 'Content-Type: application/json' \
        -H "Authorization: MediaBrowser Token=\"$token\"" \
        -d "{\"PlaybackPositionTicks\":$ticks,\"Played\":false}" >/dev/null
    start_iso=$(date '+%Y-%m-%d %H:%M:%S')
    xcrun simctl openurl "$udid" "lagoon://play/$item"
    echo "run $run/$runs: playing item at ${position}s — hands off the simulator for ${wait_seconds}s"
    sleep "$wait_seconds"

    # The simulator keeps its own log store — the host's `log show` never
    # sees these signposts.
    line=$(xcrun simctl spawn "$udid" log show --last "$((wait_seconds + 30))s" --signpost \
        --predicate "subsystem == \"$SUBSYSTEM\" AND category == \"PlaybackPerformance\"" 2>/dev/null \
        | grep "Bench Result" \
        | awk -v start="$start_iso" 'substr($0, 1, 19) >= start' \
        | tail -1 || true)
    if [[ -n "$line" ]]; then
        summary=$(sed -E 's/.*(dropped=[^"]*)/\1/' <<<"$line")
        echo "  → $summary"
        results+=("$summary")
    else
        echo "  → NO RESULT — playback failed, or the window did not finish untouched" >&2
    fi
    press_menu   # leave the player so the next run re-enters at the new seed
    sleep 3
done

# --- summary ----------------------------------------------------------------
echo
echo "=== ${#results[@]}/$runs runs completed — item $item @ ${position}s ==="
for r in "${results[@]:-}"; do [[ -n "$r" ]] && echo "  $r"; done
python3 - "${results[@]:-}" <<'EOF'
import re, sys
rates = [float(m.group(1)) for arg in sys.argv[1:] if (m := re.search(r'percent=([0-9.]+)', arg))]
if rates:
    print(f"  loss percent: mean {sum(rates)/len(rates):.2f}  min {min(rates):.2f}  max {max(rates):.2f}  (n={len(rates)})")
EOF
