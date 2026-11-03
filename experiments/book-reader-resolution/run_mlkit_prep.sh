#!/usr/bin/env sh
# Run ML Kit (MlKitFolderScore, -e dumpLines true) over each out/mlkit_prep/<variant> folder on
# the emulator and pull the per-image line JSON to <variant>/results/ plus the harness TSV.
# Needs the HstnBench app + test APK installed. Usage: ./run_mlkit_prep.sh [variant ...]
# Then: .venv/Scripts/python prep_for_mlkit.py score
set -e
export MSYS_NO_PATHCONV=1
ADB="${ADB:-$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe}"
SERIAL="${SERIAL:-emulator-5554}"
PKG=com.deaco.hstnbench
DEV=/sdcard/Download/book-ocr
FILES=/sdcard/Android/data/$PKG/files
cd "$(dirname "$0")/out/mlkit_prep"
[ $# -gt 0 ] || set -- crop crop_up2 crop_up3 crop_up2_enh crop_max2000
for v in "$@"; do
  echo "== $v $(date +%T)"
  local_dir="$(cd "$v" && (pwd -W 2>/dev/null || pwd))"
  "$ADB" -s "$SERIAL" shell rm -rf "$DEV" "$FILES/mlkit-lines" "$FILES/book-ocr-results.tsv"
  "$ADB" -s "$SERIAL" shell mkdir -p "$DEV"
  "$ADB" -s "$SERIAL" push "$local_dir/." "$DEV/" >/dev/null
  "$ADB" -s "$SERIAL" shell am instrument -w \
    -e class com.meta.wearable.dat.externalsampleapps.cameraaccess.MlKitFolderScore \
    -e folder "$DEV" -e dumpLines true \
    "$PKG.test/androidx.test.runner.AndroidJUnitRunner" | tail -5
  rm -rf "$v/results" "$v/mlkit-lines"
  "$ADB" -s "$SERIAL" pull "$FILES/mlkit-lines" "$local_dir/" >/dev/null
  mv "$v/mlkit-lines" "$v/results"
  "$ADB" -s "$SERIAL" pull "$FILES/book-ocr-results.tsv" "$local_dir/book-ocr-results.tsv" >/dev/null || true
  echo "== $v done $(date +%T): $(ls "$v/results" | wc -l) results"
done
