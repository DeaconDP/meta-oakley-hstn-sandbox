# Watch for text and Ask about the text (iOS)

2026-11-20. Two Android tools ported to the iOS app, phone first. Glasses are optional: both tools take frames (Watch) or text (Ask) the same way whichever camera is in use. Each is a `SpeakUpTool` (`A11y/Tools/SpeakUpTool.swift`, unchanged).

Code:
- `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Watch/`
- `tracks/ios-native/HstnBench/CameraAccess/A11y/Tools/Ask/`
- Tests: `CameraAccessTests/WatchForTextTests.swift`, `CameraAccessTests/AskAboutTextTests.swift`

No shared file was changed. Nothing is wired into the app yet; the integrator does that (see "For the integrator").

## Watch for text

"Tell me when you see 42", "watch for platform 4", "find Boots". It keeps reading the camera and says when the target appears and which side it's on, until told to stop.

| File | What it does |
|---|---|
| `HeardText.swift` | Android's `Phrases`: light and normalized forms of a transcript, filler and address dropped, plus a small NSRegularExpression wrapper (Swift's Regex has no lookbehind). Ask uses it too. |
| `WatchTarget.swift` | What was said, as tokens: numbers, codes ("12B"), words. Spoken numbers ("forty two", "one oh one", "platform three"). Bus noise words dropped. |
| `WatchTextMatcher.swift` | Matching rules, the position in the frame, near misses. |
| `WatchSightingTracker.swift` | Two-of-four confirmation, gone and back, near-miss throttling, "where is it", left / ahead / right, close / far, covered / dark watcher, pace watcher, the covered / dark check. |
| `WatchGrammar.swift` | `opens(_:)` for "watch for X" from anywhere (with the free target), and `parse(_:)` for commands inside the tool. |
| `WatchRecognizer.swift` | Vision, `.fast` level, no language correction, every line with its box. The covered / dark check runs first on a 48x72 grey grid. |
| `WatchTool.swift` | The tool: frame loop, speech, earcons, haptic, tick, watchdogs. |
| `WatchPanel.swift`, `WatchWording.swift` | The phone panel and every spoken line. |

What the user hears is the same as on Android (notes/watch-for-text.md): the start line, "42, on your right." (", close" / ", far off"), "42, gone.", "I see 24, not 42.", "where is it", "what are you watching for", stop / carry on, ticks off / on / every N seconds, and spoken problems (covered, too dark, no pictures for 10 s, OCR failing 3 times, OCR slower than one look every 3 s).

Differences from Android:
- **Phone first.** "Ahead" is centred at x = 0.5 for the phone camera. The glasses keep Android's 0.53 (their camera sits front left). Covered and no-pictures lines name the phone's camera or the glasses.
- **Haptic on the phone.** A success notification haptic plays with the sighting earcon.
- **Earcon.** iOS has no FOUND earcon, so a sighting uses `attention` (the earcon ROADMAP reserves for alerts). The alive tick is `working`.
- **Frames.** It polls `latestReadFrame` every 500 ms and skips frames it has already read or that are over 2 s old. Android subscribes to a 2 fps stream. `prepareStreamForReading()` starts the camera; `.unavailable` is said once.
- **Fast OCR.** Vision's fast level with language correction off (it would "fix" 42A and B00TS). Read text keeps the accurate level.
- **Silence line.** The first start and help also say "I can miss things, so silence doesn't mean it isn't there", per ROADMAP > "Awareness, not safety". No wording says safe, clear or cross; a test checks this.
- **Typing.** The panel has a field to type the target, for people who'd rather not speak.
- **Global stop.** The tool has `pause()` for the app's own "stop" / "pause". "Carry on" or "continue" restarts it when it reaches the tool while stopped.

## Ask about the text

Questions about what was just read, answered on the phone. Same kinds as Android (notes/ask-about-the-text.md): define (with "more"), "did you mean" for misheard words (with "no"), spell it, who is, what is, recap (this session, or last time), find (with "next"). Every answer is a quote from the text or a dictionary sense.

| File | What it does |
|---|---|
| `RecentText.swift` | The store tools publish to. Text only, in memory, bounded. Keeps the last ~3,000 heard characters in UserDefaults for "what happened last time". |
| `AskGrammar.swift` | Question kinds, gated follow-ups (`AskFollowUps`, 2 minutes), `isQuestion(_:)` for partial transcripts. |
| `AskTextTools.swift` | Sentences, read-so-far, sound-alike words, mentions, search, recap. |
| `WordNetDictionary.swift` | Reads the dictionary file; `AskDictionaryLoader` loads it once, lazily, off the main actor. |
| `AskLemmatiser.swift`, `AskWordLookup.swift` | Inflections, British / American spellings, which word was meant. |
| `AskAnswerer.swift` | Answers a question. Port of `OnDeviceAsk`. |
| `AskOnline.swift` | Optional OpenAI answer for open questions. |
| `AskTool.swift`, `AskPanel.swift`, `AskWording.swift` | The tool, its panel, and every spoken line. |

Differences from Android:
- **Cloud.** OpenAI instead of Claude, because the iOS app already has an OpenAI key in Settings. It reuses `OpenAIKey` and `KeychainKeyStore` for the key, and `OpenAIClient`'s URL, host check, model, session and error mapping. `OpenAIClient` has no text-question request and its request builder is private, so the one request is built in `AskOnline.swift`.
- **When it goes online.** Only open questions, only when asked, only if a key is set, never under test. "Asking online." is said first. Sent: the question and the text heard so far (last 12,000 characters). Never an image. `store: false`. A reply of "The text doesn't say." is spoken as "The text doesn't say." It has never made a live request.
- **Carry-on hint.** Android adds "Say carry on to keep reading" when the book reader was paused for a question. Here it is opt-in (`offerCarryOn`), because Ask is its own tool and Read text doesn't pause for questions yet.
- **Last session.** Android keeps the tail next to the book's bookmark. Here `RecentText` keeps it in UserDefaults (`ask_recent_text_tail`), from any tool, on every append and every current-sentence change.
- **Typing.** The panel has a question field and buttons for More, Spell it, "No, the word I said", and Recap.

### Dictionary file and licence

- Bundled: `Tools/Ask/wordnet.wnask`, byte-for-byte the Android asset (sha256 `db30ee83…34e4`). 3,458,889 bytes, gzip'd text. The iOS reader parses the same format, so the Android script `tracks/android-native/HstnBench/scripts/build_ask_dictionary.py` rebuilds it for both.
- Content: Princeton WordNet 3.0. 117,659 definitions, 147,306 lemmas, 5,947 irregular forms. Examples and relations are dropped.
- Licence: WordNet 3.0's BSD-style licence allows use, copying and redistribution, provided the copyright notice and disclaimer go with every copy. The notice is the file's own `#` header, and `Tools/Ask/WordNet-3.0-LICENSE.txt` is bundled next to it. The panel shows "Definitions from WordNet 3.0, Copyright 2006 by Princeton University. All rights reserved. Used under the WordNet licence." The name Princeton must not be used in advertising.
- Size and loading: 3.46 MB in the app, well under the 15 MB budget. It is gunzipped (Compression framework, raw DEFLATE after the gzip header) and indexed the first time Ask opens, off the main actor. About 10 MB in memory. On the simulator (debug build, a heavily loaded Mac) loading took 109 ms and lemmatising one word took 0.06 ms.
- The file sits in the synchronized `A11y` group, so it is copied to the app bundle with no project change. Checked in the built app.

## Tests

Run on the Mac, simulator "SpeakUp Watch iPhone 17" (iOS 27.0), Xcode 27.2, scheme CameraAccess, unit tests only.

- `WatchForTextTests`: 35 tests, all pass. Ports of WatchMatchingTest, WatchTrackerTest and WatchGrammarTest, plus the phone's centred camera, the covered / dark check, the wording, `HeardText`, and the openers that carry the free target.
- `AskAboutTextTests`: 43 tests, all pass. Ports of AskGrammarTest, DictionaryTest, TextToolsTest and OnDeviceAskTest on the real bundled file and the same fixture pages; the OpenAI request (no image, only the text and question) and canned replies (answer, "doesn't say", refusal, 401, 429, bad JSON, network error); RecentText (per tool, bounded, replace by key, latest, the tail kept for next time).
- Whole unit test target: 337 tests, 1 failure. The failure is the known one, `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay` ("The display didn't start."). After a last wording change, the two new classes were run again: 78 tests, 0 failures.
- No compiler warnings in the new files (Swift 6, strict concurrency).

The Android tests that need Android's GlobalGrammar or book reader grammar weren't ported; the iOS global grammar is the integrator's.

## For the integrator

- `WatchTool(defaults: UserDefaults = .standard, haptic: (@MainActor () -> Void)? = nil)`
  - `WatchGrammar.opens(_ transcript:) -> WatchOpenRequest?` spots "watch for X" anywhere; open the tool and call `watch(for:)` with `request.target` if there is one. It's kept until `start(source:)`.
  - `pause() -> Bool` for the app's "stop" / "pause" while watching. `isBusy` is true while watching (don't answer room chatter with "didn't get that").
- `AskTool(recentText: RecentText = .shared, loader: AskDictionaryLoader = .shared, online: (@MainActor () -> (any AskOnline)?)? = nil)`
  - `AskGrammar.isQuestion(_:)` spots a question while another tool is open; `ask(_:offerCarryOn:)` answers it. `preferredSource` picks whose text to ask about.
- `RecentText.shared`
  - `append(_ text: String, source: ToolID, key: String? = nil)`: a page, a letter. Same key replaces.
  - `setCurrent(_ sentence: String?, source: ToolID)`: the sentence being read; nil when done. Only text up to it counts.
  - `setTitle(_:source:)`, `clear(source:)`, `snapshot(source:)`, `latest()`, `forQuestion(source:)`, `previousSession`.
  - Thread-safe. Text only.
- TextReader should call `append` when it starts reading a page and `setCurrent` per sentence.

Suggested changes to shared files (not made):
- `SpeakUpTool`: an `isBusy` (or "swallows chatter") property, and a `pause()` / `resume()` pair for the global stop and carry on. Watch has both already.
- `Earcon`: a `found` earcon for sightings, so `attention` stays for alerts.
- `OpenAIClient`: a public text-only `answer(instructions:input:)` request, so Ask doesn't build its own.
- Move `HeardText` to `A11y/Tools/` (or Voice) if other tools port Android's `Phrases`.

## Not done / not verified

- Not tried on a real iPhone, and not on glasses. All results are unit tests on the simulator.
- The Watch frame loop, Vision fast OCR on real signs, the haptic, and the panels have not run in the app; nothing opens the tools yet.
- Ahead / left / right on the phone assumes the user points the phone where they face.
- OCR speed on a phone is unmeasured. Android measured about 61 ms a frame with ML Kit.
- The OpenAI path has never made a live request.
- Misheard-word matching is tested on invented mishearings, not on recordings.
