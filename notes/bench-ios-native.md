# Benchmark: ios-native (Mock Device Kit)

2026-10-30. `tracks/ios-native/HstnBench`, mwdat 1.0.1, Xcode 27.1, simulator "HstnBench iPhone 17" (iOS 27.0), 5 runs via `tracks/ios-native/bench.sh`. All 5 passed. Run locally on this Mac (`MacBook-Pro`) without the Tailscale/ssh step.

| Metric | What it measures | Runs (ms) | Median |
|---|---|---|---|
| session_start | `startSession()` → `.started` | 20, 20, 19, 18, 19 | 19 |
| stream_to_first_frame | `addCamera` → first HEVC frame (540x960) | 103, 102, 100, 87, 79 | 100 |
| capture_to_photo | `capturePhoto()` → decoded 960x1440 image | 362, 361, 401, 334, 362 | 362 |
| tts_to_audio_start | `speak()` → `didStart` | 97, 86, 83, 75, 89 | 86 |
| tts_total | `speak()` → `didFinish` ("Photo captured.") | 2060, 1920, 1947, 2012, 1986 | 1986 |

A second batch of 5, run after the `AudioInputHandler` fix, gave medians of 19, 98, 367, 90, and 1952 ms in the same order. The table is the first batch because only that run kept per-run values.

## Caveats

- These are mock numbers, same as Android. They say nothing yet about Bluetooth/Wi-Fi transport on real glasses.
- Against the Android emulator: session, first frame, and capture are about 10x faster, and `tts_to_audio_start` about 2.5x. `tts_total` is slower (1986 vs 1369 ms), probably because of a different voice and speaking rate. Most of the gap is the emulator, not the platform, so don't read it as an iOS-vs-Android result until both run on real hardware.
- TTS played on the Mac (`route=phone`) because the Simulator has no A2DP sink. Glasses-speaker routing still needs a real HSTN.
- `tts_to_audio_start` includes activating the audio session when it isn't already up. Since 2026-10-30 the session is shared with the accessibility earcons and announcer (`A11yAudioSession`) and released about 2 s after the last sound, so a reply right after an earcon skips activation. Re-run the bench before comparing against the table above.

## Fixes made while getting here

- `bench.sh` passes `-collect-test-diagnostics never`. A runtime warning made xcodebuild run a sysdiagnose after every test, about 10 minutes per run against a 30 s test.
- `TtsReply` does its audio-session work on a serial queue (that was the main-thread warning) and caches the voice. It ducks other audio and deactivates after each reply, so music on the glasses comes back instead of being cut off for good. It also always sets `.playback` unless a recording is running. Before this, a finished recording left the session at play-and-record, so every later reply would have gone over HFP (mono, call quality) instead of A2DP.
- `AudioInputHandler` (upstream sample code) read `audioEngine.inputNode` on every recording, even without a glasses mic. On the Simulator that stalled the audio server and the app aborted with an RPC timeout, so `testPhotoCaptureWhileRecording` crashed on the original code too. It now touches the input node only when the glasses HFP mic is active. It removes its tap even if the engine never started, and it releases the session after video-only recordings. Full suite: 21/21 pass (17 UI, 4 unit).

## Read it aloud: trigger → first spoken word (added 2026-10-30, not measured yet)

`BENCH_READ=1 ./bench.sh` also runs `ReadAloudUITests/testReadAloud`, which feeds the mock a printed page (`A11y/Read/Fixtures/read_page.mp4` / `.png`, made by `tools/make-read-fixtures.swift`) and presses Read. New metric lines, same `metric=… ms=…` layout:

| Metric | What it measures |
|---|---|
| trigger_to_first_word | Read trigger → `didStart` of the first spoken line (detail `first=text\|guidance\|photo_notice\|starting_camera`, `source=frame\|photo`, `route=`). Target ≤ 1.5 s (ROADMAP phase 2) |
| ocr | Vision `VNRecognizeTextRequest` (`.accurate`, language correction on) alone |
| frame_age | Age of the stream frame handed to OCR (the latest decoded frame, not `capturePhoto`) |
| read_photo | `capturePhoto` for reading, only when there is no frame from the last second or the text is too small in it |

No numbers yet: on 2026-10-30, after a CoreSimulator update, the mock session would not start in any UI test on this Mac, `testPhotoCaptureAndDismiss` on unchanged HEAD included, so neither test could run. The real Vision pass over the fixture does run in the unit tests (`ReadFixtureOCRTests`) and reads the page in order.

## Re-run 2026-11-01 (shared audio session, British voice from 6892fda, Start-session hit-target fix)

5 of 5 runs passed on "HstnBench iPhone 17" (Simulator, mock). Medians: session_start 21, stream_to_first_frame 41, capture_to_photo 354, tts_to_audio_start 48 (`route=phone`), tts_total 1404 ms. First frame and TTS start are about half the 2026-10-30 numbers; `tts_total` dropped from about 1986 to 1404 ms, most likely because of the new voice. These are still Simulator numbers and say nothing about Bluetooth on real glasses.

`BENCH_READ=1` still has no numbers. The mock session now starts, but `ReadAloudUITests/testReadAloud` fails every time on sentence 2: the transcript reads "The quick brown(?) fox(?) jumps(?) over the lazy dog." because Vision's alternatives on the mock stream frame disagree, so those words are marked unsure. The test expects the sentence with no marks.
