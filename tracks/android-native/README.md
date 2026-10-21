# android-native

Kotlin app using `com.meta.wearable:mwdat-core` / `mwdat-camera` from Maven Central.

`HstnBench/` is a copy of `sdks/meta-wearables-dat-android/samples/CameraAccess` (mwdat 1.0.1) with the step-2 benchmark added:

- `bench/BenchClock.kt` logs timings to logcat under the tag `HstnBench` (`metric=<name> ms=<n>`).
- `bench/TtsReply.kt` speaks "Photo captured." after each photo. It uses media audio attributes, so the reply goes to the glasses over A2DP when they're connected. It logs `route=a2dp|sco|phone`.
- applicationId is `com.deaco.hstnbench` and the callback scheme is `hstnbench`, so it installs alongside the upstream sample.

Run `./bench.sh [runs]` against a booted API 31+ device. It reuses the upstream `photoCaptureAndDismiss` instrumentation test to drive the mock flow. Results go in `notes/bench-android-native.md`.

Build needs `HstnBench/local.properties` with `sdk.dir` set to the Android SDK (gitignored). Use forward slashes.
