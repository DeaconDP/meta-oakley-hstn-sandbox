# HSTN capabilities in DAT 1.0 (mwdat 1.0.1)

2026-10-22. Sources: the DAT docs (via the meta-wearables-docs MCP, doc version v1.0), the SDK submodules, and the mwdat 1.0.1 AARs in `~/.gradle/caches/modules-2/files-2.1/com.meta.wearable/` (inspected with `javap`). Short forms: `A/` = `sdks/meta-wearables-dat-android/`, `I/` = `sdks/meta-wearables-dat-ios/`, `docs/` = `https://wearables.developer.meta.com/docs/`.

## Summary

- HSTN is a first-class supported device. It is named in Hardware requirements (`docs/develop/dat/getting-started-toolkit` > Hardware requirements), and SDK 1.0.1 needs HSTN firmware **V128** + Meta AI app **V292** (`docs/develop/dat/version-dependencies` > 1.0.1). It shares firmware V128 with Ray-Ban Meta.
- **No per-device capability matrix exists in the docs.** The guides document each capability generically for "AI glasses". The only per-device flag in the API is display capability (`DeviceType.isDisplayCapable` / `supportsDisplay`), and it is false for HSTN (`docs/reference/android/dat/1.0/com_meta_wearable_dat_core_types_devicetype`). Nothing in the docs or SDKs separates HSTN from Ray-Ban Meta.
- Everything added in 1.0 except device state is **Experimental / dev-and-beta channel only** and can't ship to production: photo capture, camera audio, Motion, Inputs, Speech, voice invocations (`A/CHANGELOG.md:22-27`).

## Capabilities

| Capability | DAT 1.0 surface | Values | Status | Source |
|---|---|---|---|---|
| Camera stream | `StreamConfiguration(videoQuality, frameRate, compressVideo)` | `HIGH` 720x1280, `MEDIUM` 504x896 (default), `LOW` 360x640 (9:16). fps: 2, 7, 15, 24 (Android default), 30 (iOS default). Raw YUV or compressed HEVC | GA | `docs/develop/dat/streaming` > Framerate and resolution; `docs/reference/android/dat/1.0/com_meta_wearable_dat_camera_types_streamconfiguration` |
| Stream bandwidth ladder | automatic | Over Bluetooth Classic it drops one resolution step first, then lowers fps, but never below 15 fps | GA | `docs/develop/dat/streaming` > Framerate and resolution |
| Photo capture | `Camera.photo`, `PhotoConfiguration` | `PhotoResolution` SMALL ~480p, MEDIUM ~720p (default), LARGE ~1080p, FULL 4032x3024 (native sensor, ~12 MP). `PhotoQuality` LOW/MEDIUM/HIGH | Experimental | `docs/develop/dat/camera-capture` > Overview > Resolution; `docs/reference/android/dat/1.0/com_meta_wearable_dat_camera_photo_types_photoresolution`; `A/CHANGELOG.md:26` |
| Mic, in-band with stream | `StreamConfiguration.audioCodec` = `AudioCodec.PCM(sampleRate, channels)`, `Stream.audioStream` | `AudioSampleRate` 16000 / 44100 / 48000 (AAR enum). Not beamformed, so ambient sound comes through | Experimental | `docs/develop/dat/microphones-and-speakers` > Overview, > Capture audio while streaming from the camera; `A/CHANGELOG.md:27` |
| Mic, via HFP | plain OS Bluetooth (no DAT API) | Mono, 16 or 8 kHz, beamformed to the wearer's voice | OS-level | `docs/develop/dat/microphones-and-speakers` > Overview |
| Speakers | plain OS Bluetooth (no DAT API) | A2DP: output only, 44.1/48 kHz stereo. HFP: mono voice quality. The two profiles are mutually exclusive | OS-level | `docs/develop/dat/microphones-and-speakers` > Choose a profile |
| On-glasses ASR | `mwdat-speech` `Speech` → `TranscriptionResult(text, isFinal, confidence)` | Needs `Permission.MICROPHONE` | Experimental | `docs/develop/dat/speech` > Overview; `A/CHANGELOG.md:24` |
| IMU / Motion | `mwdat-motion` `Motion` → `MotionSample` | accel (m/s²), gyro (rad/s), magnetometer (µT), orientation quaternion. Every reading is nullable; magnetometer and orientation are "not produced by every device". Rates: 5/10 (default)/15/24/30/60 Hz | Experimental | `docs/develop/dat/motion` > Overview; `docs/reference/android/dat/1.0/com_meta_wearable_dat_motion_types_motionsamplingrate` |
| Input | `mwdat-inputs` `Inputs` → `InputEvent` (Nav, Select, Back, Button, Capture, Drag) | `InputSource`: CAPTOUCH, CAPTURE_BUTTON, ACTION_BUTTON, NEURAL_BAND, NEURAL_BAND_DRAG, UNKNOWN. The device decides gesture mapping, and the docs say it "can differ across device models" | Experimental | `docs/develop/dat/inputs` > Input sources; `A/CHANGELOG.md:22` |
| Voice invocation | `VoiceInvocationsStream` (`LaunchApp`) | n/a | Experimental | `A/CHANGELOG.md:25` |
| Device state | `Device.batteryLevel` (0-100), `chargingState`, `donState` (worn), `hingeState` (folded), `thermalLevel` | n/a | GA | `docs/develop/dat/device-state`; `docs/reference/ios_swift/dat/1.0/mwdatcore_devicestate`; `A/CHANGELOG.md:28` |
| Display | none. `DeviceType.OAKLEY_META_HSTN` = "without an integrated display". `mwdat-display` targets Meta Ray-Ban Display | n/a | n/a | `docs/reference/android/dat/1.0/com_meta_wearable_dat_core_types_devicetype` |

Lifecycle: closing the hinges disconnects Bluetooth, stops streams and forces the session to `STOPPED`. Reopening them doesn't restart the session (`docs/develop/dat/lifecycle-events` > Device availability).

## `GlassesModel` / `DeviceType` enums

**Yes, there is an HSTN entry**, and it has been there since 0.8.0 (`A/CHANGELOG.md:86`, `I/CHANGELOG.md:90`).

- Android `com.meta.wearable.dat.mockdevice.api.GlassesModel` (from `javap` on `mwdat-mockdevice-1.0.1.aar`), in declaration order: `RAYBAN_META, META_RAYBAN_DISPLAY, OAKLEY_META_HSTN, OAKLEY_META_VANGUARD, RAYBAN_META_OPTICS, META_GLASSES`. The constructor takes a `core.types.DeviceType` plus a `DeviceTypeRegistry` hardware code, so a mock HSTN reports `DeviceType.OAKLEY_META_HSTN`.
- Android `com.meta.wearable.dat.core.types.DeviceType` (from `javap` on `mwdat-core-1.0.1.aar`): `UNKNOWN, RAYBAN_META, OAKLEY_META_HSTN, OAKLEY_META_VANGUARD, META_RAYBAN_DISPLAY, RAYBAN_META_OPTICS, META_GLASSES`.
- iOS `GlassesModel`: `.rayBanMeta, .oakleyMetaHSTN, .oakleyMetaVanguard, .rayBanMetaOptics, .metaGlasses, .metaRayBanDisplay` (`I/AGENTS.md:342-343`). iOS `DeviceType`: `unknown, rayBanMeta, oakleyMetaHSTN, oakleyMetaVanguard, metaRayBanDisplay, rayBanMetaOptics, metaGlasses` (`docs/reference/ios_swift/dat/1.0/mwdatcore_devicetype`). The iOS submodule ships no `.swiftinterface`, so these come from docs.
- CameraAccess hard-codes `GlassesModel.RAYBAN_META` (`A/samples/CameraAccess/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/mockdevicekit/MockDeviceKitViewModel.kt:59`). That is a choice made by the sample, not an SDK limit.

## Can Mock Device Kit simulate an HSTN?

Yes: `mockDeviceKit.pairGlasses(GlassesModel.OAKLEY_META_HSTN)`. The BirdSpotter sample does exactly this (`A/samples/BirdSpotter/app/src/main/java/com/meta/pixelandtexel/birdspotter/data/dat/DatMockDeviceRepository.kt:454`; iOS `I/samples/BirdSpotter/BirdSpotter/Data/Dat/DatMockDeviceRepository.swift:430`).

Caveat: this is an identity-level simulation. Every model gets the same `MockGlassesServices` (camera, captouch, display, input, motion, speech, voiceinvocations: package list in the mockdevice AAR, `A/CHANGELOG.md:35`). The mock stream is a canned 504x896 HEVC asset (`notes/bench-android-native.md`). Mock Device Kit skips per-model input mappings and other device-side behaviour, which the docs say must be validated on hardware (`docs/develop/dat/inputs` > Mock Device Kit fidelity).

## Not determined

- Whether HSTN has an **action button** (`ACTION_BUTTON`) and whether it supports **Neural Band** input. The docs list these sources without naming devices.
- Whether HSTN's IMU provides **magnetometer / fused orientation** ("not every device produces it").
- Real HSTN stream fps and resolution under the Bluetooth ladder, and whether 30 fps at `HIGH` holds.
- Whether the HSTN firmware rejects any Experimental capability. Needs a real device on V128.
- The README's "12 MP ultra-wide" and "5-mic array" claims are not stated in DAT docs. Photo `FULL` = 4032x3024 (~12.2 MP) is consistent with 12 MP.
