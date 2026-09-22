#!/bin/bash
# Frame-loss bench: runs the in-app Frame-Loss Bench N times on one movie at
# one pinned start position in the tvOS simulator, then prints each run and a
# summary.
#
#   scripts/framedrop-bench.sh --title "Deadgirl" --position 600 --runs 3 \
#       --set debug.simulatorTranscode=true
#
# Options:
#   --title <name>   required. Must exactly match a movie's name
#                    (case/diacritic-insensitive). Movies only, not episodes.
#   --year <year>    picks between movies that share a title
#   --position <s>   start position in seconds (default 300)
#   --runs <n>       number of runs (default 3)
#   --udid <udid>    target simulator (default: booted)
#   --set key=bool   app default to write before each run, for A/B tests
#   --window <s>     seconds to wait for the window (default 60). The app
#                    owns the real window; this only sets the wait.
#
# Measurement rules:
#   * same title, start position and media-time window every run;
#   * leave the simulator untouched during a window (screenshots force render
#     captures and corrupt the numbers);
#   * 3+ runs, because single runs mean nothing at this effect size.
#
# The app does the measuring (10 s warmup + 60 s window on media time) and
# logs a "Bench Result" signpost. Each run force-quits the app, writes the
# bench defaults (`debug.benchSearchTerm`, `debug.benchStartSeconds`, and
# `debug.benchProductionYear` with --year), and relaunches, so
# `MainTabView.launchBenchItemIfRequested()` finds the movie and starts
# playback. It also forces `debug.frameLossBench`, `debug.playbackHUD` and
# `debug.benchAutoExit` on. A `lagoon://` deep link cannot do this: the
# router drops links without the current Top Shelf `?owner=&generation=`
# pair.
#
# The app must already be installed and signed in on the simulator. Every
# default written is deleted afterwards. On hardware, read the HUD's Bench
# line instead, after leaving the scene untouched.
#
# Output: each run's dropped/percent fields, then the mean, min and max
# loss percent.

set -euo pipefail

BUNDLE_ID="ee.helop.lagoon"
SUBSYSTEM="ee.helop.lagoon"

title=""
year=""
position=300
runs=3
udid="booted"
warmup=10
window=60
slack=35
declare -a sets=()

usage() { sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --title) title="$2"; shift 2 ;;
        --year) year="$2"; shift 2 ;;
        --position) position="$2"; shift 2 ;;
        --runs) runs="$2"; shift 2 ;;
        --udid) udid="$2"; shift 2 ;;
        --set) sets+=("$2"); shift 2 ;;
        --window) window="$2"; shift 2 ;;   # informational: the app owns the window
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
done

[[ -n "$title" ]] || { echo "--title \"<exact movie title>\" is required" >&2; usage; }

# --- defaults this script owns -----------------------------------------------
# Tracked so they can all be deleted after the runs.
declare -a written_keys=(
    debug.frameLossBench
    debug.playbackHUD
    debug.benchAutoExit
    debug.benchSearchTerm
    debug.benchStartSeconds
)
[[ -n "$year" ]] && written_keys+=(debug.benchProductionYear)
for kv in "${sets[@]:-}"; do
    [[ -n "$kv" ]] || continue
    written_keys+=("${kv%%=*}")
done

# --- runs -------------------------------------------------------------------
wait_seconds=$((warmup + window + slack))
results=()

for run in $(seq 1 "$runs"); do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true

    # Without these there is no result to read, and the last run leaves the
    # player on screen.
    xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.frameLossBench -bool true >/dev/null
    xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.playbackHUD -bool true >/dev/null
    xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.benchAutoExit -bool true >/dev/null
    xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.benchSearchTerm -string "$title" >/dev/null
    xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.benchStartSeconds -float "$position" >/dev/null
    if [[ -n "$year" ]]; then
        xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" debug.benchProductionYear -int "$year" >/dev/null
    fi
    for kv in "${sets[@]:-}"; do
        [[ -n "$kv" ]] || continue
        key="${kv%%=*}"; value="${kv#*=}"
        xcrun simctl spawn "$udid" defaults write "$BUNDLE_ID" "$key" -bool "$value" >/dev/null
        echo "default $key = $value"
    done

    start_iso=$(date '+%Y-%m-%d %H:%M:%S')
    xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    echo "run $run/$runs: \"$title\"${year:+ ($year)} at ${position}s — hands off the simulator for ${wait_seconds}s"
    sleep "$wait_seconds"

    # The simulator has its own log store; the host's `log show` misses these.
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
done

# --- leave the simulator as it was found -------------------------------------
for key in "${written_keys[@]}"; do
    xcrun simctl spawn "$udid" defaults delete "$BUNDLE_ID" "$key" >/dev/null 2>&1 || true
done

# --- summary ----------------------------------------------------------------
echo
echo "=== ${#results[@]}/$runs runs completed — \"$title\" @ ${position}s ==="
for r in "${results[@]:-}"; do [[ -n "$r" ]] && echo "  $r"; done
python3 - "${results[@]:-}" <<'EOF'
import re, sys
rates = [float(m.group(1)) for arg in sys.argv[1:] if (m := re.search(r'percent=([0-9.]+)', arg))]
if rates:
    print(f"  loss percent: mean {sum(rates)/len(rates):.2f}  min {min(rates):.2f}  max {max(rates):.2f}  (n={len(rates)})")
EOF
