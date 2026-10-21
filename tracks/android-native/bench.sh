#!/usr/bin/env sh
# Step-2 benchmark: runs the mock pair -> session -> stream -> photo -> TTS flow N times and prints
# the HstnBench timing lines. Usage: ./bench.sh [runs]   (needs a booted API 31+ device/emulator)
set -e
RUNS="${1:-5}"
ADB="${ADB:-adb}"
cd "$(dirname "$0")/HstnBench"
./gradlew.bat installDebug installDebugAndroidTest -q
"$ADB" logcat -c
for i in $(seq 1 "$RUNS"); do
  "$ADB" shell am instrument -w \
    -e class com.meta.wearable.dat.externalsampleapps.cameraaccess.InstrumentationTest#photoCaptureAndDismiss \
    com.deaco.hstnbench.test/androidx.test.runner.AndroidJUnitRunner | grep -E "^OK|FAIL" || true
  sleep 3
done
"$ADB" logcat -d -s HstnBench:I | grep metric=
