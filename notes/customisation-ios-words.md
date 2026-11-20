# Make it your own on iOS: your words and your buttons

Written 2026-11-20. This covers C3 (your words) and C4 (your buttons) from notes/customisation-roadmap.md, on iOS. Both plug into the shared contract in `A11y/Customise/SettingsArea.swift`. The settings core (store, undo, lock, profiles, main settings screen) is another branch's work. The core still has to wire `SettingsChanges.handler`, `isLocked` and `SettingsVoice.route`. This branch only uses them.

## What was built

All new code is in `A11y/Customise/Words/`, `A11y/Customise/Controls/` and `A11y/Glasses/DATGlassesInputs.swift`.

| Area | `areaID` | Storage key | What it holds |
|---|---|---|---|
| `WordsArea` | `words` | `customise.words.v1` (UserDefaults, JSON) | aliases, macros, tools menu order, hidden tools, address word |
| `ControlsArea` | `controls` | `customise.controls.v1` | glasses buttons on/off, event → action map, favourite tool |

Both areas follow the contract:
- Every user-made change goes through one `change` function. It refuses while `SettingsChanges.isLocked()` ("Settings are locked. Say unlock settings to change them."), calls `SettingsChanges.record` with the snapshot from before, then saves.
- Snapshots are JSON with sorted keys.
- `restore` keeps the default for any missing or unknown field.
- `differencesFromDefaults` speaks only what changed.

`MakeItYourOwnWords.install()` is called once from `CameraAccessApp.init`. It registers both areas, registers `WordsGrammar` and `ControlsGrammar` with `SettingsVoice`, and sets the utterance hook.

### Aliases
- **Saying it:** "when I say post, open the mail reader" saves the alias straight away.
- **Where the name ends:**
  - If the recogniser gives a comma, the name ends there.
  - Otherwise the shortest name (up to four words) whose remainder is understood wins.
- **What it can stand for:** any phrase the app's grammar understands (any `VoiceCommand` on any screen), or a tool's own grammar (mail, labels, light, watch, ask). For example, "when I say the works, read it all".
- **Using it:** an alias is rewritten to `<address word> <phrase>`, then parsed as usual. This works for both listeners and for tool phrases.
- **Other phrases:**
  - "forget post"
  - "what are my words"
  - "what does post do"
- **On screen:** a word field, an "It means" picker (every tool and command), and Add and Forget buttons.

### Macros
- **Saying it in one go:** "when I say morning post, open mail and read it all".
  - Steps are split on "then", "and then", "after that" and "and". Tool names that contain "and" stay whole ("light and colour"), and the longest understood head wins.
  - Two or more steps are read back: "Morning post will open mail, then read it all. Shall I save it?" Then "yes" saves it, and "no" or "cancel" drops it.
- **Building it step by step:** "when I say evening", then a step, "then …", "scratch that", "that's all" (read back), and "yes".
  - Up to 10 steps.
  - A draft is dropped after 120 s of silence.
  - While a draft is open it takes every utterance first, including "yes", "no" and "stop".
- **Running:** say its name, say "run <name>", press a glasses button, use the Run button in Settings, or the Shortcuts intent.
- **How steps run:** `MacroRunner` runs each step through `VoiceControl.inject("<address word> <step>")`, so tools get their own phrases.
- **Waiting between steps:** the app has no "command finished" signal. So the runner waits a 0.6 s settle delay, then polls every 0.2 s until `Announcer.isSpeaking` and `TextReader.isActive` are both false. Each step is capped at 300 s.
- **Cancelling:** anything the user says while a macro runs cancels the remaining steps.

### Conflict check (`WordsUnderstanding`)
A new name is refused, with a spoken reason, when it:
- is empty, or longer than four words
- starts with the address word
- is already one of your words or macros ("say forget post first")
- is a built-in command on any screen
- is a settings phrase, or starts with a settings lead word. This covers the core's, the ears' and our own phrases: undo, put it back, keep that, lock/unlock settings, what's my setup, reset …, switch to …, save as profile, earcons …, louder/quieter, balance, move it left/right, clear speech, I use mono, someone's talking to me, carry on.
- is understood by a tool grammar ("how much" belongs to mail, "everything" to labels)

A step must be understood by the app or a tool; otherwise: "I don't know how to open the mailbox…".

### Tools menu
- **By voice:**
  - "put labels first / last / second / to the top"
  - "move mail up / down"
  - "hide light and colour", "hide ask, watch and light"
  - "show watch", "show all tools"
- You can't hide every tool.
- Hidden tools can still be opened by name.
- **On screen:** Up, Down and Hide/Show for each tool, plus "Show all tools".
- `ToolsHome` lists `WordsArea.shared.visibleTools`.
- `SpokenMessage.toolsList` reads a lock-protected mirror, so "list tools" follows the menu. With nothing hidden it still starts "SpeakUp has six tools."

### Address word
- **By voice:** "call you Robin", "your name is …", "change your name to …", "call you reader again", "what's your name".
- **On screen:** a text field and a "Use this name" button.
- One or two words. The plural is also accepted ("robins"), as "readers" was.
- **Refused when it:**
  - is shorter than three letters, or contains a number
  - is a common word ("the", "hey"…)
  - is the first word of any built-in or tool-open phrase ("stop", "open", "read"…)
  - is a settings lead word
  - is, or starts, one of your own words
- `AddressWord` holds the current word behind a lock, because the parser runs off the main actor. `VoiceCommandParser.stripWakeWord`, `wakeWord`, the help line, `VoiceCoachLines.Words`, `voiceControlOnWakeWord` and `voiceNotUnderstood` all use it.

### Your buttons (C4, Experimental)
- **Events (`GlassesControl`):**
  - capture short press / hold / double press
  - touchpad double tap (Select)
  - swipe up / down / left / right (Nav)
  - action button
- **Actions (`ControlAction`):** nothing, look, read, repeat, stop, next, previous (back), status, help, favourite tool, open <tool>, run <macro>.
- **Default map:** short = look, hold = read, double press = stop, double tap = repeat, swipe left = previous, swipe right = next. Up, down and the action button do nothing.
  - "Look" means the open tool starts again (Light probes, Labels scans). With Read text, or no tool open, it reads. iOS has no describe tool yet.
- **Voice phrases:**
  - "what do my buttons do" reads the map, then "Tap and hold on the side of the glasses belongs to Meta: it ends the session, so I never hear it. A single tap pauses or resumes."
  - "when I double tap, stop", "make hold open mail reader", "set swipe up to morning post", "press and hold should read", "what does double tap do"
  - "glasses buttons on / off"
  - "make mail my favourite", "my favourite tool is …", "what's my favourite tool", "open my favourite"
- **SpeakUp (store) build:** the button phrases answer that glasses buttons need the Beta. The favourite tool works in both builds.
- **On screen:**
  - favourite tool picker (both builds)
  - in the Beta build: an on/off button, one picker per event, "What do my buttons do?", and the Meta warning
- **Double press:** because of the known issue below, a short press waits 0.45 s while a double press is mapped, and is dropped if the double press follows.

### Phone triggers
In `WordsIntents.swift`:
- `RunMacroIntent` takes a `MacroEntity` (an `AppEntity` with an `EntityStringQuery` over your macros).
- `OpenFavouriteToolIntent` opens your favourite tool.

Both open the app. The macro waits for the camera screen (up to 60 s) before running.

They aren't App Shortcuts, because `LaunchShortcuts` already uses the 10 iOS allows. They appear in the Shortcuts app, so a shortcut named "Morning post" gives "Hey Siri, morning post", and either can go on Back Tap or the Action Button.

Magic Tap is unchanged (read / stop). It has a single action and no spare slot. CameraView is also being edited on another branch.

## Hooks into existing code (small hunks)
- `Voice/VoiceControl.swift` `inject(transcript:)`: the one hook. `UtteranceHook.rewrite?(heard, context)` returns one of:
  - `.unchanged`
  - `.rewritten(words)`, which is then parsed instead
  - `.handled`: the earcon plays and push to talk ends

  Both the phone and the glasses listener reach `inject`. The engine, in order:
  1. passes its own injected steps through
  2. needs `addressedText` (the wake-word and own-speech gates)
  3. cancels a running macro
  4. lets a draft macro take the words
  5. matches your aliases and macros
  6. tries the words and buttons grammars, unless the words are a built-in command

  It runs before ToolHub. That's why "what are my words" isn't taken by Ask as a question.
- `Voice/VoiceCommand.swift`: `wakeWord` is computed, `stripWakeWord` uses `AddressWord.length(atStartOf:)`, and the help line uses the word.
- `Voice/VoiceCoach.swift` and `Voice/SpokenMessage+Voice.swift`: "reader" → the address word.
- `HandsFree/SpokenMessage+HandsFree.swift`: `toolsList` follows the menu.
- `Tools/ToolsHomeViews.swift`: `ForEach(WordsArea.shared.visibleTools)`.
- `Views/CameraView.swift` `settingsPanel`: `WordsSettingsSection()` and `ControlsSettingsSection()`, until the core's settings screen takes them.
- `CameraAccessApp.swift`: `MakeItYourOwnWords.install()`.
- `ViewModels/CameraViewModel.swift` (DAT only):
  - `DATGlassesInputs.shared.attach(to:)` when the session starts
  - `detach()` when it stops
  - `reattach()` when the glasses go from doffed to donned
- `CameraAccess.xcodeproj`: MWDATInputs linked to CameraAccess (same pattern as MWDATSpeech), and `Glasses/DATGlassesInputs.swift` excluded from the SpeakUp target.

The settings core also gets both grammars through `SettingsVoice`. If it routes `SettingsVoice` itself, there's no double handling, because the hook answers first and stops.

## DAT API findings (search_dat_docs, and the linked 1.0.1 MWDATInputs interface)
- **The linked package already ships the product:** `meta-wearables-dat-ios` 1.0.1 includes `MWDATInputs` (Package.swift products: Camera, Core, Display, Inputs, MockDevice, MockDeviceTestClient, Motion, Speech). So the event wiring is real, not a stub.
- **The interface we rely on:**
  - `extension DeviceSession { func addInputs(configuration: InputsConfiguration = InputsConfiguration()) throws(DeviceSessionError) -> Inputs?; func removeInputs() throws(DeviceSessionError) }`
  - `final class Inputs { let events: AsyncStream<InputEvent>; var state: InputsState; … }`
  - `InputsConfiguration(sources: Set<InputSource> = [.captouch, .neuralBand, .captureButton, .actionButton, .neuralBandDrag], consumeBack: Bool = true)`
  - We pass `[.captureButton, .captouch, .actionButton]` and `consumeBack: false`.
- **InputEvent (iOS):** "`nav(direction:source:timestampMs:)`, `select`, `back`, `button(ButtonType, …)`, `capture(CapturePressType, …)`, `drag(…)`".
- **CapturePressType:** "`shortPress` → A single short press of the capture button. Defaults to capturing a photo. `hold` → … Defaults to starting a video recording. `doublePress` → … Defaults to stopping an in-progress video recording." Marked "Dev and beta only".
- **Input sources:** "A double tap on the touchpad arrives as `Select`, and a swipe arrives as `Nav` with the direction produced by the current device interaction mapping and settings. The wearer's device settings can invert horizontal and vertical swipe output."
- **Reserved:** "Single tap with one finger | Pauses or resumes the device session. Tap and hold with one finger | Stops the device session. … Do not design an interaction around a single tap or tap and hold on the touchpad. Use a double tap to select, and use the capture button's `HOLD` / `.hold` press type if you need the button's hold action."
- **Known issue, double press:** "When the user double-presses the physical capture button on the glasses, the SDK sends the client two separate `Capture` events instead of one: a `SHORT_PRESS` event followed by a `DOUBLE_PRESS` event." The workaround is to "Buffer each `SHORT_PRESS` event briefly".
- **Known issue, re-wear:** "If users remove their glasses and then don them again while Wear Detection is on, inputs stop working. … re-add the capability … when the glasses are worn again."
- **Not checked:** the docs server kept returning errors for LaunchApp, so "Hey Meta, start SpeakUp mail" wasn't looked at or built.

## Tests
`CameraAccessTests/CustomiseWordsTests.swift` has 41 tests: `CustomiseWordsTests` (27) and `CustomiseControlsTests` (14). They cover:
- alias rewrite, and the wake-word gates on it
- macro one-liners and step-by-step building, read-back, yes/no, timeout
- run order with waiting, and cancel on speech
- conflict refusals
- tools menu order, hide/show and persistence, and `toolsList`
- address word in the parser, help and tips, plus its conflicts
- snapshot/restore with unknown fields, `differencesFromDefaults`, record before each change, and lock refusals
- VoiceControl's hook end to end
- the button map, the double-press buffer, button grammar, the store build's replies
- `ControlAction` round trip
- built-in, core and ears phrases staying unclaimed

Full CameraAccessTests run, serial: 567 tests, 2 failures.
- The known `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay`.
- `ViewModelIntegrationTests.testStreamingAndStillForReading` ("Condition not met within 10.0 seconds"). That class passed twice when run on its own (4/4 each time), so it looks like a timing flake in the long serial run.

Both schemes (CameraAccess, SpeakUp) build.

## Needs real hardware or a real iPhone
- Which Inputs events HSTN actually sends:
  - capture hold and double press
  - whether there is an action button
  - which way swipes go, and whether the wearer has inverted them
- Whether adding Inputs takes the capture button's own photo/video action while SpeakUp's session runs, and whether "glasses buttons off" (`removeInputs`) gives it back.
- Whether 0.45 s is the right double-press window.
- Whether re-adding on re-wear restores inputs.
- How the recogniser writes custom address words and alias names (unusual names may be transcribed differently), and whether it gives commas for "when I say X, …".
- Macro step timing on real tools: does a mail "read it all" right after "open mail" have a letter to read yet?
- The Shortcuts intents from Siri, Back Tap and the Action Button.
- The settings section was not checked on screen: the device panel had no Mac host.

## Not done
- C3 "your timing" (tip pacing).
- C4 `LaunchApp` ("Hey Meta, start SpeakUp mail").
- C4: whether Meta's press-and-hold shortcut can launch a DAT app.
- Magic Tap's favourite-tool action (see above).
- Android.
