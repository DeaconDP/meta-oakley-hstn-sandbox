# Reading with an iPhone (iOS, V0 "Phone-specific UX")

Written 2026-11-20. This covers the TODO line "V0: haptics for framing; big-text mirror of what's read; iOS dark warning before reading". It also adds "read me the next step" from V2. All the code is in `tracks/ios-native/HstnBench/CameraAccess/A11y/Read/`. Screenshot: `design/screens/ios-big-text.png`.

## 1. Haptic framing

`FramingHaptics.swift`. Light taps match the spoken framing guidance. The voice still speaks; the taps are extra.

- **Page found**: text comes into view. One medium tap.
- **Edge cut off**: text runs off one side. Two light taps. The voice says which way to move.
- **Too close**: text runs off opposite sides. Three quick firm taps.
- **Too far**: the print is too small. One soft tap.
- **Lost**: the text left the frame. One light tap.
- **Dark**: the system warning pattern, just before the dark warning.
- **Locked**: well framed. One firm tap, repeated every 2 s while the page stays framed.

`HapticCueMapper` turns a framing verdict into a cue. It is pure. `HapticPacer` limits the rate, also pure: at least 0.4 s between any two cues, and the same cue at most every 3 s (locked every 2 s, dark every 10 s). So it never buzzes all the time.

Cues come from two places:

- Every read's verdict, on the phone camera, while the guidance is spoken.
- `FramingAssist`, while lining up. It runs while Read text is open, the phone camera is already running, and nothing is being read. About every 0.7 s it checks the latest frame with Vision's fast recognizer. It never starts the camera itself, so there is no camera prompt and no camera light before the first read. In practice: read, hear "cut off", move the phone, feel the locked tap, then read again.

The setting is "Haptics while lining up a page" in Settings > Reading (`reading_haptics_toggle`). It is on by default and stored in `PhoneReadingSettings`. iOS also skips UIKit haptics when System Haptics is off, so the system setting is respected without extra code. Nothing here runs for the glasses.

## 2. Big-text mirror

`BigTextMirror.swift`. A full-screen, very large, high-contrast view of the sentence being spoken. It follows the speech.

- **Word highlight.** The Announcer had no word timing, so I added a small hook to `Core/Announcer.swift`: `spokenWord` publishes AVSpeechSynthesizer's `willSpeakRange` and is cleared when the line ends. The mirror finds the word in the sentence's spoken chunks (`BigTextMirrorModel.wordIndex`). The natural (cloud) voice has no word timing, so with it the mirror follows by sentence only.
- It shows the words as they are spoken. A withheld dose reads "a dose I can't read reliably" here too.
- **Controls.** Swipe left for next, right for previous. Tap the text to pause or carry on. Buttons do the same: Previous, Pause or Carry on, Next, Smaller, Contrast, Larger, Close. All are 60 pt targets outlined in the text colour.
- **Size.** 48 pt at the default text size. It scales with Dynamic Type (`@ScaledMetric`), times its own scale from 0.75 to 2.5.
- **Contrast.** Yellow on black (the default), dark on light, light on dark. Every text pair, and the highlighted word, is above 7:1. A test checks this.
- **VoiceOver.** The mirror never speaks over VoiceOver. It posts no announcements, the sentence isn't a live region, and the highlight is visual only. Focus starts on Pause, not on the sentence. The sentence element has Next and Previous as custom actions, and swipe up or down (adjustable) moves too. Escape closes it. When VoiceOver is on, "big text" plays an earcon instead of speaking.
- The screen stays awake while it is open.
- **Opening it.** "Big text" on the reading card (`read_big_text_button`). By voice: "big text", "large print", "big text off", "close big text". In step mode it shows the current step.

## 3. Dark warning before reading

`DarkWatch.swift`. This runs on the phone camera, before OCR or the cloud. If the scene is dark, the app says "It's dark. Say torch on, or move somewhere brighter." and skips OCR. The first time in a run, if the phone has a torch and it is off, it adds "Shall I turn the torch on? Say yes, or tap Torch on." Saying "yes" or tapping Torch on turns the torch on, waits 0.9 s for the exposure to settle, and reads again. "No" says "OK. Say torch on any time."

- **How dark is measured.** The camera's own exposure gives the scene's EV at ISO 100: log2(N²/t) − log2(ISO/100), from `lensAperture`, `exposureDuration` and `iso`. A page of white text on black has a dark frame but a normal EV, so it isn't flagged. Without an EV (a fake source in tests), the frame's mean brightness stands in, with a stricter threshold.
- **Hysteresis.** It becomes dark below EV 3 (about 20 lux) and light again only above EV 4 (about 40 lux). Without an EV: below 0.10 and above 0.16 mean brightness. All four numbers are estimates to check on real phones.
- It warns once per dark spell. Reading again while still dark goes ahead with OCR, because the user heard the warning and wants to try. The framing check can still say "Too dark" after OCR.
- The glasses aren't checked. Their framing check is unchanged.

## 4. "Read me the next step"

`StepSplitter.swift` and `ReadSteps.swift`.

`StepSplitter.steps(in: String) -> [String]` is a pure function another tool can reuse. Its rules:

- A step starts with "Step 1", "1.", "1)", "1:", "a)", "(a)", or a bullet. A number alone on a line takes the next line. "1.5 cups" and "10:30" are not markers.
- Lines after a marker continue the step, up to the next marker, a blank line or a heading. A word hyphenated across lines is joined.
- A "Method", "Instructions", "Directions", "Steps" or "How to use" heading limits the search to the lines under it, up to the next heading such as "Notes". Under such a heading with no markers, each paragraph is a step. A single paragraph is split into sentences.
- "Ingredients", "You will need" and similar lists are never steps. Numbered markers win over bullets.
- Two numbered steps on one line ("1. Mix. 2. Bake.") are split.
- Prose without a heading and with fewer than two steps has no steps.

`TextReader` hands every page with text to `ReadSteps`: camera, cloud and imported pages. After that the steps work from memory, with no camera needed:

| Say | Does |
|---|---|
| "next step", "read me the next step" | The next step. Step 1 if not started. |
| "previous step", "go back a step" | The step before. On step 1, "This is the first step." and step 1 again. |
| "repeat step" | The current step again |
| "what step am I on" | "You're on step 3 of 6." |
| "how many steps", "how many steps left" | The count, or what is left |
| "steps", "first step", "go to step 3" | Jumps there |
| "next", "back", "repeat" | Move through the steps while step mode is on |

Steps are read as printed. Each one goes through `ReadSpeech`, so a dose or an amount the recognizer wasn't sure of is still withheld. A step printed without a number gets "Step 3." first. Steps use the phone's voice.

The place is kept until a different page with text is read. A failed read keeps it. Reading the same steps again also keeps it. A new read leaves step mode, so plain "next" means sentences again, but "next step" picks up where you were. The reading card shows "Step 2 of 6" with Previous step, Repeat step and Next step buttons.

## Voice routing

The phrases belong to Read text, not to the app's grammar. `ReadTextTool.handle` calls `ReadTextVoice.handle`. The ToolHub gives the open tool the words before the screen's commands. A test checks that no Read text phrase is one of the app's always-on commands. "yes" and "no" are taken only while the torch offer is waiting.

## Measured in the Simulator

iPhone 17 Simulator, iOS 27.0, Xcode 27.2. The read_page fixture was drawn at phone frame sizes. Each number is the best of 3 runs on a heavily loaded Mac.

| | 1080x1440 (.photo-like) | 1080x1920 (.high) |
|---|---|---|
| Dark check (240 px brightness) | 12 ms | 17 ms |
| Fast framing OCR (FramingAssist) | 30 ms | 37 ms |
| Accurate OCR (a read) | 554 ms | 546 ms |

`StepSplitter` on 20 recipes (about 9,900 characters) took under 1 ms. The dark check adds about 15 ms to a read; the camera's EV costs nothing. A framing check every 0.7 s keeps the CPU busy about 5% of the time.

## `.photo` or `.high`? (open question 2, reasoning only)

The Simulator has no camera, so this is reasoning, not a measurement.

- `.photo` keeps the full-resolution still (12 to 48 MP) for small print and the cloud path. Its video frames use the 4:3 photo format. On recent iPhones the video data output then gets about 1440x1080 or less, depending on the model.
- `.high` gives 1920x1080 video frames. On some models the still is limited to the video format's size, which loses the reason for having a photo fallback.
- Reading needs a sharp still more than a big frame. Most reads use the stream frame. A frame of 1080 px wide in portrait already gives body text at 30 cm about 20 to 25 px tall, which is above `FramingAdvisor.minLineHeight` (16 px). The small-print case is what the photo fallback is for.
- 4:3 also matches a page better than 16:9, so less of the frame is wasted.
- The timings above barely change between the two sizes.
- **Advice:** keep `.photo`. On a real phone, log `frame_age` and the `size=` in the `ocr` metric. If frames come in under about 1000 px on the short side, set `activeFormat` to a 4:3 format with a video size of at least 1440x1080, rather than switching to `.high`.

## Tests

`CameraAccessTests/PhoneReadingTests.swift` has 37 tests:

- The splitter on recipe and manual texts: pancakes with bulleted ingredients and a numbered method, soup without a method heading, a kettle manual with "Step N", lettered steps, inline steps, paragraphs, one paragraph, numbers alone on a line, bullets that stop at a heading, prose, a shopping list, hyphen joining, word confidence kept for withheld doses, and a speed check.
- Step navigation: the pure navigator, and `ReadSteps` through a real `TextReader` read with voice phrases. Also keeping the place, and no page or no steps.
- Phrases, with no clash with always-on commands.
- Haptics: the cue mapping, the pacer, the setting.
- Dark warning: the EV formula, hysteresis on EV and on brightness, and the full path through `TextReader` with a fake phone: the warning, the torch offer, yes, reading again, no, EV winning over a dark frame, and the glasses not being checked.
- The mirror: the word index across chunks, contrast of at least 7:1, scale, gestures, and big text by voice following the reader.
- Simulator timings.

`CameraAccessUITests/BigTextUITests.swift`: reads the fixture page on the mock glasses, opens Big text, checks the controls, pauses, presses Next, cycles the contrast and closes. With `TEST_RUNNER_SPEAKUP_SHOT_DIR` set, it saves the screenshots.

Results on the Mac (Xcode 27.2, iOS 27.0, simulator "SpeakUp PhoneUX iPhone 17", `-parallel-testing-enabled NO`). Both schemes build (CameraAccess and SpeakUp).

- Unit tests, skipping `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`: 562 passed, 0 failed.
- UI tests: `ReadAloudUITests` 2/2, `AccessibilityAuditUITests` 15/15 (they include the reading card with the new Big text button and the settings with the new row), `BigTextUITests` 1/1.

The first speech in a test run can block the main actor for over a minute in this Simulator, while TextToSpeech looks up its voices. My tests count polls instead of wall time, so that stall doesn't use up their waits.

## Shared files touched

- `A11y/Core/Announcer.swift`: `spokenWord` and the `willSpeakRange` delegate method. Additive.
- `A11y/Tools/ToolHub.swift`: `ReadTextTool` starts and stops `FramingAssist`, `handle` calls `ReadTextVoice.handle`, the help line mentions big text and steps, and `ReadTextPanel` gets `.bigTextMirrorCover()`.
- `A11y/Cloud/ReadingSettingsRows.swift`: one line, `ReadingHapticsRow()`.

## Not tried on a real iPhone

- None of the haptics have been felt on a phone. Pattern strength and the 0.7 s rhythm need a BLV tester.
- The EV thresholds, the torch settle time and the dark check on real exposure all need checking.
- `FramingAssist` with real frames: its battery cost and whether fast OCR finds a page reliably at 30 cm.
- The mirror's word highlight with VoiceOver's voice (`prefersAssistiveTechnologySettings`) on a device.
- Steps on real recipe photos. OCR may put step numbers in their own column (block), which the splitter doesn't rejoin.
