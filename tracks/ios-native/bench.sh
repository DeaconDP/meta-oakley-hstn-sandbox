#!/usr/bin/env sh
# Step-2 benchmark: runs the mock pair -> session -> stream -> photo -> TTS flow N times in the iOS
# Simulator and prints the HstnBench timing lines. Run on the Mac, from this directory.
# Usage: ./bench.sh [runs]
#        BENCH_READ=1 ./bench.sh [runs]   also runs the "Read it aloud" test each run, adding
#                                        trigger_to_first_word, ocr, frame_age and read_photo.
# It uses its own simulator ("HstnBench iPhone 17") so it never touches other booted simulators.
set -e
RUNS="${1:-5}"
SIM_NAME="${SIM_NAME:-HstnBench iPhone 17}"
DERIVED="${DERIVED:-$HOME/Library/Developer/HstnBench/DerivedData}"
TESTS="-only-testing:CameraAccessUITests/CameraAccessUITests/testPhotoCaptureAndDismiss"
if [ "${BENCH_READ:-0}" = "1" ]; then
  TESTS="$TESTS -only-testing:CameraAccessUITests/ReadAloudUITests/testReadAloud"
fi
FAILS=0
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
# Diagnostics collection (a sysdiagnose) adds about 10 minutes per run, so it's off.
# Parallel testing runs on throwaway simulator clones, where the photo step fails, so run serially.
# xcodebuild can leave the simulator shut down, so boot it before every run.
for i in $(seq 1 "$RUNS"); do
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  if xcodebuild test-without-building -project CameraAccess.xcodeproj -scheme CameraAccess \
    -destination "$DEST" -derivedDataPath "$DERIVED" $TESTS \
    -parallel-testing-enabled NO -collect-test-diagnostics never -quiet >/dev/null 2>&1; then
    echo "run $i: OK"
  else
    echo "run $i: FAIL"
    FAILS=$((FAILS + 1))
  fi
  sleep 3
done

xcrun simctl bootstatus "$UDID" -b >/dev/null
LINES=$(xcrun simctl spawn "$UDID" log show --start "$SINCE" --style compact \
  --predicate 'subsystem == "com.deaco.hstnbench"' 2>/dev/null | grep -oE '(metric=|tts_).*' || true)
echo "$LINES"

# n, min, median, and max per metric.
echo
printf "%-24s %3s %6s %6s %6s\n" metric n min median max
echo "$LINES" | awk '
  /^metric=/ { split($1, m, "="); split($2, t, "="); v[m[2]] = v[m[2]] " " t[2] }
  END {
    for (k in v) {
      n = split(substr(v[k], 2), a, " ")
      for (i = 2; i <= n; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] + 0 > x + 0; j--) a[j + 1] = a[j]; a[j + 1] = x }
      med = (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
      printf "%-24s %3d %6d %6d %6d\n", k, n, a[1], med, a[n]
    }
  }' | sort

[ "$FAILS" -eq 0 ] || { echo "$FAILS of $RUNS runs failed" >&2; exit 1; }
