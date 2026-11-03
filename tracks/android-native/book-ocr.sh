#!/usr/bin/env sh
# Book-reader OCR harness: pushes a local folder of page images + ground truth to the device, runs
# ML Kit over every image (MlKitFolderScore) and prints CER/WER per image (logcat tag BookOcrScore).
#
# Usage: ./book-ocr.sh <local-folder> [device-folder]   (needs a booted API 31+ device/emulator)
#   <local-folder>  images plus manifest.tsv (<image>\t<truth.txt> per row), or image/.txt pairs
#                   with matching base names
#   device-folder   default /sdcard/Download/book-ocr (wiped and re-pushed each run; no spaces)
# Results TSV is pulled to <local-folder>/book-ocr-results.tsv.
# With several devices attached, pick one: ANDROID_SERIAL=emulator-5554 ./book-ocr.sh ...
set -e
if [ -z "$1" ] || [ ! -d "$1" ]; then
  echo "usage: $0 <local-folder> [device-folder]" >&2
  exit 1
fi
# Absolute path in a form adb.exe understands on Git Bash (C:/...), plain path elsewhere.
LOCAL="$(cd "$1" && (pwd -W 2>/dev/null || pwd))"
DEVICE_DIR="${2:-/sdcard/Download/book-ocr}"
ADB="${ADB:-adb}"
PKG=com.deaco.hstnbench
# Git Bash would otherwise rewrite /sdcard/... into a Windows path.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/HstnBench"
if command -v cmd.exe >/dev/null 2>&1; then GRADLEW=./gradlew.bat; else GRADLEW=./gradlew; fi
"$GRADLEW" installDebug installDebugAndroidTest -q

"$ADB" shell rm -rf "$DEVICE_DIR"
"$ADB" shell mkdir -p "$DEVICE_DIR"
"$ADB" push "$LOCAL/." "$DEVICE_DIR/" >/dev/null
"$ADB" logcat -c
"$ADB" shell am instrument -w \
  -e class com.meta.wearable.dat.externalsampleapps.cameraaccess.MlKitFolderScore \
  -e folder "$DEVICE_DIR" \
  "$PKG.test/androidx.test.runner.AndroidJUnitRunner" | grep -E "^OK|FAIL|Error|shortMsg" || true
"$ADB" logcat -d -s BookOcrScore:V | grep -E "image=|summary|folder=|results=" || true
"$ADB" pull "/sdcard/Android/data/$PKG/files/book-ocr-results.tsv" "$LOCAL/book-ocr-results.tsv" >/dev/null \
  && echo "results: $LOCAL/book-ocr-results.tsv"
