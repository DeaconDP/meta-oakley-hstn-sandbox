# Book reader on Android (HstnBench)

2026-10-27. The first build of the book reader from `notes/book-reader.md`, in `tracks/android-native/HstnBench`. It has only been tested on the Mock Device Kit (emulator `HSTN_Mock_API34`, mock `OAKLEY_META_HSTN`). Real glasses haven't been tried yet.

## What was built

**Pure-Kotlin core** (`.../cameraaccess/book/`, no Android imports, JVM unit-tested):

| File | Does |
|---|---|
| `OcrModel.kt` | Engine-neutral OCR result (`OcrPage` > `OcrBlock` > `OcrLine` with box + confidence) |
| `PageLayout.kt` | Finds the gutter (the widest vertical gap near the middle that almost no line crosses) and reads left page then right. Puts rows in reading order, merging same-row segments. Drops the running header and page number: digit or roman numerals, or "12 TITLE"/"TITLE 13", set apart by a gap ≥ 1.5× line pitch; chapter headings are kept. Builds paragraphs from gaps, indents, and short lines that end a sentence. Rejoins line-end hyphens (`exam-`+`ple`), keeps real ones (`hearth-rug`, `anti-American`), and rejoins words across the gutter even when headers are read aloud |
| `PageDedup.kt` | "Same page?" uses word-bigram containment (≥ 0.5). Re-OCR noise or a half-framed copy of the same page counts as the same page; the next page scores ~0 |
| `FramingCheck.kt` | Spoken hints from box geometry: text touching an edge gives "Page cut off on the right. Turn your head right." (the right edge has the lowest threshold because the camera is on the left). Both sides cut gives "further away". No text or low confidence gives "Can't read this. Hold the book steady, a little closer." Tiny text gives "closer" |
| `SpeechChunker.kt` | Sentence split that doesn't break on `Mr.`, `J. R. R.` or `?" said`. Sentences over 180 chars split at `; : , —`, then at spaces. Also handles "back a sentence" |
| `Bookmark.kt` | Saves pages read + last sentence; on resume, finds that sentence again by fuzzy match |
| `PageTurnDetector.kt` | READING → TURNING (≥2 consecutive big-change frames) → SETTLING → CAPTURE (5 still frames with text) → `captureDone()`. `nextPage()` is the manual fallback. `FrameSizeMotion` turns compressed HEVC frame sizes into a 0..1 motion score (no decode) |
| `PageProcessor.kt` | One capture in, one decision out: Hint / SamePage / Read. Carries a word broken across two captures (`occu-` … `pation`) |
| `TextDistance.kt` | CER/WER (Levenshtein, whitespace-normalised) |

**Android glue** (`.../cameraaccess/bookreader/`):

- `MlKitOcr.kt`: ML Kit Text Recognition v2, Latin, bundled model (`com.google.mlkit:text-recognition:16.0.1`). On-device and offline.
- `PageCamera.kt`: the seam to the camera. `CameraViewModel` implements it: `capturePage()` is the GA in-stream `stream.capturePhoto()` without the preview sheet or the bench "Photo captured." reply; `frameSizes` is every compressed frame's size; `isStreaming`.
- `BookReaderViewModel.kt`: the loop. Page-turn events or Next page → capture → OCR (Default dispatcher) → `PageProcessor`. Pages queue up, so page N+1 is captured and OCR'd while page N is spoken. Framing hints retry every 2.5 s, and the third attempt reads whatever is in view. A bookmark is saved after every chunk. A lost stream (fold, session end) stops speech and keeps the bookmark. Speech rate, read-furniture and auto-turn settings persist in SharedPreferences `book_reader`.
- `BookSpeaker.kt`: one TTS utterance per chunk with `USAGE_ASSISTANCE_ACCESSIBILITY`. Generation counters stop a cut-off utterance from advancing the reader. If no TTS engine is available, reading still advances and the screen says so. `TtsReply` was left alone: it's the benchmark's timing probe and uses media attributes.
- `Earcons.kt`: `ToneGenerator` on the accessibility stream for ack, turn detected, page captured, same page, page done and error. Every control press plays ack.
- `ui/BookReaderScreen.kt`: big Start/Pause/Resume button, Next page, Back a sentence, Slower/Faster plus a rate slider (0.5–3.0×), and switches for "Read page numbers and headers" and "Detect page turns automatically". All are labelled for TalkBack, and each switch is one merged node. Recognised text is shown at 26 sp, white on black, with the sentence being spoken highlighted black on yellow. To open it, use the new "Book reader" pill on the camera screen, which is enabled while streaming.

**Tests**

- JVM unit tests (`app/src/test/.../book/`): 51 tests. The fixtures have real page geometry: a Conan Doyle page and a Wells two-page spread with headers carrying page numbers, indents, line-end and cross-gutter hyphens, plus a cut-off-right variant, a re-OCR with errors and the next page.
- `BookReaderTest` (androidTest, Mock Device Kit): renders a book page (`BookPageRenderer`: justified serif, header, page number, hyphen breaks), sets it as the mock HSTN's captured image, streams `plant.mp4`, opens the reader and presses Start. It asserts the text read has CER ≤ 2%, no header or page number, hyphens rejoined, and 3 paragraphs. A second test presses Next page on the same image and expects "Same page".
- `BookOcrPipelineTest` (androidTest, no mock): real ML Kit plus layout on a rendered single page and a 1440x960 spread.
- `MlKitFolderScore` (androidTest harness) plus `tracks/android-native/book-ocr.sh`: see below.

## Results

Emulator `HSTN_Mock_API34` (API 34, headless, `-no-audio`), mwdat 1.0.1, ML Kit text-recognition 16.0.1.

- `./gradlew.bat assembleDebug testDebugUnitTest`: BUILD SUCCESSFUL, **51/51 unit tests pass**.
- **Book instrumented tests all pass**: `BookReaderTest` (2: reads the page off the mock HSTN; same page detected on Next page), `BookOcrPipelineTest` (2: single page; spread split at the gutter, headers and page numbers dropped, `ex-`/`traordinarily` rejoined across the gutter), `MlKitFolderScore`, `RegistrationButtonTest`.
- What the reader produced from the mock capture (960x1440 in-stream photo) matched the expected text exactly: header and page number gone, `oc-`/`casions` and `be-`/`hind` rejoined, `hearth-rug` kept, 3 paragraphs.
- Timings on the mock (logcat `HstnBench`): `book_capture_to_photo` 0.9–1.3 s (the bench's 3.9 s `capture_to_photo` includes the preview/TTS path), `book_ocr` 16–19 s in-app on the emulator, `book_capture_to_text` 17–20 s.
- **Full instrumented suite** (27 tests, `am instrument`): 25 pass. `InstrumentationTest#photoCaptureAndDismiss` and `#photoCaptureWhileRecording` fail with the SDK logging `Photo capture timed out after 10000ms` for `plant.png` on the mock Ray-Ban. **This was already failing:** an untouched HEAD build in a temporary worktree fails the same two tests the same way on the same emulator session. In the same session the book tests capture their own PNG on a mock HSTN in about 1 s. Not investigated further; re-check `bench.sh` on a fresh emulator.

**MlKitFolderScore smoke run** (`book-ocr.sh` on 4 synthetic copies of one rendered page, scratch folder, not the experiment dataset):

| image | OCR ms | lines | CER raw | CER layout | WER layout |
|---|---|---|---|---|---|
| 960x1440 | 13656 | 28 | 0.546 | 0.015 | 0.047 |
| 720x1080 | 5450 | 28 | 0.561 | 0.006 | 0.019 |
| 504x896 | 6150 | 15 | 0.070 | 0.009 | 0.047 |
| 360x640 | 4044 | 13 | 0.074 | 0.015 | 0.047 |

At higher resolution ML Kit splits each widely justified line into two segments (28 "lines" for 14), so the raw text interleaves half-lines and raw CER is ~55%. The layout pass's same-row merge puts them back together. Take "layout" as the number that matters for the reader. These are clean renders, so the real resolution answer has to come from the photographed dataset in `experiments/book-reader-resolution/`.

### Running the harness

```sh
cd tracks/android-native
ANDROID_SERIAL=emulator-5554 ./book-ocr.sh <local-folder> [/sdcard/Download/book-ocr]
```

The folder holds the images plus `manifest.tsv` (`<image>	<truth.txt>` per row; a header row and `#` comments are fine) or `name.png` + `name.txt` pairs. Device paths can't contain spaces. The script installs both APKs, wipes and re-pushes the device folder, runs `MlKitFolderScore` with `-e folder`, prints the `BookOcrScore` lines, and pulls `book-ocr-results.tsv` into the local folder. Direct run: `adb shell am instrument -w -e class com.meta.wearable.dat.externalsampleapps.cameraaccess.MlKitFolderScore -e folder /sdcard/Download/book-ocr com.deaco.hstnbench.test/androidx.test.runner.AndroidJUnitRunner`. Without `-e folder` and with no data, the test skips, so a plain `connectedAndroidTest` stays green.

## Voice control (2026-11-03)

A blind user can't use the screen, so voice became the default, both ways and from launch. Decisions: understanding is **on-device only** (no cloud), and the mic is **the glasses' own speech recognition with a phone fallback**.

**From launch.** There's a second launcher entry, **"Book Reader"** (`activity-alias .BookReaderLauncher`), so "Hey Google, open Book Reader" works. The same mode can be reached with `--ez book_reader true` or `hstnbench://book`. It opens straight into the reader, and `PageCamera.connectAndStream` starts the session and then the stream with no confirmation dialog. If camera access is missing, it says so and opens Meta AI. Each step is narrated: "Connecting to your glasses", "Your glasses are ready. Hold the book open… say read", or "I can't reach your glasses… I'll keep trying". If the app was never registered with Meta AI, it says that the one-time setup is needed. Saying "close" saves the bookmark, says goodbye, ends the session and backgrounds the app.

**Listening** (`bookreader/VoiceInput.kt`, `VoiceControl.kt`):
- Glasses: `mwdat-speech` (`session.addSpeech()`, Experimental). Only text crosses the link, so the reading voice stays on A2DP stereo. It needs the DAT `MICROPHONE` permission; the reader explains this out loud before opening Meta AI. A photo capture puts the recogniser down, so it's restarted (5 tries, 600 ms apart). The reader captures a photo every page.
- Fallback: Android `SpeechRecognizer.createOnDeviceSpeechRecognizer` (API 31+) on the **phone** mic, restarted after every result. It deliberately doesn't open Bluetooth SCO, because the hands-free mic would make a whole chapter mono. It's used when there's no session within 20 s, the mic permission is refused, speech won't attach or start within 5 s, or the glasses later report `UNAVAILABLE`.

**Understanding** (`book/VoiceCommands.kt`, pure Kotlin, 15 JVM tests): ordered regex rules over normalised text. Fillers and an optional address ("reader, …") are dropped. Commands: Pause, Resume/start, NextPage, Repeat, Back(n sentences), BackParagraph, FromTop, Faster/Slower (0.25, or 0.5 for "much"), SetRate ("1.5x", "one and a half times", "double speed", "normal speed"), WhereAmI, Help, ReadFurniture on/off, AutoTurn on/off, Close. Room chatter ("turn right at the lights", "stopwatch") parses to nothing.

**Talking back.** Every command gets a short spoken answer ("Paused.", "1.5 times speed.", "Page 3 since you started. Sentence 4 of 12…"). An answer cuts off the sentence being read and then reads that sentence again, so the user never waits for a long sentence to finish. "Stop" acts on the *partial* transcript (barge-in). Unknown speech gets "Sorry, I didn't get that. Say help…", but only between pages, for ≤ 6 words, and at most once per 8 s; during reading it's ignored as room noise.

**Nudging (2026-11-05).** The end of a page is spoken, not only shown: "End of page. Turn the page, then say next page." (or "…and I'll read it" with auto-turn on), unless the next page is already being captured. If the reader is then waiting for the user (not started, or between pages; not reading, capturing, retrying, paused or without glasses) and nobody says or presses anything, it reminds them what it's waiting for after 30 s, 60 s and 2 min of quiet, and the last reminder adds "I'll stay quiet now. Say read whenever you're ready." Anything the user says, even speech that isn't a command, or any button press starts the count over. Timing is `book/IdleNudge.kt` (3 JVM tests); the wiring is `remindWhenQuiet()` in `BookReaderViewModel`. `BookReaderTest#saysWhatToDoAtTheEndOfAPage` checks the end-of-page prompt on the mock. The silence reminders themselves haven't fired in an instrumented test yet (the tests finish before 30 s of quiet).

**Echo guard.** The mic hears our own TTS. `BookSpeaker` reports each utterance's actual start (`onUtteranceStarted`), and `EchoGuard` drops a transcript that is a run of words being spoken right now. That covers a command word read out from the book ("Stop!" cried Holmes), including as a partial. For 2 s after speech ends, only fragments of 3+ words count, so a user answering "Say read to start" with "read" is heard. Trade-off: saying a command word that the current sentence also contains is ignored. Use a synonym ("pause", "wait").

**Tests** (emulator `HSTN_Mock_API34`, all pass):
- `BookReaderTest#voiceDrivesTheReaderThroughTheGlasses`: after opening the reader, everything is driven through `glasses.services.speech.simulateTranscription`: "I'll tell you when I turn the page" → auto-turn off; "OK, start reading please" → page read (CER ≤ 2%); "a bit faster" → 1.3×; "hang on" → paused; "Reader, close the book" → screen closes.
- `VoiceFirstLaunchTest`: launched with `EXTRA_BOOK_READER` and no taps at all. The reader opens, session_start takes 2.0 s, the glasses mic is picked, and "read" reads the page.
- The two existing `BookReaderTest` cases still pass with voice running alongside the buttons. 66/66 JVM unit tests pass.

**Not verified yet:**
- Real glasses: whether on-glasses speech coexists with a camera stream and the A2DP reading voice, recognition quality on the open-ear speaker's echo, and the restart after each capture.
- The phone recogniser: it beeps on every restart on many phones, and it's only been compiled, not exercised (the mock always had glasses speech).
- Background mic access with the screen off (Android 14+ may need a `microphone` foreground-service type).
- "Hey Meta, start Book Reader" (voice invocation: Experimental, needs Developer Center approval).
- Command phrases are English-only.

## Pitfalls: spoken, and recovered from (2026-11-03)

Nothing that stops reading is reported only on screen. Each condition is spoken once, when it changes, and also shown on the status line.

| Pitfall | How it's detected | What the user hears / what happens |
|---|---|---|
| Bluetooth off on the phone | `BluetoothAdapter` state broadcast | "Bluetooth is off on your phone… Turn Bluetooth on." Glasses alerts are held back while it's off |
| No glasses linked | `Wearables.devices` empty | "I can't find any glasses linked… Pair your glasses in the Meta AI app first." |
| Glasses disconnected / back | DAT metadata `linkState` | Pause, "Your glasses disconnected. I've saved your place…"; "connected again", then the camera comes back by itself |
| Glasses folded / session ended | Stream drops (folding has no signal of its own) | The reader is **paused, not reset**: the captured page can still be read. A quiet reconnect runs every 4 s while the glasses look connected. "The glasses camera is back. Say read to carry on." |
| Taken off / put back on | `donState` | Pause, "You took your glasses off…"; "Glasses on. Say read to carry on." |
| Camera paused from the glasses (tap) | `StreamState.PAUSED` | "The glasses paused the camera. Tap the side of the glasses to carry on." |
| Camera permission refused | Meta AI result | "Camera access wasn't allowed… Say read to ask again." "read" retries |
| Can't reach the glasses at all | No stream within 20 s | The most specific reason available: Bluetooth off, not linked, update required, camera refused, not worn, else "check they're on, unfolded…" |
| Glasses or phone battery low | DAT `batteryLevel`, `ACTION_BATTERY_CHANGED` | Once each at 20 / 10 / 5 %, re-armed by charging; at 5 % the bookmark is saved. "battery" asks for both levels |
| Overheating | DAT `thermalLevel` (moderate/severe = warm, critical+ = too hot) | "getting warm"; too hot: pause and "take them off for a few minutes" (on the mock the glasses end the session themselves); "cooled down", then reconnect |
| Glasses or SDK update required | DAT `compatibility` | "Your glasses need a software update… in the Meta AI app." |
| Lens covered / too dark / no page in view | `ImageCheck` on a 48x72 point-sampled luma grid, **before OCR** (instant) | "Is something covering the camera?" / "too dark… turn on a light" / "I can't see a page… about a forearm's length away". Retried every 2.5 s |
| Glare / hand over part of the page | Same check, used only when OCR found no usable text | "There's glare… tilt the book" / "Something is covering part of the page, maybe a hand or thumb" |
| Text cut off, too small, low confidence | `FramingCheck` (existing) | "Turn your head right", "closer", … |
| Still can't read after 3 tries | Hint counter | "I still can't read the page. Say read when you're ready to try again." (never silent) |
| OCR slow | Timer | Soft tick every 2.5 s; after 10 s, "Still reading this page." |
| No TTS engine | `TextToSpeech` init failure | Error tone (the only channel left); the screen says so |
| No mic (glasses speech and phone both unavailable) | `VoiceControl` | "Voice control is off… The buttons on the phone screen still work." Glasses speech that won't restart (glasses gone) falls back to the phone mic, and moves back to the glasses on reconnect |
| App never registered with Meta AI | Registration state on voice-first launch | "Book Reader needs a one-time setup with the Meta AI app…" |

Code: `book/ReaderHealth.kt` (`HealthMonitor`, edge-triggered, pure), `book/ImageCheck.kt` (pure), `bookreader/ReaderWatch.kt` (DAT metadata + system broadcasts → snapshots), all wired in `BookReaderViewModel`. 18 JVM tests in `PitfallTest.kt`.

`PitfallsTest` (instrumented, mock HSTN, voice-first, no taps) passes: covered lens → dark room → readable page via the automatic retries, battery 9 %, doff/don, thermal critical/none, fold, then unfold + don → reconnects by itself (session restart 89 ms). The full instrumented suite passes, 30/30, on a fresh emulator. That includes `InstrumentationTest#photoCapture*`, which failed in the earlier session.

**Not verified on hardware:** real metadata values (battery, thermal and don state on HSTN), the ImageCheck thresholds on real camera photos (a clean white render trips GLARE, which is harmless because GLARE never blocks OCR), and the reconnect behaviour of a real fold. Glasses may need to be worn before they're "eligible" again (that's how the mock behaves).

## Gaps and next steps

- **Nothing has run on real HSTN.** Still unverified: capture resolution and latency over Bluetooth/Wi-Fi, whether the frame-size motion signal actually tracks head and page motion (the mock streams a canned clip), the framing thresholds against real camera geometry, and TTS reaching the glasses over A2DP.
- **Page-turn signal is a proxy.** `FrameSizeMotion` uses HEVC frame size. It costs nothing, but it's untested on real motion. Keyframes are filtered only by requiring 2 consecutive high frames. On the mock, the looping plant clip looks like page turns, so the tests switch auto-turn off. A pixel-difference score from decoded frames would plug into the same `FrameSignal`.
- **Capture is in-stream photo only.** The "latest stream frame" path needs a decoder → `ImageReader` branch (today the HEVC decoder renders straight to the preview Surface).
- **OCR is slow on the emulator**: 16–19 s per 960x1440 page in-app, against ~5 s with no stream running. On the emulator the CPU is shared with the software HEVC preview decode. Needs a phone measurement. The pipelining helps, but only if OCR finishes faster than a page is spoken.
- **ML Kit quirk:** on one widely justified rendered line it returned `TheTimeTravellerwasexpoundingarecondite`, a single element with no spaces. `MlKitOcr` rebuilds lines from elements when the elements still have word boundaries. Splitting on per-character box gaps was tried and dropped: the symbol boxes are too loose and it produced "breakfa st". It also misread `ex-` as `exX-` at 24 px on the spread. Real book photos may or may not show this; the folder harness will tell.
- **Layout not handled**: two-column textbooks (rows would merge across columns), footnotes, side notes, curved-gutter dewarping, and a dictionary check for real hyphens at line ends ("well-known" across a line break becomes "wellknown").
- Framing hint strings and dedup are English-only and hard-coded in the core. UI strings are resources.
- Hints aren't spoken over a page being read; the next capture repeats them. A hint during reading is shown on screen and marked with the error earcon.
- Voice control is in (see Voice control above). No captouch controls yet.
