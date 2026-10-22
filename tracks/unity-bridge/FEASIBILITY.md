# unity-bridge: feasibility and design

2026-10-22. This is desk research only. Nothing was installed and no Unity project exists yet.

**Verdict: GO, mock-only, about 4 days.** This PC already has everything needed. Unity 6.3 with full Android support is installed, and DAT 1.0.1 is on Maven Central, so the build needs no GitHub token. The mwdat AARs ship x86_64 native libraries, so the app can run on `HSTN_Mock_API34`. About 70% of the Kotlin can be reused from HstnBench. The real-HSTN run is blocked on the same Android 12+ phone as every other track.

## 1. Unity on this PC

- **Hub**: Unity Hub 43.7.0 is in `C:\Program Files\Unity Hub`. The secondary install path is `C:\Work\Development\Unity\UnityEditors` (from `%APPDATA%\UnityHub\secondaryInstallPath.json`). `C:\Program Files\Unity\Hub\Editor` does not exist.
- **The `unity` shim**: `%LOCALAPPDATA%\Unity\bin\unity.exe` is not an editor. It is the **Unity CLI 1.0.0-beta.8**, installed by Hub on 2026-09-23 (`%APPDATA%\UnityHub\cli-install.json`). Its commands include `editors`, `install`, `install-modules`, `build` (runs the editor in batch mode) and `doctor`. `unity editors --json` lists installed editors with their modules. Entries without a `location` are releases you could install, not installed ones.
- **`%LOCALAPPDATA%\Unity`**: holds only caches, licensing logs and old per-version preference folders (2018.3, 2018.4, 2019.1). There are no editors there.
- **Installed editors** (from `PlaybackEngines/AndroidPlayer` on disk):

| Editor | Android module | SDK / NDK / JDK |
|---|---|---|
| **6000.3.9f1** (use this) | yes | SDK platforms 34, 35, 36; NDK r27c; OpenJDK 17.0.9. Modules: Android, Android SDK & NDK Tools, iOS, OpenJDK, Web, Windows |
| 6000.3.8f1 | yes | same as above |
| 6000.0.36f1 | no | none |
| 2022.3.22f1 | player only | no SDK, NDK or JDK |
| 2021.3.3f1 | yes | SDK 29/30 and NDK only (too old for API 31+) |
| 2021.1.0f1, 2021.3.4f1, 2021.3.8f1, 2022.1.0b9 | partial | SDK only |
| 2020.3.x, 2021.2.7f1, 2021.3.14f1, 2022.1.0b2, 2022.2.0f1 | no | none |

- **Unity 6000.3.9f1 Android toolchain**: Gradle 8.13 (`Tools/gradle/lib`), AGP 8.10.0 (`Tools/GradleTemplates`), JDK 17. IL2CPP has **x86_64** player libraries (`Variations/il2cpp/Release/Libs/x86_64`), so it can build for the x86_64 emulator. The CLI reports `upgradeTo 6000.3.27f1`. That version is not needed.

## 2. Prior art

### Photon "Fusion Meta Wearables Camera Streaming"
Source: https://doc.photonengine.com/fusion/v2/industries-samples/fusion-meta-wearables-camera-streaming

- **Versions**: Unity 6.3, Fusion 2, Photon Voice 2.64, **DAT 1.0** (sample v2.1.1, 2026-09-30), Kotlin 2.0.21. Earlier write-ups cited DAT 0.5 and 0.6, so `tracks/unity-bridge/README.md` ("DAT 0.6") is out of date.
- **Graphics**: the sample requires Vulkan. GLES3 fails with `AndroidTextureView getTexID error` on ANGLE devices, but that error comes from Photon Voice's video path, not from DAT.
- **Frame transport**: Kotlin converts DAT **I420 to RGBA32** and double-buffers it. C# polls every frame over JNI with `hasNewFrame()`, then `pollFrame()` (returns a `byte[]`), then `getFrameMetadata()` (returns `"w|h|ts"`). `KotlinBufferToTextureConverter` loads the bytes into a `Texture2D`. `UnitySendMessage` carries only state and errors as JSON. Video does not go through `UnitySendMessage`, and the sample uses no texture pointers or AndroidJavaProxy.
- **Plugin**: `MetaWearablesPlugin.aar`, created with `new AndroidJavaObject(..., activity)`. Its manifest supplies `APPLICATION_ID`, `CLIENT_TOKEN` and `ANALYTICS_OPT_OUT`, left empty for Developer Mode. The Gradle files live in `Assets/Plugins/Android/`. The sample pulls DAT from GitHub Packages, so it needs `GITHUB_TOKEN` with `read:packages`. We don't: mwdat 1.0.1 is on Maven Central.
- **Permissions and registration**: a `PermissionProxyActivity` hosts `Wearables.RequestPermissionContract()` and reports back through `UnitySendMessage`. Registration calls `Wearables.startRegistration(activity)` and retries up to 3 times on `FAILED_TO_REGISTER`. The doc does not describe the deep-link handler.
- **Mock Device Kit**: not mentioned. The sample assumes real glasses in Developer Mode.
- **Download**: https://downloads.photonengine.com/download/fusion/fusion-meta-wearables-camera-streaming-2.1.1.zip?pre=sp returns an HTML **sign-in page**, not a zip (checked with curl on 2026-10-22). A **Photon account is required** to download it, plus Fusion and Voice AppIds to run it.
- **License**: the page states none. Assume Photon's SDK terms apply, which means we can read the sample for the pattern but must not vendor its code into this public repo.

### Other bridges
A web search on 2026-10-22 found **no public Unity plus DAT bridge** other than Photon's. The community wrappers are Flutter only (`flutter_meta_wearables_dat`, `meta_wearables_dat_flutter` on pub.dev). Meta ships no Unity SDK (https://developers.meta.com/wearables/faq/).

## 3. Minimal bridge design

```
tracks/unity-bridge/
  plugin/        Gradle Android library -> hstnbridge-release.aar (Kotlin, AGP 8.11 as in HstnBench)
  HstnUnity/     Unity 6000.3.9f1 project (later)
  bench.sh       autobench driver (mirrors tracks/android-native/bench.sh)
```

### 3.1 Kotlin AAR (`com.deaco.hstnbridge`)
Reuse from `tracks/android-native/HstnBench/app/src/main/java/.../cameraaccess/`:
- `bench/BenchClock.kt` and `bench/TtsReply.kt`, copied verbatim. They keep the logcat tag `HstnBench`.
- The session, stream and capture logic in `camera/CameraViewModel.kt` (`startSession`, `beginStream`, `capturePhoto`, `decodePhoto`/EXIF rotation). Move it out of the ViewModel into a plain `DatBridge` singleton with its own `CoroutineScope(SupervisorJob() + Dispatchers.Default)`.
- The mock setup from `mockdevicekit/MockDeviceKitViewModel.kt` and from `setupMockDevice` in `androidTest/.../InstrumentationTest.kt`: `MockDeviceKit.getInstance(ctx).enable(MockDeviceKitConfig(initialPermissionsGranted = true))`, `pairGlasses(RAYBAN_META)`, `powerOn`, `don`, `unfold`, `setCameraFeed(uri)` and `setCapturedImage(uri)`.
- Drop Compose, `HevcDecoder`, `VideoRecorder` and `StreamingService` (the foreground service is not needed for a foreground Unity app).

Public surface, kept JNI-friendly (primitives, `String` and `ByteBuffer` only):
```kotlin
object DatBridge {
  fun init(activity: Activity, listener: String /* Unity GameObject name */)  // Wearables.initialize(appContext)
  fun enableMock(feedAsset: String, photoAsset: String)  // MDK pair/power/don/unfold + feeds
  fun startRegistration()                         // launches DatProxyActivity (real HW only)
  fun startSession(); fun startStream(fps: Int); fun stopStream(); fun endSession()
  fun capturePhoto()                              // result -> photoBuffer + UnitySendMessage
  fun speak(text: String)                         // TtsReply
  fun frameBuffer(): ByteBuffer                   // direct, sized w*h*3/2, allocated once
  fun latestFrameSeq(): Long                      // bumps when a new frame is copied in
  fun frameInfo(): LongArray                      // [w, h, ptsUs, arrivalRealtimeNs]
  fun photoBuffer(): ByteBuffer                   // RGBA8888 of the rotated bitmap
  fun benchEnd(metric: String, detail: String)    // lets C# log through BenchClock
}
```
Events such as session, stream and registration state, errors, and `photoReady` go through `UnityPlayer.UnitySendMessage(listener, "OnDatEvent", json)`. That is fine because they are low-rate. In Unity 6 with GameActivity, use `com.unity3d.player.UnityPlayer.UnitySendMessage`, which Unity 6 keeps.

### 3.2 Frame transport: I420 in a shared direct ByteBuffer
- Stream with `StreamConfiguration(compressVideo = false)`. The SDK then decodes HEVC itself and delivers **YUV** `VideoFrame.buffer` (https://wearables.developer.meta.com/docs/reference/android/dat/1.0/com_meta_wearable_dat_camera_types_streamconfiguration). Photon reports the layout as I420. **Check whether it is I420 or NV12 on the first run** by logging the buffer size and sampling the chroma.
- Kotlin copies each frame into one of two preallocated **direct** ByteBuffers and swaps them under a lock. It does no RGBA conversion. At the mock's 504x896 size, a frame is 677 KB (I420) instead of 1.8 MB (RGBA), which is 2.7x less to copy and saves the CPU conversion Photon does.
- C# caches the JNI method IDs. When `latestFrameSeq()` changes, it gets the buffer pointer once with `AndroidJNI.GetDirectBufferAddress`, then calls `Texture2D.LoadRawTextureData(ptr, size)` and `Apply(false)` on a single **R8** texture of size `w x (h*3/2)`. A small unlit shader samples the Y, U and V regions and converts BT.601 limited-range YUV to RGB. This path allocates no managed memory per frame and works with both GLES3 and Vulkan, so Photon's Vulkan requirement does not apply.
- Rejected: `byte[]` returned per frame (Photon's way), because it allocates about 1.8 MB of GC garbage per frame at 24 fps. Also rejected: HEVC to `SurfaceTexture`/OES with an external texture, because it is zero-copy but GLES-only, needs native render-thread plumbing, and breaks on Vulkan. Keep it only as a later optimisation if the 24 fps copy shows up in a profile.
- Photo: decode and rotate in Kotlin (the existing `decodeWithOrientation`), fill `photoBuffer()` with RGBA, and have C# load it into an RGBA32 `Texture2D`. This happens once per capture, so the cost doesn't matter.

### 3.3 C# API (`Assets/HstnBridge/`)
```csharp
public sealed class HstnDat : MonoBehaviour {      // DontDestroyOnLoad; GameObject named "HstnDat"
  public event Action<DatState> StateChanged;      // parsed from OnDatEvent JSON
  public event Action<Texture2D> PhotoCaptured;
  public Texture VideoTexture { get; }             // R8 I420 texture + YUV material
  public void EnableMock(); public void StartRegistration();
  public void StartSession(); public void StartStream(int fps = 24); public void StopStream();
  public void CapturePhoto(); public void Speak(string text);
  void Update();                                   // polls latestFrameSeq, uploads frame
  void OnDatEvent(string json);                    // UnitySendMessage target
}
```
A Unity Editor stub (`#if !UNITY_ANDROID || UNITY_EDITOR`) feeds a static test texture, so the scene works in Play mode.

### 3.4 Activity, deep link and Mock Device Kit inside the Unity player
- Unity 6 uses **GameActivity** (`com.unity3d.player.UnityPlayerGameActivity`) by default, and GameActivity derives from AppCompatActivity. Even so, don't subclass Unity's activity or register activity-result launchers on it. Ship a transparent **`DatProxyActivity : ComponentActivity`** in the AAR, following the same idea as Photon's `PermissionProxyActivity`. It:
  - requests `BLUETOOTH_CONNECT` (runtime) and then calls `Wearables.initialize`. DAT needs initialization after permissions, as `MainActivity.kt` does.
  - hosts `Wearables.RequestPermissionContract()` for the camera permission in Meta AI.
  - calls `Wearables.startRegistration(this)`.
  - owns the **callback-scheme intent filter** (`<data android:scheme="hstnunity"/>`, `launchMode="singleTop"`) and calls `Wearables.handleIntent(intent, ...)` from `onCreate` and `onNewIntent`, as required since DAT 1.0 (https://wearables.developer.meta.com/docs/develop/dat/version-dependencies). It finishes once the state settles.
- The intent filter, the `APPLICATION_ID`/`CLIENT_TOKEN` meta-data (`0` or empty for Developer Mode) and the permissions go in the AAR's manifest. Gradle merges them into Unity's launcher manifest. Set the applicationId to `com.deaco.hstnunity` so it installs alongside `com.deaco.hstnbench` and the upstream sample.
- **Mock path**: `MockDeviceKitConfig(initialPermissionsGranted = true)` auto-grants the camera, and the mock simulates registration, so the mock benchmark never opens Meta AI or the proxy activity. Copy the feed assets (`plant.mp4`, HEVC as MDK requires, and `plant.png`) from `HstnBench/app/src/main/assets` into the AAR's `assets/`, and use them through a FileProvider or a `file://` URI copied to `cacheDir`.

### 3.5 Gradle and SDK constraints
- **Player Settings**: Minimum API Level **31** (matches HstnBench). DAT's own AARs need only minSdk 29, so 31 comes from the sample. Target API **36**: the editor bundles android-36, and mwdat-core pulls `androidx.activity 1.10.1` and `core 1.16.0`, which need compileSdk 35 or higher. Use IL2CPP with **ARM64 + x86_64**. x86_64 is required for the emulator, and `mwdat-core` ships `jni/x86_64`. GLES3 or Vulkan both work with the R8 path.
- **Dependencies**: the AAR is built separately with HstnBench's AGP 8.11.1 and Kotlin 2.2.21. Unity's Gradle (AGP 8.10, Gradle 8.13) only packages it. Unity does not resolve the dependencies of a bare `.aar`, so enable **Custom Main Gradle Template** and list `com.meta.wearable:mwdat-core/camera/mockdevice:1.0.1`, `org.jetbrains.kotlin:kotlin-stdlib:2.2.21`, `kotlinx-coroutines-android` and `androidx.activity:activity-ktx`. Put `mavenCentral()` in **Custom Settings Gradle Template** (Unity 6 already includes google() and mavenCentral()). The alternative is to publish the AAR with its POM to a local Maven repo in `plugin/build/repo` and add that repo, so Gradle resolves the transitive dependencies. Pick one; start with the template list.
- **Watch for**: duplicate-class or `META-INF` packaging conflicts (copy HstnBench's `packaging { excludes += "/META-INF/{AL2.0,LGPL2.1}" }` into the launcher template), R8/minify stripping DAT and fbjni classes in release builds (benchmark a development build, or copy the mwdat consumer rules), and soloader/fbjni on x86_64 (supported in theory, unproven inside the Unity player).

### 3.6 Timing metrics (to match notes/bench-android-native.md)
- Log the five existing metrics in Kotlin through the copied `BenchClock`, at exactly the same points: `session_start`, `stream_to_first_frame` (first non-config `VideoFrame`), `capture_to_photo` (to the decoded bitmap), `tts_to_audio_start` and `tts_total`. That makes them directly comparable with the android-native numbers.
- Add bridge metrics, logged from C# through `DatBridge.benchEnd`. They use the same `HstnBench` tag, so `adb logcat -s HstnBench` captures everything:
  - `stream_to_first_texture`: from `addCamera` to the first `LoadRawTextureData` in Unity.
  - `capture_to_texture`: from `capturePhoto()` to the photo `Texture2D` being ready in C#.
  - `frame_bridge_ms p50/p95`: from Kotlin frame arrival (`elapsedRealtimeNanos` in `frameInfo`) to the C# upload, measured over 240 frames.
  - `unity_fps` and `frames_dropped`: sequence gaps seen by `Update()`.
- Driver: `tracks/unity-bridge/bench.sh [runs]`. The instrumentation test can't drive Unity UI, so each run does `adb shell am force-stop com.deaco.hstnunity` and then `am start -n com.deaco.hstnunity/com.unity3d.player.UnityPlayerGameActivity --ez hstn_autobench true`. The force-stop gives a cold start each time, like `am instrument`. C# reads the extra and runs the sequence mock, session, stream, wait for the first frame, capture, speak, then quits. Afterwards the script runs `adb logcat -d -s HstnBench:I | grep metric=`. Write the results to `notes/bench-unity-bridge.md`.

## 4. Effort estimate (mock only, one person)

| Step | Days |
|---|---|
| `plugin/` Gradle library: DatBridge facade, copied BenchClock/TtsReply, MDK setup, double-buffered I420, DatProxyActivity and manifest | 1.25 |
| Unity project: Player Settings, Gradle templates, first successful APK on the x86_64 emulator (the riskiest step: dependency and packaging conflicts) | 1 |
| C# `HstnDat`, YUV shader, minimal scene with preview, photo and buttons, Editor stub | 1 |
| Autobench mode, `bench.sh`, 5 runs, notes and scorecard row | 0.5 |
| Buffer for Unity-on-emulator GPU and layout surprises | 0.5 |
| **Total** | **~4.25** |

The real-HSTN run adds about 0.5 day once a phone running Android 12 or later is available, which is the same blocker as in ROADMAP.md.

## 5. Risks and open questions
- **Unity player on the emulator**: GLES3 through host GPU emulation is normally fine. Vulkan on the emulator is unreliable, so build with GLES3 first.
- **YUV layout**: whether the buffer is I420 or NV12, and whether rows are padded beyond the width, is not documented for Android. Confirm it on the first frame.
- **Coroutine threads**: the DAT flows are collected off the main thread. `UnitySendMessage` is thread-safe and queues to the Unity thread, but all JNI calls from C# happen on the Unity main thread, so the lock on buffer swaps must stay short.
- **Strategic value**: `tracks/unity-bridge/README.md` says this track is only worth doing for 3D/AR or networked content. For the benchmark task itself, a Unity build can be no faster than android-native, because it adds the bridge copy on top of the same DAT calls. It mainly measures that overhead and the developer experience.
