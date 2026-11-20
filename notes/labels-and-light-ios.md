# Labels and barcodes, Light and colour (iOS, phone first)

2026-11-20. Two Android tools ported to the iOS app as `SpeakUpTool`s. The Android notes are `notes/labels-and-barcodes.md` and `notes/light-and-colour.md`. The rules, thresholds and spoken lines are the same unless listed under "Differences".

Code:
- `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Labels/`
- `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Light/`

Tests:
- `CameraAccessTests/LabelsToolTests.swift`
- `CameraAccessTests/LightToolTests.swift`

Update 2026-11-20: food check (your allergens, dates against today, cooking steps) was added to the Labels tool. See `notes/food-check-ios.md`.

**Nothing here has been tried on a real iPhone.** It builds, and the pure logic passes its unit tests in the Simulator. The Simulator has no camera, so the barcode search, OCR on real labels, the probe tone and the exposure lock have not run end to end.

## What was built

### Labels and barcodes (`LabelsTool`)

- Opening the tool starts a barcode search on the camera's frames, 3 a second.
- Barcodes are decoded with Vision `VNDetectBarcodesRequest` on the phone.
- When nothing decodes, `BarcodeHint` looks for bars in 48 rows of a 480 px greyscale copy. It plays geiger ticks: 1 to 4 per frame, 500 to 1400 Hz, more and higher as the bars get bigger and more central.
- With no bars in view, the working earcon plays every 2 s, so the search is never silent.
- After 5 s with no bars: "Turn it slowly. Barcodes are usually on the back or bottom."
- After 4 frames with bars that don't decode: "I can see a barcode. Bring it a little closer…" or "Hold it steady."
- After 15 s it says it couldn't find a barcode and reads the label instead.
- A decode plays the done earcon and a success haptic. QR codes are described, never opened (domain only, Wi-Fi name without the password).
- "Look it up" sends the barcode number, and nothing else, to Open Food Facts. It uses an ephemeral URLSession: no cookies, no shared cache. Found products are cached in Caches/labels_products, so a second lookup works offline. Every failure is spoken: not found, offline, other errors.
- "Read the label" takes a full-resolution photo (the latest frame if the photo fails). It runs the existing `TextRecognizer` and `FramingAdvisor`. Too dark, blurred, too small and no text each get a spoken hint. On the phone, too dark suggests "torch on".
- Quick jumps take a fresh photo and search every side read so far, newest first:
  - dates (best before, use by, expiry; said as dates; passed or today);
  - ingredients (from Open Food Facts if the label has none);
  - cooking instructions;
  - allergens, and "does it contain nuts" (never "no" because a word wasn't found);
  - the product's name.
- Medicine: the name only, with strengths stripped, and the expiry date only when every line it came from was read with at least 0.8 confidence, always with "Please have a pharmacist or a trusted person check the date". Dose questions are always declined, on any label. A medicine label's text is never shown on screen.

### Light and colour (`LightTool`)

- Light probe (default): frames 4 a second, 96 px wide. Centre-weighted luminance drives a continuous tone. The pitch is logarithmic: one stop of light is a third of an octave, 220 to 1760 Hz. It is smoothed (alpha 0.4, dead band 0.004) and glides (60 ms) without clicks.
- "How bright is it" says dark, dim, normal, bright or very bright, then "That's the camera's estimate, so it's only relative."
- "Where's the light" says brighter to the left, to the right, straight ahead, or about even.
- Blinking: a 12x20 cell grid over the last 20 frames. It says "It's blinking." when blinking starts, at most once every 10 s, and answers "is it blinking".
- If no frame has arrived for 2 s, the tone goes silent.
- Colour: a 160 px wide frame. The centre patch is 20 % of the width. White balance comes from the surround (grey world plus white patch, at 75 %). OKLab two-means splits two colours, and the colour is named from 39 everyday names. The answer is hedged in dim or tinted light, abstains when too dark or with glare, and gives two colours for stripes. A light haptic plays when a colour is named.
- Exposure lock: on the phone camera, while the probe runs, exposure and white balance are locked 0.8 s after the camera is ready. They unlock when the probe stops, in colour mode, and when the tool closes. This is `PhoneExposureLock`, through `AVCaptureDevice.default(.builtInWideAngleCamera, .video, .back)`, the same shared device object `PhoneFrameSource` uses. **`PhoneFrameSource` was not changed.** It only sets focus, so the two don't overlap. With the glasses there is no lock (DAT has no exposure control), as on Android.

### Audio

`ToolTonePlayer` (in `Tools/Light/`) plays the probe tone and the geiger ticks on its own `AVAudioEngine`:
- an `AVAudioSourceNode` for the gliding sine, with a little second harmonic so 220 Hz is heard on the phone speaker;
- an `AVAudioPlayerNode` for ticks, rendered with `EarconSynth`.

It coexists with `A11yAudioSession` like this:
- All engine work runs on `A11yAudioSession.shared.queue`.
- While a tool holds the player, it takes the session's speech hold (`beginSpeech()`/`endSpeech()`). That keeps the session active in its playback category, so the idle check doesn't deactivate it under the tone.
- Side effect: other apps' audio is ducked while the probe or the barcode search runs.
- Earcons and speech mix with the tone. The tone doesn't duck under speech, as on Android.

### Haptics

`LightLabelKit.haptic`:
- success when a barcode is found;
- a medium tap when a colour is named;
- error when something fails.

They are optional: off when UserDefaults `tools.hapticsEnabled` is false, and the system haptics switch also turns them off. There is no settings row yet (that would touch shared files).

### Panels

`LabelsPanel` and `LightPanel`:
- large Dynamic Type text, the theme's fonts and colours;
- `ChunkyButtonStyle` buttons (60 pt) that do exactly what the voice commands do;
- VoiceOver labels and identifiers (`labels_*`, `light_*`);
- in colour mode, the swatch's VoiceOver label is the spoken sentence;
- for medicine, only the medicine banner with the name.

No camera preview is in the panels. The integrator can put the existing preview above them.

## Differences from Android

- Vision instead of ML Kit for barcodes. Vision reports UPC-A as EAN-13 with a leading 0. A product code with a bad check digit is dropped as a misread.
- The search runs at 3 frames a second, not 2, because Vision on the phone is quick.
- OCR is Apple Vision through `TextRecognizer`. Line confidence for the medicine date rule is the lowest word confidence on the line.
- There is no `ImageCheck`. `FramingAdvisor`'s verdicts give the hints: too dark, blurred, too small, no text. Covered, glare and hand-in-the-way are not detected separately.
- Wording is for the phone: "Hold it in front of the camera", "a hand's length from the phone", "Turn the phone slowly". When too dark, the phone suggests "torch on".
- The exposure lock covers the probe only. Android locked exposure for the whole tool. Colour wants a well exposed object, so colour mode unlocks and waits 0.6 s.
- The grammar normalises like iOS's `VoiceCommandParser` (apostrophes closed: "whats", "wheres") and drops filler anywhere, like Android's `Phrases`.
- The light tool also takes "quiet", "pause", "carry on" and "resume" as tone off and on, because there is no `onGlobal` hook on iOS.
- There is no "ask about the text" publishing (RecentText), so nothing is published, medicine or not.
- The `User-Agent` is `SpeakUp-LabelReader/0.1 (iOS; …)`.

## Tests

The CameraAccess scheme unit tests ran in the Simulator ("SpeakUp Labels iPhone 17", iOS 27.0) on the Mac.

Result: 343 tests, 342 passed, 1 failed. The failure is the known one, `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`. The build has no warnings in the new files.

The 84 new tests all pass.

Labels (54), ported from Android's `LabelDatesTest`, `LabelTextTest`, `MedicineExpiryTest`, `BarcodeHintTest`, `LabelsGrammarTest` and `OpenFoodFactsTest`:
- `LabelDatesTests` (14): every date format; day first; nearest year; best-before-end; passed and today; "see top"; no false dates; `CivilDate` days.
- `LabelTextTests` (12): sections; name; allergens (yes, may contain, free from, never "no", look-alikes, product data, summary); medicine detection; name without strength.
- `MedicineExpiryTests` (5): a clear date gets the reminder; an unsure line gives no date.
- `LabelsToolMedicineTests` (5): on the tool itself, medicine is detected and its text isn't kept; a clear date is said with no dose words; an unclear one isn't said; food dates are said plainly; dose questions are declined.
- `BarcodeHintTests` (6): drawn EAN-13 bars found where they are; closeness and ticks; text and paper aren't bars; check digits; QR descriptions.
- `LabelsGrammarTests` (7): every command and synonym; doses always caught; other tools' and global phrases left alone; normalisation.
- `OpenFoodFactsTests` (5): inline replies (no recorded fixtures); not found and garbage; quantities and tags; the URL holds only the barcode; the cache, offline, HTTP 503 and non-digit codes with a fake fetch.

Light (30):
- `ColourReaderTests` (15), ported from `ColourReaderTest`: OKLab reference values; 23 named patches; light/dark modifiers; between families; red under warm light; casts; white balance; too dark; dim; black; glare; muted; stripes; background; swatch.
- `LightProbeTests` (15), ported from `LightProbeTest`: pitch is monotonic and logarithmic; smoothing; levels; centre weighting; brightest side; blinking (LED at 1 Hz, every frame, steady, switched once, moving camera, flashing room, slow fade); the grammar; the opening mode.

The synthetic frames use a small seeded generator in place of Kotlin's `Random`, so the noise differs from Android's. The same thresholds pass.

## For the integrator

- `LabelsTool(productSource: any ProductSource = OpenFoodFactsSource(), today: @escaping () -> CivilDate = { CivilDate.today() }, tones: ToolTonePlayer = .shared)`
- `LightTool(tones: ToolTonePlayer = .shared, exposureLock: PhoneExposureLock = PhoneExposureLock())`
- `LightTool.openingMode`: set it before `start` from the opening phrase, with `LightTool.mode(forOpeningPhrase:)`. "What colour is this" opens colour mode.
- Global commands get transcripts first, so some tool phrases never arrive:
  - "read" and "read it" go to Read text;
  - "try again" is reconnect;
  - "again" is repeat;
  - "stop" stops speech but not the tone.
  Suggested: let the open tool see the transcript before the global grammar (Android's order), or route global "stop" to `LightTool.pauseTone()` and the tools' `stop()`.

Suggested `SpeakUpTool` changes (not made):
- `start(source:request:)` with the opening phrase, so a tool can pick its mode;
- an `onGlobal(_ command:) -> Bool` hook (stop, repeat, carry on);
- a hint for whether the tool needs the camera kept running.

Suggested `A11yAudioSession` change (not made): a hold that keeps the session active without ducking, for continuous tool audio. The tools use the speech hold for now.

## Not tried / limits

- Not run on a real iPhone. Not checked:
  - barcode decoding and geiger ticks on real packs;
  - OCR of real labels;
  - the probe tone through the speaker;
  - the exposure lock's effect;
  - the 0.8 s settle before the lock;
  - CPU at 4 fps on the phone.
- `latestReadFrame` converts the full camera buffer to an image on the main thread at 4 fps (as Read text does once per read). That cost isn't measured.
- The thresholds come from Android's synthetic tests and are not tuned on iPhone frames.
- All the Android limits still apply: medicine detection is keyword-based and English only; US month-first dates only when day-first is impossible; Open Food Facts data can be wrong; mains flicker isn't detectable.
