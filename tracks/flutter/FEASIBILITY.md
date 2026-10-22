# flutter: feasibility (2026-10-22)

Desk research only. Nothing installed, nothing built.

## Verdict: GO

`flutter_meta_wearables_dat` 1.0.1 wraps the same mwdat 1.0.1 as `tracks/android-native/HstnBench`. Its mock add-on wraps `mwdat-mockdevice` 1.0.1 and can pair an Oakley HSTN model. Streaming and photo capture are both exposed. The only work outside the plugin is TTS, which `flutter_tts` covers, plus a few lines of Kotlin to log the audio route.

## The package

| | |
|---|---|
| pub.dev | https://pub.dev/packages/flutter_meta_wearables_dat |
| Latest | 1.0.1, published about 2026-10-16. 160 pub points, 14 likes, about 625 downloads |
| Publisher | rodcone.io (verified). MIT license |
| Repo | https://github.com/rodcone/flutter_meta_wearables_dat. Created 2026-02-13, last push 2026-10-16, 15 stars, 4 forks, not archived. Two main maintainers (214 and 42 commits) |
| Android deps | `android/build.gradle`: `mwdat_version = "1.0.1"` (mwdat-core, mwdat-camera) from Maven Central, no GitHub token. minSdk 29, compileSdk 36, AGP 8.9.1, Kotlin 2.1.0, Java 11 |
| iOS deps | `ios/flutter_meta_wearables_dat.podspec` 1.0.1 vendors MWDATCore and MWDATCamera xcframeworks (SPM `Package.swift` too). iOS 17.2+. The simulator build is arm64-only. The CHANGELOG says both platforms are on DAT 1.0.1 |
| DAT 1.0 | Yes. 1.0.0 (2026-10-05) moved to DAT 1.0.0 and 1.0.1 moved to DAT 1.0.1. Not exposed yet: motion/IMU, inputs, speech, standalone photo capture, and Meta-AI-initiated registration (README, "DAT 1.0 compatibility") |
| Changelog | https://github.com/rodcone/flutter_meta_wearables_dat/blob/main/CHANGELOG.md |

### Mock Device Kit add-on
`flutter_meta_wearables_dat_mock_device` 1.0.1 (https://pub.dev/packages/flutter_meta_wearables_dat_mock_device) is in the same repo and depends on `com.meta.wearable:mwdat-mockdevice:1.0.1`.
- API: `configure`, `pairGlasses(model)` (`GlassesModel.oakleyMetaHSTN` is listed), `powerOn/Off`, `don/doff`, `setCameraFeed(uuid, videoPath)`, `setCameraFacing`, `setCapturedImage`, `setPermission`.
- `setCameraFeed` can play the same canned video the native mock uses, which keeps the numbers comparable. The default feed is the phone camera, which would be the emulator's virtual camera.
- The `don()` call covers the "Donned must be on" requirement from the native run.

### API surface (main package)
- `startStreamSession(deviceId?, frameRate, streamQuality, videoCodec, audio)` returns a texture ID for the Flutter `Texture` widget. Quality: low 360x640, medium 504x896, high 720x1280. FPS: 2, 7, 15, 24, 30. On Android only `VideoCodec.raw` is available (`hvc1` is iOS-only).
- `capturePhoto(deviceId, format)` returns `CapturedPhoto` bytes. On Android the device picks the format.
- Streams: `streamSessionStateStream`, `streamSessionErrorStream`, `videoStreamSizeStream`, `videoFramesStream`, `audioFramesStream` (glasses mic, 16 kHz PCM16, dev/beta channels only), `deviceStateStream`, `registrationStateStream`.
- Other: `captureStreamFrame(textureId)` returns RGBA, `enableBackgroundStreaming`, `startRegistration`, and `handleUrl` for the callback scheme.

### Open issues (5)
https://github.com/rodcone/flutter_meta_wearables_dat/issues
- PR #53: stream diagnostics and recovery. PR #51: separate device and camera session lifetimes.
- #31 and #33: iOS background keep-alive and diagnostics.
- #32: the iOS background keep-alive's `AVAudioSession` (.playAndRecord) claims the glasses as the A2DP output. It's relevant to the TTS step, but only on iOS and only with background streaming on.
- Known limitation: intermittent iOS session termination while locked. Not relevant to this benchmark.
- The single closed bug report, #47 "Black screen when streaming on Android", is fixed.

### Alternatives (pub.dev search "meta wearables")
- `meta_wearables_dat_flutter` 1.0.0 (iSee-Labs, unverified uploader, DAT 1.0.0, has a mock kit, 1 like). Younger and less used, but a fallback. https://pub.dev/packages/meta_wearables_dat_flutter
- `meta_wearables_flutter` 0.1.1, `meta_wearables_dat` 0.1.3 and `meta_wearables` 0.0.1 are all pre-1.0 and stale.

## This PC
- **Flutter/Dart: not installed.** Not on PATH. Not found in C:\flutter, C:\src\flutter, C:\tools\flutter, ~\flutter, scoop, chocolatey, WinGet or fvm. `%LOCALAPPDATA%\Pub\Cache` exists with leftovers from an old RustDesk build, but there's no SDK.
- Android SDK: `%LOCALAPPDATA%/Android/Sdk` (from `HstnBench/local.properties`). It has platforms android-33/35/36 (36 is needed for compileSdk 36), build-tools 34–36, NDK 27.x and the emulator.
- AVD `HSTN_Mock_API34` exists. JDK 17 and 21 are on PATH.
- Setup still needed: Flutter stable SDK (about 2 GB, `winget install Google.Flutter` or a git clone), then `flutter doctor --android-licenses`.

## Building the benchmark

| Step | Covered by | Notes |
|---|---|---|
| Register / pair (mock) | mock add-on: `configure`, `pairGlasses(oakleyMetaHSTN)`, `powerOn`, `don`, `setCameraFeed` | No native code |
| Stream to first frame | `startStreamSession`, then the first `videoFramesStream` event | Time it with a Dart `Stopwatch`. Includes platform-channel hop, so it's slightly pessimistic compared with native |
| session_start | `streamSessionStateStream` reaching `streaming` | Session and camera start are bundled in one call, so it may not split as cleanly as native `createSession` → `addCamera` |
| Photo | `capturePhoto()` → decode bytes with `instantiateImageCodec` | Same as `capture_to_photo` |
| TTS reply | `flutter_tts` 4.2.5 (https://pub.dev/packages/flutter_tts): `setStartHandler` / `setCompletionHandler` for `tts_to_audio_start` / `tts_total` | Android TTS plays on the media stream by default, so it goes over A2DP when the glasses are connected, same as `TtsReply.kt`. On iOS, `setIosAudioCategory(playback or playAndRecord + allowBluetoothA2DP)` |
| Route log (`route=a2dp\|sco\|phone`) | not covered | About 20 lines of Kotlin `MethodChannel` in `MainActivity` (`AudioManager.getDevices(GET_DEVICES_OUTPUTS)`), or the `audio_session` package |
| Automated runs (`bench.sh`) | not covered | Native reused the upstream instrumentation test. Flutter needs an `integration_test` driver run with `flutter test integration_test -d emulator-5554`. Log the same `metric=<name> ms=<n>` lines so `bench.sh` parsing can be reused |

Estimated effort: about half a day for SDK install and scaffolding (`flutter create`, plugin deps, manifest/callback scheme, Wearables app ID metadata as in the plugin README), then about a day to port the benchmark and the integration-test driver.

The real-HSTN run is blocked on the Android 12+ phone, the same as android-native. The plugin's minSdk 29 is lower than the native sample's 31, but the S7 (API 26) still doesn't qualify.

## Risks
- Single community maintainer with low usage. If it falls behind Meta's DAT updates, the escape hatch is forking or writing our own thin Kotlin plugin.
- Platform-channel overhead and Flutter texture rendering add latency, so the numbers are not perfectly comparable with native. That's part of what the benchmark measures.
- iOS A2DP output can be claimed by the background keep-alive (#32). Keep background streaming off for the benchmark.
