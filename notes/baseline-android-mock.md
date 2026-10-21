# Baseline: CameraAccess on Android + Mock Device Kit

2026-10-21. Upstream sample at `sdks/meta-wearables-dat-android/samples/CameraAccess`, mwdat 1.0.1.

Result: works end to end on an emulator. Registration, session, live stream, and photo capture all ran against mock glasses. No glasses, no Meta AI app, no Developer Center credentials.

## Build

```sh
cd sdks/meta-wearables-dat-android/samples/CameraAccess
echo "sdk.dir=$env:LOCALAPPDATA/Android/Sdk" > local.properties   # forward slashes; backslashes get eaten
./gradlew.bat assembleDebug
```

- JDK 21 is fine. The Gradle wrapper (8.14.1) downloads itself.
- `mwdat-*` resolve from Maven Central with no auth.
- The cold build took about 3 minutes and produced a ~95 MB debug APK.
- `local.properties` and `build/` are gitignored upstream, so the submodule stays clean.

## Run

- `minSdk 31` (Android 12). The USB phone here (Galaxy S7, SM-G930F) runs Android 8.0 / API 26, so it **can't** install the sample.
- AVD `HSTN_Mock_API34` uses `system-images;android-34;google_apis;x86_64` with the `pixel` profile.

```sh
emulator -avd HSTN_Mock_API34 -no-snapshot-save -no-boot-anim
adb -s emulator-5554 install -r app/build/outputs/apk/debug/app-debug.apk
```

## Mock flow (in the app)

1. Allow "nearby devices".
2. Open the bug FAB (Debug menu), tap **Enable MockDeviceKit**, then **Pair Ray-Ban Meta**.
3. Turn on Power and **Donned**. Donned also sets Unfolded. Without Donned, starting a session fails with `RemoteSessionMockService: Device not worn - donned=false` / `START_ERROR_DEVICE_UNAVAILABLE`.
4. Set Camera source to Back camera (emulator virtual scene), Front camera, or Video file, then grant camera permission.
5. Close the sheet. The app shows "Ready" (mock registration happens automatically). Tap **Start session**, then **Preview**, then **Capture photo**.

## Observations

- The sample's mock UI pairs only `GlassesModel.RAYBAN_META`. It has no HSTN model, which is close enough for camera work.
- Debug sheet toggles ignore taps while the sheet is still animating open. Wait a second before tapping.
