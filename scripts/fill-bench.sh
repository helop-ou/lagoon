#!/usr/bin/env bash
#
# Background-fill bench: plays one title hands-off on a simulator with the
# decode trace on and reports how the direct-play cache filled, to compare
# builds on the same asset, window and link.
#
#   scripts/fill-bench.sh <simulator-udid> <app-path> "<exact title>" [seconds] [runs]
#
# Defaults: 120 seconds, 3 runs. LAGOON_REGRESSION_SERVER / _USER / _PASS pick
# the server (default: the public demo). Each run reinstalls the app, plays
# from the start and resets its state, so never use a simulator whose sign-in
# you want to keep.
#
# Output per run: cached MB, network MB, requests, stalls and dropped frames
# at 30/60/90/… s, then the average fill rate in MiB/s.
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
