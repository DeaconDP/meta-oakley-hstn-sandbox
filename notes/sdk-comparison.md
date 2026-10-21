# SDK comparison

Benchmark task: **stream glasses camera to the phone, take a photo, and play a TTS reply through the glasses speakers.**

| Track | Official? | Dev machine | Mock device | Time to first frame | Latency | Pain points | Verdict |
|---|---|---|---|---|---|---|---|
| android-native | yes | this PC | yes (CameraAccess baseline OK on API 34 emulator, 2026-10-21) | | | minSdk 31; mock needs "Donned" on | |
| ios-native | yes | Mac (macbook-pro) | yes | | | | |
| unity-bridge | no (own plugin) | this PC | via plugin | | | | |
| flutter | community | this PC (Android) / Mac (iOS) | add-on pkg | | | | |
