# SDK comparison

Benchmark task: **stream glasses camera to the phone, take a photo, and play a TTS reply through the glasses speakers.**

| Track | Official? | Dev machine | Mock device | Time to first frame | Latency | Pain points | Verdict |
|---|---|---|---|---|---|---|---|
| android-native | yes | this PC | yes (CameraAccess baseline OK on API 34 emulator, 2026-10-21) | mock: 975 ms median (notes/bench-android-native.md) | mock: capture 3.9 s, TTS start 0.2 s | minSdk 31; mock needs "Donned" on; no audio-out API (plain BT A2DP/HFP) | |
| ios-native | yes | Mac (macbook-pro) | yes, in Simulator (video-file feed) | | | ready 2026-10-22; real-HSTN possible via iPhone 13 Pro Max | |
| unity-bridge | no (own plugin) | this PC (Unity 6000.3.9f1) | via plugin | | | ~4 days mock-only; Photon sample needs login and has no license; deferred unless 3D/networked | |
| flutter | community (`flutter_meta_wearables_dat` 1.0.1, wraps mwdat 1.0.1) | this PC (Android) / Mac (iOS) | `flutter_meta_wearables_dat_mock_device`, can pair as HSTN | | | Flutter not installed; ~1.5 days; TTS via flutter_tts | |
