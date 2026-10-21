# TODO

- [ ] Pair HSTN with the Meta AI app and turn on Developer Mode
- [ ] Register an app in the Wearables Developer Center and get the application ID
- [x] Build and run sdks/meta-wearables-dat-android/samples/CameraAccess against the Mock Device Kit (2026-10-21, emulator `HSTN_Mock_API34`; see notes/baseline-android-mock.md)
- [ ] Get an Android 12+ (API 31+) phone for real-HSTN testing. The USB Galaxy S7 is Android 8.0 and can't install the sample
- [ ] Run CameraAccess against the real HSTN (needs both items above)
- [x] Step-2 benchmark in android-native on the mock (2026-10-22, notes/bench-android-native.md)
- [ ] Re-run `tracks/android-native/bench.sh` on a real phone + HSTN and confirm `route=a2dp`
- [ ] Check which DAT 1.0 capabilities HSTN actually exposes (camera / mic / audio / IMU)
- [ ] Decide whether the iOS track matters (needs the Mac)
