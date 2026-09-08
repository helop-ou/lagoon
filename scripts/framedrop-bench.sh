#!/bin/bash
# Frame-loss bench harness (HEL-64).
#
# Runs the in-app frame-loss bench (Settings → Debug → Frame-Loss Bench)
# against one movie at one pinned start position, N times, in the tvOS
# simulator — and prints the per-run results plus a summary. This encodes
# the measurement discipline that caught two false positives on HEL-64:
#
#   * same title, same pinned start position, same media-time window every
#     run;
#   * the simulator is left completely untouched during a window
#     (screenshots force render captures and corrupt the numbers);
#   * 3+ runs, because single runs are meaningless at this effect size.
#
# The app side does the measuring (10 s warmup + 60 s window keyed on
# media time, result as a "Bench Result" signpost + HUD line); this script
# just launches, waits, and reads the signpost back out of the unified
# log. Since HEL-141, `DeepLinkRouter` only accepts `lagoon://` links
# carrying an `?owner=&generation=` pair matching the current Top Shelf
# publication, so the old `lagoon://play/{id}` link this script used to
# open is now silently dropped. Instead this drives `MainTabView`'s
# launch-time bench hook (`launchBenchItemIfRequested()`): it force-quits
# the app, writes `debug.benchSearchTerm` / `debug.benchStartSeconds` (and
# optionally `debug.benchProductionYear`) via `defaults write` on the
# simulator, then relaunches so the app's own startup task resolves the
# title against the MOVIES library and jumps straight into playback at
# that position. **The title must exactly match a movie's name**
# (case/diacritic-insensitive) — the hook only searches
# `includeTypes: [.movie]`, so TV episodes cannot be benched this way.
# `--year` disambiguates remakes/re-releases that share a title. A/B
# experiments toggle app defaults between runs with --set, e.g.:
#
#   scripts/framedrop-bench.sh --title "Deadgirl" --position 600 --runs 3 \
#       --set debug.simulatorTranscode=true
#
# The app must already be installed on the target simulator and signed
# in — playback no longer needs server credentials from this script.
# Every default this script writes is deleted again once the runs are
# done, leaving the simulator's defaults as they were found. Real-hardware
# runs can't be scripted this way — there, read the same result from the
# HUD's Bench line after leaving the scene untouched.

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
# Tracked so every one of them can be deleted again once the runs are done —
# the simulator's app defaults should come out of a bench run exactly as
# they went in.
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

    # The bench itself, the HUD, and a clean auto-exit are always forced
    # on: without them there is no result to read and the last run leaves
    # the player on screen.
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
