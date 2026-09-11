#!/usr/bin/env bash
#
# Background-fill bench (HEL-160): plays one title hands-off on a simulator
# with the decode trace on and reports how the direct-play cache filled over
# time, so two builds can be compared on the same asset, media-time window
# and link. It reads the `cacheMB=` / `netMB=` fields the decode trace prints
# every two seconds and the engine's stall/drop counters on the same line.
#
#   scripts/fill-bench.sh <simulator-udid> <app-path> "<exact title>" [seconds] [runs]
#
# Environment: LAGOON_REGRESSION_SERVER / _USER / _PASS select the server
# (default: the public demo). The app is installed fresh on the simulator
# each run and launched through the bench hook (`-debug.benchSearchTerm`),
# which plays from the beginning; `-debug.regressionResetState` is passed,
# so never point this at a simulator whose sign-in you want to keep.
#
# Output per run: one line per checkpoint (30/60/90/… s) with cached MB,
# network MB, request count, stalls and dropped frames, then a summary with
# the average fill rate over the window in MiB/s.
set -euo pipefail

udid="${1:?simulator udid}"
app="${2:?path to Lagoon.app}"
title="${3:?exact title}"
seconds="${4:-120}"
runs="${5:-3}"
bundle="ee.helop.lagoon"
server="${LAGOON_REGRESSION_SERVER:-https://demo.jellyfin.org/stable}"
user="${LAGOON_REGRESSION_USER:-demo}"
pass="${LAGOON_REGRESSION_PASS:-}"

xcrun simctl boot "$udid" >/dev/null 2>&1 || true
for run in $(seq 1 "$runs"); do
    log="$(mktemp -t fill-bench)"
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl install "$udid" "$app"
    SIMCTL_CHILD_LAGOON_REGRESSION_SERVER="$server" \
    SIMCTL_CHILD_LAGOON_REGRESSION_USER="$user" \
    SIMCTL_CHILD_LAGOON_REGRESSION_PASS="$pass" \
    xcrun simctl launch --console-pty "$udid" "$bundle" \
        -debug.playerRegression YES -debug.regressionBootstrapPublicDemo YES \
        -debug.regressionResetState YES -debug.benchSearchTerm "$title" \
        -debug.playbackHUD NO -debug.decodeTrace YES > "$log" 2>&1 &
    launch_pid=$!
    start=$SECONDS
    until grep -qa "DecodeTrace" "$log" || [ $((SECONDS - start)) -gt 90 ]; do sleep 1; done
    if ! grep -qa "DecodeTrace" "$log"; then
        echo "run $run: playback never started (see $log)" >&2
        kill "$launch_pid" >/dev/null 2>&1 || true
        continue
    fi
    first=$SECONDS
    echo "run $run: playing, sampling for ${seconds}s"
    while [ $((SECONDS - first)) -lt "$seconds" ]; do sleep 5; done
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    kill "$launch_pid" >/dev/null 2>&1 || true
    python3 - "$log" "$seconds" <<'EOF'
import re, sys
log, window = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(log, errors="replace"):
    if not line.startswith("DecodeTrace"):
        continue
    def f(key, default=None, cast=float):
        m = re.search(rf"\b{key}=(-?[0-9.]+)", line)
        return cast(m.group(1)) if m else default
    rows.append((f("position"), f("cacheMB"), f("netMB"), f("req", cast=int), f("stalls", cast=int), f("dropped", cast=int)))
if not rows or rows[0][1] is None:
    print("no cache trace fields in this build's output")
    sys.exit(0)
print("  t(s)  position  cachedMB   netMB  req  stalls  dropped")
checkpoints = {30, 60, 90, 120, 180, 240, 300}
t0 = None
for i, (pos, cache, net, req, stalls, dropped) in enumerate(rows):
    t = i * 2
    if t in checkpoints or i == len(rows) - 1:
        print(f"  {t:4d}  {pos:8.1f}  {cache:8.1f}  {net:6.1f}  {req:3d}  {stalls:6d}  {dropped:7d}")
first, last = rows[0], rows[-1]
span = max((len(rows) - 1) * 2, 1)
print(f"  fill {(last[1] - first[1]) / span:.2f} MiB/s cached, {(last[2] - first[2]) / span:.2f} MiB/s network over {span}s; "
      f"stalls {last[4]}, dropped {last[5]}")
EOF
    echo "  log: $log"
done
