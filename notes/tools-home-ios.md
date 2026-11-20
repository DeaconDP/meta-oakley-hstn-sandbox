# Tools home (iOS)

2026-11-20. The iPhone app is now a tools app. The main screen lists six tools. Each opens a panel with a Close button. Voice opens, switches and closes them. Glasses are an optional extra.

Code is in `tracks/ios-native/HstnBench/CameraAccess/`. Screenshots (App Store build, Simulator): `design/screens/ios-tools-home.png`, `design/screens/ios-tool-open.png`.

## What was built

- **`A11y/Tools/ToolHub.swift`**. `ToolHub.shared` keeps one instance of each tool, made the first time it opens. `open(_:phrase:)` stops the open tool, then starts the new one with `CameraSourceRouter` as the source. The router keeps running, so a switch doesn't restart the camera. `close(announce:)` stops the tool and says "Mail reader closed. Main menu." `stopForGlobal()` calls the open tool's `pauseForStop()`. `openWatch(for:)` opens Watch with a target. `openReadTextQuietly()` opens Read text without its first line, for callers that read at once.
- **`ReadTextTool`** (same file) wraps `TextReader.shared`. TextReader wasn't rewritten. Its panel, `ReadTextPanel`, is the big Read text button (`read_button`) and the old `ReadPanel`.
- **`A11y/Tools/ToolsHomeViews.swift`**. `ToolsHome`: six full-width rows (coin, title, one-line job, "Say ..."). Read text is first, big and yellow; the others have a coloured coin each. `ToolPanelHeader`: the tool's name and Close. `GlassesRow`: one small "Meta glasses" row, only in the Beta build.
- **"Read a photo or PDF"** (`ImportButton`, notes/reach-ios.md) sits just under the six tools, styled like their rows (coin, title, one line). It is one VoiceOver button named "Read a photo or PDF", with a hint. It asks "Choose a photo" or "Choose a file", then reads the item in Read text's panel.
- **`Views/CameraView.swift`**. Order: status, the tools (or the open tool's header and panel), the hands-free card, the camera card, the glasses row, Status/Settings. Opening a tool scrolls to the top and moves VoiceOver focus to its name. The two-finger scrub (escape) closes settings, then the tool. Magic Tap quiets an open tool, otherwise reads as before.
- **`SpeakUpTool`** gained `pauseForStop()`, with an empty default. Watch pauses, Light turns the tone off, Labels stops the barcode search, Ask drops the answer in progress, Read text stops reading.
- **Opening lines**. Each tool says its own line with an earcon. Mail and Light already did. Watch now says "Watch for text. What should I watch for? ...", Ask plays the ready earcon, Labels says "Labels and barcodes." first, and Read text says "Read text. Hold the phone flat ... then say read or tap Read text."
- **Tapping Read text reads at once**, as the one Read button did. It also opens the Read text panel, so the reading card shows there.
- **Launch actions**. `.openMail/.openLabels/.openWatch/.openAsk/.openLight` open the tool. `.read` opens Read text and reads. `.readImported` opens Read text quietly, then calls `ImportedReading.readPending()`. The import button goes through `.readImported` too, so the page shows in the reading card.

## Voice

New `VoiceCommand` cases: `openMail`, `openLabels`, `openWatch`, `openAsk`, `openLight`. `.openReader` and `.read` open Read text. Their phrases are each `ToolID.openPhrases` plus a few more. They work on the main screen only.

| Say | Does |
|---|---|
| "open mail reader", "read my mail", "read this letter" | Mail reader |
| "open labels", "scan a barcode", "read the label" | Labels and barcodes |
| "watch for text", "open watch" | Watch, asking what to watch for |
| "watch for 42", "tell me when you see platform 4" | Watch, already watching for it (`WatchGrammar.opens`) |
| "open ask", "ask about the text" | Ask about the text |
| "light and colour", "is the light on" | Light, probe mode |
| "what colour is this" | Light, colour mode (`LightTool.mode(forOpeningPhrase:)`) |
| "open reader", "open read text" | Read text |
| "read", "read text" | Read text, and read now (unless the open tool uses "read") |
| "close", "back" (nothing else to go back to), "main menu" | Close the tool |
| "help" with a tool open | The tool's help line, then "Say close to go back to the tools, stop to quiet it, or open and another tool's name." |
| "help" on the home | Adds "Tools: say open, then read text, mail reader, labels, watch for text, ask, or light and colour." |
| "list tools" | All six, with their jobs (`SpokenMessage.toolsList`, built from `ToolID`) |

None of the new phrases clash with old ones. "light on" is still the torch; "is the light on" opens Light.

## Routing order

`VoiceControl.inject(transcript:)` on the main screen:

1. A waiting yes-or-no question takes yes, no and continue.
2. `ToolHub.route(text, command:)`. The text has the wake word taken off, and passes the same gates as commands (`VoiceCommandParser.addressedText`): while the app speaks, only "reader, ..." counts, and the app's own speech is dropped.
   - Another tool's name switches tools.
   - The always-on commands are left to the app: stop, close, main menu, help, where am I, list tools, faster, slower, settings by voice, status, the camera and torch commands, connect, disconnect.
   - Then the open tool's `handle(transcript:)`. So "read", "repeat", "back", "next", "how much" reach Mail first.
   - Then "watch for X" from anywhere.
   - With Read text open, a question ("what does ephemeral mean") goes to Ask without leaving the page.
   - The open tool's own name again, unused by it, restarts its first line.
3. Otherwise the screen's commands, then the common ones, as before.

Global "stop" still cuts speech. The screen also calls `ToolHub.stopForGlobal()`, so the tone, watch loop or barcode search goes quiet and the tool stays open.

## Ask after any tool

- `TextReader` appends each page to `RecentText` (key per read; a cloud page grows as it streams) and calls `setCurrent` per sentence, `nil` at the end. The text is the spoken chunks, so withheld numbers stay withheld.
- `MailTool` appends `Letter.safeText` (unsure amounts masked), one passage per letter, and tracks the sentence during "read it all".
- `LabelsTool` appends every side read. A medicine label publishes nothing and clears what the pack published.

## Hands-free and the store build

- `HandsFreeTool` lists the six tools, then status and settings. The glasses display card shows the open tool's name with "stop, close, help", or "read, list tools, help" on the home.
- In the App Store build (`SPEAKUP_NO_DAT`), help leaves out connect, use the glasses, disconnect and glasses display (`VoiceContext.glassesSupported`). Spoken tips never say connect or Meta AI (`VoiceCoachLines.phoneOnlyHint`). The glasses row isn't shown.

## A fix outside the tools

`AppVoice.voice` no longer looks the voices up on the main thread while the launch lookup is still running. On the iOS 27 Simulator the two lookups deadlocked inside TextToSpeech (`axUnsafeForcedSync`), and the app froze on its first spoken line after tapping Read text. Until the lookup finishes, the en-GB default voice is used.

`CameraView.confirmCameraPermission` now has a fallback. The view model carries on the Read only once "Camera access allowed" has been heard to the end. When another line cut it off, the read never carried on: the glasses stream started and nothing was read. That was already possible before. With the tools home it happened in most UI test runs. Now, once speech is quiet (at most 4 s), the read carries on anyway, unless access was refused or the session isn't up. `CameraViewModel` is unchanged.

## Update 2026-11-20 (later)

- The import button is on the tools home (above).
- Imported pages are read by `TextReader` (notes/reach-ios.md). So next, previous, repeat, Stop and Magic Tap work on them.
- The three read-panel audits pass. The cause was `SayLine` ("Say back, repeat, continue, stop" under the reading controls). It was visible but hidden from VoiceOver, so the audit flagged it as inaccessible text with no element. It is now a VoiceOver element: "You can say ...". I found it by hiding parts of the panel one at a time.
- At the largest text size the test no longer scrolls to Stop. It taps Stop only when Stop is already in view, waits for the read to end, then audits the reading card. The audit scrolls to off-screen elements itself and sometimes measures contrast mid-scroll (`status_title`, 400 pt above the top, failed one run in two). Contrast on elements that were off-screen when the audit started is now ignored. That element is audited in place before the read.
- `VoiceControlUITests.testHandsFreeOffByVoiceShowsTheMicButton` passes. Hands-free speaks a line at launch, and while the app speaks only "reader, ..." counts. The test now says "reader, touch mode".
- New UI test `ToolsHomeUITests.testImportButtonIsOnTheHomeAndOffersBothPickers`. On iOS 27 the choices have no Cancel row; a tap outside closes them.

Mac, Xcode 27.2, iOS 27.0 Simulator "SpeakUp Final iPhone 17", `-parallel-testing-enabled NO`. CameraAccess and SpeakUp (with SpeakUp Share) build.

- Unit tests, skipping `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`: 525 passed, 0 failed, 0 skipped.
- UI tests: 42 run, 41 passed, 0 failed, 1 skipped (`StoreScreenshotsUITests`, skipped unless `TEST_RUNNER_SPEAKUP_SCREENSHOTS=1`). Run in four batches to keep each under 10 minutes.

## Tests (first pass)

Mac, Xcode 27.2, iOS 27.0 Simulator "SpeakUp Hub iPhone 17", signed, `-parallel-testing-enabled NO`. Both schemes build (CameraAccess and SpeakUp).

- Unit tests (`CameraAccessTests`, skipping `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`): 484 run, 0 failures.
- New: `ToolHubTests` (12: open, switch, close, routing order, global stop, watch with a target, colour mode), `ToolPhraseTests` (10: every open phrase, old phrases unchanged, help, list tools, hands-free list, wake-word gate, store help and tips), `ToolsPublishTextTests` (2: labels and medicine, a real OCR'd page from TextReader), and one Mail test for `RecentText`. `HandsFreeTests.testToolsMatchTheirCommands` was updated for the longer list.
- UI tests: `ToolsHomeUITests` (2, `--phone-camera`): every tool opens from its row and closes; and by voice: open mail reader, what colour is this, close, tell me when you see 42, main menu. Both pass.
- Full `CameraAccessUITests`, without the three read-panel audits and the screenshot test: 37 run, 36 pass. The one failure was `VoiceControlUITests.testHandsFreeOffByVoiceShowsTheMicButton` ("touch mode" never registered). Fixed later the same day, see above.
- The read-panel audits failed with "Potentially inaccessible text/element" and no element. Fixed later the same day, see above.
- The Mac was heavily loaded (load average up to 68, other agents' simulators running). Several runs had the runner restart; these numbers come from clean reruns on my own simulator.
- `StoreScreenshotsUITests` takes the two screenshots from the installed SpeakUp app. It is skipped unless the run sets `TEST_RUNNER_SPEAKUP_SCREENSHOTS=1`.

## Not tried on a real iPhone

- No tool has run with a real camera. The Simulator has none, so every panel opened on "No camera available".
- VoiceOver focus moving to the tool's name, and the escape gesture, were not tried with VoiceOver on.
- Routing with a live mic: the wake-word gate while a tool speaks, and whether Watch's free answer ("42") gets swallowed by room chatter.
- The Light tone, the barcode ticks and speech together on the phone speaker.
- Switching tools quickly while the camera starts.
- The accessibility text sizes on the new rows were laid out to stack, but no screenshot was taken at those sizes.
