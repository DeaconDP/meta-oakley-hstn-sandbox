# Voice from start to finish (iOS)

Goal (set 2026-11-20): a blind user can run SpeakUp on iPhone by voice alone, from launching it to ending the session. No step should need a tap, and where iOS makes a tap unavoidable, the app says so out loud and names a voice way round it.

Roadmap entry: ROADMAP.md > Voice from start to finish. Tasks: TODO.md > Voice from start to finish.

## Where we are (2026-11-20)

The walkthrough below assumes VoiceOver is on and the phone camera is used.

| Step | Today | Gap |
|---|---|---|
| Launch | Icon, Siri "Open SpeakUp", 10 App Shortcuts, `speakup://handsfree` | No Control Center / Action button control (no widget extension). "Hey Meta, start SpeakUp" not wired |
| First run | With VoiceOver: hands-free turns on, voice setup ("phone", "connect", "continue") | Without VoiceOver: hands-free stays off, the welcome is silent (`OnboardingView.swift:278-281`), and mic/speech access is never asked during setup. notes/a11y-onboarding.md:72 says it is asked there, so the note or the code is stale |
| Permissions | Spoken line before mic/speech alerts; camera line on first read | System alerts need a tap. Nothing tells a voice-only user about Voice Control's "Tap Allow" |
| Tools home | Status line, tools by name, "help", spoken tips | No bare "switch to \<tool>" |
| Tools | All six tools and Read text's paging work by voice | — |
| Import | Button, share sheet, Files, link | No voice way in. Choice dialog, photo picker and file picker are touch-only |
| Settings | Rate, detail, hands-free, glasses display, camera, torch | Voice choice, earcons, tips are touch-only. No undo |
| Glasses | Spoken connect, lost, fallback | Meta AI handoff and glasses permissions happen in another app, by touch |
| End | "close the app" says "Apps can't close themselves on iPhone…" | No goodbye. Mic, glasses session and audio stay up until the app is backgrounded. "goodbye", "end session" and bare "exit" aren't recognised. No "welcome back" on return |

## Platform limits (research 2026-11-20)

- **No self-termination.** Apple: "There is no API provided for gracefully terminating an iOS application… Do not call the `exit` function" ([QA1561](https://developer.apple.com/library/archive/qa/qa1561/_index.html)). `UIApplication.suspend` is private (Guideline 2.5.1). So "end the session" means: say goodbye, stop the mic, glasses session and audio, and leave the app idle. The user leaves with Siri "Go home", Voice Control, or the lock button.
- **No mic while locked by default.** Background audio for recording is a likely 2.5.4 rejection unless it's a clearly described feature. Locking or backgrounding the phone ends the session, which already matches the code (`CameraViewModel.swift:389-394`).
- **System permission alerts can't be answered with Siri.** Voice Control's "Tap Allow" probably works but needs a device check. Ask at first need, with a spoken pre-prompt.
- **Launch without the icon:** Siri "Open SpeakUp" needs nothing. App Shortcuts are done. One `ControlWidget` with an `OpenIntent` covers the Action button, Control Center and the Lock Screen (iOS 18+, needs a widget extension, and the intent must be in both targets). Back Tap works through Shortcuts already.
- **Glasses (DAT):** "Hey Meta, start \<app>" launches a DAT app (dev/beta). `DeviceSession.stop()` ends a session cleanly. The app can receive the double tap and capture-button hold (beta). A single tap and tap-and-hold belong to Meta. Glasses-side Speech is beta and stops after about a minute; keep `SFSpeechRecognizer` on the HFP mic for production.

## Plan

Order: J1 and J2 first (small, visible), then J3 and J4 (the real dead ends), then J5 and J6, then J7 to prove it.

### J1 End the session by voice (M) — built 2026-11-20

**What was built:**
- **Phrases:** "goodbye", "bye", "end session", "end the session", "close the app", "quit", "exit the app" and "quit speakup" all mean `.closeApp` (`VoiceCommand.swift`). Bare "exit" doesn't, because Watch looks for it as a word.
- **`VoiceControl.endSession(teardown:)`:**
  1. Clears any waiting question and push to talk.
  2. Sets `isSessionEnded`. This flag isn't saved, and the listener rules turn it into `.paused(.sessionEnded)`, so the mic stops before anything is said.
  3. Says "Goodbye. I've stopped listening, and the camera is off. Lock the phone or swipe up to leave. Open SpeakUp again to carry on." with the `.disconnected` earcon.
  4. Runs `teardown` once the line has finished or been cut off.
- **Late phrases are dropped:** while the session is ended, `inject` ignores transcripts, in case a recognizer that was still stopping delivers one last phrase.
- **On the main screen** (`CameraView.handleVoice`), the session ending:
  - closes settings and the open tool;
  - stops the reader;
  - stops the camera stream (`router.stopReadingStream()`);
  - stops the working ticks;
  - ends the glasses session after the goodbye, so the audio route doesn't switch mid-sentence. `endSession()` was added to `GlassesCamera`; `NoGlassesCamera` does nothing.
- **On setup and the home screen**, the session ending is handled in `performCommon`: the mic stops and the goodbye is said.
- **Starting again:** coming back to the app (`noteBackground(false)`), the indicator's new **Start again** button, or the mic button in touch mode all call `resumeSession()`. Hands-free then says "Hello again. I'm listening. Say help at any time." (with "reader," when the mic can hear VoiceOver), and the listening cue plays when the mic opens.
- **The voice indicator** shows "SpeakUp has stopped", "Tap Start again, or leave the app and come back.", and a Start again button.

**Not done:**
- Android's rule that "close" in the menu ends the session. On iOS, "close" still only goes up one level.
- Turning the audio session off explicitly. It goes idle by itself once nothing is speaking (`A11yAudioSession`).

**Tests** (Mac, Xcode 27.2, iOS 27.0 Simulator "SpeakUp J1 iPhone 17", `-parallel-testing-enabled NO`). Unit tests, skipping the known display mock test: 533 run. 531 passed. The two failures were:
- `testListToolsAndCloseTheApp`: it injected a phrase after the goodbye, which is what led to the late-phrase guard above;
- `ViewModelIntegrationTests.testVideoStreamingFlow`, a 10 s timeout on a heavily loaded Mac.

Rerun of the voice, grammar, ToolHub and integration suites: 68 run, 0 failed. UI tests `ToolsHomeUITests` and `VoiceControlUITests`: 11 run, 0 failed. The SpeakUp (store) scheme builds.

New tests:
- `testAnEndedSessionDoesNotListen`
- `testGoodbyeStopsTheMicBeforeSayingSo`
- `testTeardownRunsEvenWhenTheGoodbyeIsCutOff`
- `testComingBackAfterGoodbyeListensAgain`
- `testStartAgainAsksForTheWakeWordWhenTheMicHearsVoiceOver`
- `testMicButtonStartsAgainAfterGoodbye`
- `testBareExitDoesNotEndTheSession`
- `testAnEndedSessionOffersStartAgain`

**Not tried on a real iPhone:** the goodbye over the glasses' speakers, ending the glasses session after it, and whether the main screen says anything about the glasses when their session stops.

**Plan as written:**
Match Android's rule (notes/tools-layer.md:144-150): "close" always goes up one level, and "close the app", "goodbye", "end session", "quit", "exit the app" always end the session.
- Phrases: `VoiceCommand.swift:230`. Test bare "exit" against `.close` (":228").
- Replace `VoiceControl.swift:474-475`. Route through `CameraView.handleVoice` (`CameraView.swift:332`) so the glasses link is reachable. Steps:
  1. say goodbye and wait for it to finish;
  2. stop the listener (`stopListener`, :674) and drop the glasses mic (`detachGlasses`, :553);
  3. call `CameraViewModel.endSession()` (:179);
  4. stop ticks (`EarconPlayer.stopAllWorkingTicks`);
  5. let the audio session go idle.
- Goodbye line, e.g. "Goodbye. SpeakUp has stopped listening. Lock the phone or say 'Hey Siri, go home'."
- Use a non-saved "ended" flag, not hands-free off, so the user's setting survives. While ended, the screen shows one big "Start again" button, and Siri "Open SpeakUp" or a shortcut also restarts.
- On return to the foreground, clear the flag and say a short "SpeakUp is listening. Say help any time." with the listening earcon.
- Tests: `VoiceTests.testListToolsAndCloseTheApp` (:930) changes. Add parser cases in `VoiceCommandParserTests` and a lifecycle test (goodbye finishes before the mic stops, nothing heard after).

### J2 Grammar gaps (S) — built 2026-11-20

**What was built:**
- **"switch to \<tool>" and "go to \<tool>":** whole phrases from `ToolID.switchPhrases`, added to `openPhrases` (`SpeakUpTool.swift`). Each tool has a few names: "switch to read text" / "the reader", "mail reader" / "my mail", "labels" / "barcodes", "watch for text", "ask", "light and colour" / "color" / "light", "reminders" / "medicine log". "switch to" is not a filler word. So "switch to read text" opens Read text (`.openReader`) and doesn't read, "switch to the phone" and "switch to the glasses" still change the camera, and "go to step 3" is still Read text's. ToolHub's step 3 opens the named tool even when another tool is open, before that tool hears the words.
- **Import by voice:** four new commands, main screen only (`VoiceCommand.importCommands`):
  - `.readPhoto`: "read a photo", "read a picture", "read a screenshot", "read a photo from my library", "choose a photo", "open my photos"...
  - `.readFile`: "read a file", "read a PDF", "read a document", "choose a file", "open my files"...
  - `.readPhotoOrFile`: "import", "read a photo or PDF".
  - `.readShared`: "read what I shared". It reads what the share sheet left; if nothing is waiting, it says "Nothing shared is waiting." and offers the choice.
- **Routing:** they are in `ToolHub.alwaysGlobal`, so an open tool never hears them. `CameraView.openImportByVoice`:
  1. closes settings, the reader and the open tool, quietly;
  2. says one line (`SpokenMessage.importOpening`), e.g. "Opening your photos. Pick one and I'll read it. The picker works with VoiceOver or Voice Control.";
  3. once the line has finished or been cut off, parks a request in `ImportPicker` (new, `A11y/Import/ImportPicker.swift`).
  `ImportButton` watches `ImportPicker.pending` with `initial: true`, because the button only appears once the tool has closed. It opens the Photos picker, the Files picker or the "Choose a photo / Choose a file" dialog. Saying "read a photo" while the dialog is up closes it first. A request expires after 15 s. While a glasses update is needed (no import button on screen), it says the status instead. The pickers themselves stay the system's.
- **Help:** the camera help offers "read a photo". "list tools" ends with "To hear a photo or PDF from your phone, say read a photo, or read a file."
- Hands-free and the toolbox use the same grammar. With push to talk, the press counts as the wake word.

**Not done:** "read my latest photo" / "read my last screenshot" with PhotoKit. That needs photo library access and its own pre-prompt (J4).

**Tests** (Mac, Xcode 27.2, iOS 27.0 Simulator "SpeakUp J1 iPhone 17", `-parallel-testing-enabled NO`):
- Unit tests, skipping the display mock test: 743 run, 0 failed. The count includes other branch work in the tree.
- UI tests `ToolsHomeUITests` and `VoiceControlUITests`: 13 run, 0 failed.
- The SpeakUp (store) scheme builds.

New tests, in `ToolHubTests.swift`:
- `SwitchAndImportPhraseTests` (8):
  - "switch to" / "go to" for every tool;
  - the neighbours: read text, the phone, the glasses, main menu, step 3;
  - the import phrases, and that they don't take "read", "read the letter" or "read the label";
  - main screen only;
  - help;
  - the spoken lines;
  - `ImportPicker` expiry.
- `SwitchAndImportRoutingTests` (3): "switch to" from inside another tool, and import phrases never reaching an open tool.
- UI `testSwitchToAndImportByVoice`: "switch to labels", then "switch to read text", then "import" (the tool closes and the choice appears), then "read a photo" (the Photos picker opens).
- `testEveryOpenPhraseOpensItsTool` covers all the new open phrases.

**Fixes after an independent review:**
- "switch to colour" opened the light tone instead of colour mode, because `LightGrammar` wants "colour mode" for the bare word. `LightTool.mode(forOpeningPhrase:)` now accepts it. Test: `SwitchToColourTests`.
- A cut-off "Opening your photos" line still parked a picker request. If a tool opened in between, the picker appeared unasked once that tool closed. The request is now parked only if no tool is open and the session hasn't ended.

Rerun after the fixes: unit tests 744 run, 0 failed; the same UI tests 13 run, 0 failed; the store scheme builds.

**Known, left as is:**
- With Watch open and asking what to look for, "switch to watch" becomes the word to watch for. "open watch" already did this.
- Bare "import" can no longer be a Watch target.

**Not tried on a real iPhone:** whether VoiceOver moving into the picker cuts off the spoken line, and Voice Control in the Photos and Files pickers.

**Plan as written:**
- "switch to \<tool>" as explicit phrases in `ToolID.openPhrases` (`SpeakUpTool.swift:66-74`), not a filler word, so "switch to read text" doesn't start reading and "switch to the phone" still changes camera. `ToolHubTests.testEveryOpenPhraseOpensItsTool` covers it.
- "read a photo", "read a file", "read what I shared" to open Import (J4).

### J3 First run for everyone (M)
- Check which is true, the note (notes/a11y-onboarding.md:72) or the code, and fix the stale one.
- Without VoiceOver: speak the welcome line anyway, then "Tap the big button anywhere to use your voice." A full-width "Use my voice" button calls `setHandsFree(true)`, which gives the spoken reason and the system alerts.
- Spoken pre-prompt before every system alert: "Next, iPhone asks to use the microphone. Choose Allow. With Voice Control on, say 'Tap Allow'."
- When the user picks the phone camera in setup, ask for camera access there, with the same pre-prompt, rather than on first read.
- Tests: `HandsFreeTests.testFirstRunFollowsVoiceOverOnce` (:92) and the `--onboarding` UI tests.

### J4 No touch-only dead ends (M)
- **Import by voice:** "read a photo" and "read a file" open the pickers with a spoken line about what comes next (the pickers stay touch, but VoiceOver and Voice Control work there). Investigate "read my latest photo" / "read my last screenshot" with PhotoKit (needs photo library access, so a separate permission and pre-prompt).
- **Toolbox mode questions:** any spoken yes/no question also says "tap the mic to answer" when the mic is closed.
- **Error alerts** (`CameraAccessApp.swift:106`, `CameraView.swift:140`): always speak them, not only in hands-free.
- **Meta AI handoff:** say before leaving ("I'm opening Meta AI. Approve SpeakUp there, then come back.") and on return. Real-device check in J7.
- **Share extension:** speak "Saved. Open SpeakUp to hear it." already exists; check that "Done" is reachable under VoiceOver.

### J5 Every setting by voice, with undo (S-M)
The iOS slice of C0 and C1, not a separate design.
- "natural voice on/off", "VoiceOver voice on/off", "sounds on/off", "tips on/off". The confirmation says when a switch has no effect (no OpenAI key, VoiceOver not running). Turning sounds off is confirmed in words.
- "undo" / "put it back" restores the last change. Record the previous value in `setVerbosity`, `changeRate`, glasses display, `setHandsFree` and the new setters.
- "what's my setup" reads the current settings.
- Update `settingsOpened` (`SpokenMessage+HandsFree.swift:44`) and the settings help.
- Tests: `VoiceTests.testSettingsByVoice` (:907), `A11yCoreTests`.

### J6 Ways in without the icon (M)
- Widget extension with one `ControlWidget` ("Start SpeakUp hands-free", `OpenIntent`) for the Action button, Control Center and the Lock Screen.
- Document Back Tap and the Action button set-up as a spoken help topic ("how do I start you without the screen?").
- "Hey Meta, start SpeakUp" in the Beta build (beta channel; overlaps C4).

### J7 Prove it end to end
- One UI test that injects the whole walkthrough with `--voice-inject`: launch, setup by voice, read, ask, switch tool, settings, undo, end session, return.
- Real-iPhone walk-through, three ways: VoiceOver, Voice Control with VoiceOver off, and neither. Write down every place a tap was needed.
- Blind and low-vision testers (V0 walk-through).
- Real HSTN: glasses mic, echo, Meta AI screens under VoiceOver (TODO.md:31, :51).

## Not building
- `exit(0)` or the private suspend call. Rejected and looks like a crash.
- Keeping the mic open while the phone is locked. Likely 2.5.4 rejection; revisit only for a clearly described glasses feature.
- Voice answers to system permission alerts by the app itself. Not possible; Voice Control covers it.
