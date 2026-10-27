#!/usr/bin/env sh
# Step-2 benchmark: runs the mock pair -> session -> stream -> photo -> TTS flow N times in the iOS
# Simulator and prints the HstnBench timing lines. Run on the Mac, from this directory.
# Usage: ./bench.sh [runs]
# It uses its own simulator ("HstnBench iPhone 17") so it never touches other booted simulators.
set -e
RUNS="${1:-5}"
SIM_NAME="${SIM_NAME:-HstnBench iPhone 17}"
DERIVED="${DERIVED:-$HOME/Library/Developer/HstnBench/DerivedData}"
TEST="CameraAccessUITests/CameraAccessUITests/testPhotoCaptureAndDismiss"
cd "$(dirname "$0")/HstnBench"

UDID=$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$UDID" ]; then
  RUNTIME=$(xcrun simctl list runtimes available | grep -E '^iOS' | tail -1 | sed -E 's/.* - (com\.apple[^ ]+).*/\1/')
  UDID=$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$RUNTIME")
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
DEST="platform=iOS Simulator,id=$UDID"

xcodebuild build-for-testing -project CameraAccess.xcodeproj -scheme CameraAccess \
  -destination "$DEST" -derivedDataPath "$DERIVED" -quiet

SINCE=$(date '+%Y-%m-%d %H:%M:%S')
# Parallel testing runs on throwaway simulator clones, where the photo step fails, so run serially.
# xcodebuild can leave the simulator shut down, so boot it before every run.
for i in $(seq 1 "$RUNS"); do
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  if xcodebuild test-without-building -project CameraAccess.xcodeproj -scheme CameraAccess \
    -destination "$DEST" -derivedDataPath "$DERIVED" -only-testing:"$TEST" \
    -parallel-testing-enabled NO -quiet >/dev/null 2>&1; then
    echo "run $i: OK"
  else
    echo "run $i: FAIL"
  fi
  sleep 3
done

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl spawn "$UDID" log show --start "$SINCE" --style compact \
  --predicate 'subsystem == "com.deaco.hstnbench"' | grep -oE '(metric=|tts_).*'
