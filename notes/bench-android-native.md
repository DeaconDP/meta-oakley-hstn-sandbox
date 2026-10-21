# Benchmark: android-native (Mock Device Kit)

2026-10-22. `tracks/android-native/HstnBench`, mwdat 1.0.1, emulator `HSTN_Mock_API34`, 5 runs via `tracks/android-native/bench.sh`. All 5 passed.

| Metric | What it measures | Runs (ms) | Median |
|---|---|---|---|
| session_start | `createSession` → `STARTED` | 221, 311, 216, 233, 198 | 221 |
| stream_to_first_frame | `addCamera` → first non-config HEVC frame | 1447, 914, 975, 858, 1008 | 975 |
| capture_to_photo | `capturePhoto()` → decoded 960x1440 bitmap | 5352, 3791, 3940, 3509, 4393 | 3940 |
| tts_to_audio_start | `speak()` → TTS `onStart` | 319, 211, 235, 203, 198 | 211 |
| tts_total | `speak()` → `onDone` ("Photo captured.") | 1711, 1429, 1369, 1345, 1350 | 1369 |

## Caveats

- These are mock numbers. The mock streams a canned HEVC asset at 504x896, so first-frame and capture times say nothing yet about Bluetooth/Wi-Fi transport on real glasses.
- The first run of each metric is the slowest (cold start).
- TTS played on the phone (`route=phone`) because the emulator has no Bluetooth A2DP sink. Getting audio onto the glasses speakers is still unverified and needs real HSTN hardware.
- DAT has no audio-output API. Glasses audio is plain Bluetooth: A2DP for playback only, HFP if you also need the mic, which drops output to mono voice quality. See the DAT "Microphones and speakers" guide.
