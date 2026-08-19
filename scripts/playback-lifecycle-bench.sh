#!/usr/bin/env bash
set -euo pipefail

destination="${1:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation)}"
build_settings=()
if [[ "$destination" == *Simulator* ]]; then
  build_settings+=(CODE_SIGNING_ALLOWED=NO)
fi

xcodebuild test \
  -project Lagoon.xcodeproj \
  -scheme LagoonHardwareRegression \
  -destination "$destination" \
  -only-testing:LagoonUITests/PlayerRegressionUITests/testPlaybackDismissSettingsReplayLifecycleAndStallBenchmark \
  "${build_settings[@]}"
