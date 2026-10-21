# Roadmap

1. **Baseline**: run the official CameraAccess sample on Android against the Mock Device Kit, then the real HSTN.
   - Mock: done 2026-10-21 (notes/baseline-android-mock.md).
   - Real HSTN: blocked on an Android 12+ phone and Developer Mode pairing.
2. **Benchmark in each track**: build the same benchmark task (see notes/sdk-comparison.md) in android-native, then unity-bridge / flutter / ios-native as needed.
3. **Pick a winner**: fill in the scorecard and commit to one track.
4. **Build the actual idea** on the chosen track.

## Deferred
- 2026-10-21: Real-HSTN baseline run. The only phone available is a Galaxy S7 (API 26), and the sample's minSdk is 31. `TODO.md:6`
- 2026-10-21: Didn't check whether `GlassesModel` has an Oakley HSTN entry. The sample pairs only RAYBAN_META, which is fine for camera work. `sdks/meta-wearables-dat-android/samples/CameraAccess/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/mockdevicekit/MockDeviceKitViewModel.kt:59`
