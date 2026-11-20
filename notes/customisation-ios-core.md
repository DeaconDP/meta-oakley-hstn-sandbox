# Make it your own: the iOS core (2026-11-20)

The iOS slice of C0, C1 (speech), C3 (tip pacing), C5, C6 (stored only) and C7 from notes/customisation-roadmap.md, plus most of J5 (notes/voice-journey-ios.md). Code in `A11y/Customise/Core/` and `A11y/Customise/Speech/`, on the shared contract in `A11y/Customise/SettingsArea.swift` (unchanged).

## What was built

- **SettingsStore** (`Core/SettingsStore.swift`). Fills in `SettingsChanges.handler` and `isLocked`. Undo stack (30 steps, session only), keep that, lock, what's my setup, reset one area, reset everything (asks yes or no first, still undoable), learned suggestions.
- **Profiles** (`Core/SettingsStore+Profiles.swift`). Starters Home, Out and about and Reading; save, switch, list, delete. Each is one undoable step.
- **Share and carry** (`Core/SettingsStore+Transfer.swift`). Versioned JSON and a short code. Import says a summary and is one undoable step.
- **Areas**, registered at start-up:
  - `speech` (`Speech/SpeechSettings.swift`): rate, pitch, pause, verbosity, per-tool verbosity, voice, VoiceOver's voice, natural voice, presets.
  - `tips` (`Speech/TipsSettings.swift`): Fewer / Normal / Off.
  - `descriptions` (`Speech/DescriptionSettings.swift`): detail, read text first, colours, directions. **Unused for now:** iOS has no Look closer or cloud scene description yet, so the values are stored, travel in profiles and codes, and wait for a describer.
- **Voice choice by ear** (`Speech/SpeechVoiceTrial.swift`). Installed voices in the current voice's language, best quality first, British first. Each one speaks a short sample in its own voice.
- **Grammars**:
  - `Speech/SpeechGrammars.swift`: speech, tips, descriptions.
  - `Core/SettingsCoreGrammar.swift`: undo, keep, lock, setup, reset, profiles, share, help.
  - `SettingsVoiceGate` (same file): the one door from VoiceControl.
- **Screen**. `Core/MakeItYourOwnView.swift`: a "Make it your own" button in the camera screen's settings menu opens a sheet that mirrors everything (rule 10). Every control has a VoiceOver label, a 60 pt target and Dynamic Type wrapping, and uses the Theme colours. Every change is spoken with its new value.
- **Start-up**. `Core/MakeItYourOwn.swift`, called from `CameraAccessApp.init`.

## The keep rule (design rule 1)

- **By voice:** a change applies at once, for this session. "Keep that" saves it. A voice change that wasn't kept goes back to the kept value on the next launch (`revertUnkeptChanges` at start-up). The first unkept change of a session adds "Say keep that to keep it."
- **On the screen:** kept at once, because a tap is already deliberate. A screen change to an area also keeps any earlier voice change to it.
- **Profile switch, save, reset, import and "keep this one" (voice trial):** kept at once, even by voice.
- **How voice is told from screen:** `SettingsVoiceGate` runs every grammar inside `store.voiceChange { }`, and so does `SpeechChanges` (VoiceControl's faster, slower and answers commands). Anything recorded outside that came from the screen.
- **Undo** covers both kinds, newest first. Screen steps on the same area within 3 s are one undo step.
- **"Keep that"** also saves into the active profile.

## Rate: one portable scale

- `A11yPreferences.speechRateMultiplier` (0.5 to 3) is the stored value. `speechRate` (AVSpeech's 0 to 1) is now a computed view of it, so every existing reader and test keeps working.
- `SpeechRateScale` is piecewise linear and one to one: 0.5× = AVSpeech min, 1× = default, 3× = max. No old value is lost.
- **Migration:** if `a11y.speech.rate` is missing, `a11y.speechRate` is converted and written. Both keys are written on every change, so an older build still reads the user's speed. If the old key no longer matches the new one, an older build changed it in between, and the old key wins.
- **Steps:** "faster" and "slower" move 0.1 below 1× and 0.2 above it, on a 0.05 grid. Each says the new value: "Faster, 1.2 times."

## Phrases

All are whole phrases after polite filler ("can you", "please"). None takes an existing `VoiceCommand` phrase, with one exception: while trying voices, "go back", "back" and "previous" step back through the voices.

- **Speech:**
  - "speed 1.5", "speak at one point two times", "2 times", "normal speed", "double speed", "half speed", "fastest", "slowest"
  - "higher voice" / "lower voice" / "normal pitch" / "pitch 1.2"
  - "longer pauses" / "shorter pauses" / "no pauses"
  - "brisk", "gentle", "normal speech", "slow and clear" / "clear speech rate"
  - "short answers for mail", "detailed answers here", "mail like everywhere else", "same answers everywhere"
  - "natural voice on/off", "VoiceOver voice on/off" (each says when it has no effect yet)
- **Voice trial:** "try another voice" (also "next voice", "change voice"), "go back", "keep this one", "cancel"; "default voice" goes back to the app's own choice.
- **Tips:** "fewer tips", "normal tips" / "tips on", "tips off" / "no tips".
- **Descriptions:** "short / normal / detailed descriptions", "skip colours" / "mention colours", "read text first" / "don't read text first", "clock face directions" / "left and right directions".
- **Core:**
  - "undo" / "put it back"
  - "keep that"
  - "lock settings" / "unlock settings"
  - "what's my setup"
  - "reset speech" (also tips, descriptions, voice, and any registered area by ID or name)
  - "reset everything", which asks "Say yes or no."
  - "switch to out and about" / "use the reading profile" / "home profile"
  - "save as profile <name>", "which profile", "list profiles", "delete profile <name>"
  - "copy my setup" (puts the code on the clipboard), "paste a setup"
  - "settings help"
- **Still VoiceControl's own, now recorded through the store:** "faster", "slower", "short answers", "normal answers", "detailed answers".

## The VoiceControl hook

`VoiceControl.inject(transcript:)`, right after the parse and before the tools route:

```swift
if question == nil, let text = VoiceCommandParser.addressedText(transcript, context: context),
  let reply = environment.routeSettings(text) { ... say(reply); return }
```

- **Why this spot:** the wake word, echo and needs-wake-word gates come from `addressedText`.
- **A waiting yes or no question wins**, so "reset everything" and suggestions can be answered.
- **A tool capturing free words skips the hook** (`SettingsVoiceGate.isCaptureActive`, now Watch asking "what should I watch for?").
- `Environment.routeSettings` defaults to `SettingsVoiceGate.route`, so tests can stand in for it.
- **Other edits in VoiceControl:** `changeRate` and `setVerbosity` call `SpeechChanges`. A VoiceControl built with other preferences (unit tests) gets the same lines with nothing recorded.

## Storage keys

- `a11y.speech.rate` (multiplier), `a11y.speechRate` (legacy, kept in sync)
- `a11y.speech.pitch`, `a11y.speech.pause`, `a11y.speech.toolVerbosity`, `a11y.speech.voice`, `a11y.tips.fewer` (all in A11yPreferences)
- `settings.descriptions` (that area's JSON)
- `settings.locked`, `settings.unkept`, `settings.baseline.<area>`, `settings.tweaks`
- `settings.profiles`, `settings.activeProfile`
- The voice being tried (`A11yPreferences.trialVoiceIdentifier`) is never saved, so closing the app mid-trial can't change the voice.

## Share format

```json
{"schema": 1, "kind": "speakup.setup", "activeProfile": "Home",
 "areas": {"speech": {"rate": 1.2, "verbosity": "short", ...}, "tips": {"pacing": "fewer"}, ...},
 "profiles": [{"name": "Home", "areas": {...}}]}
```

- **The code:** `SPEAKUP1.` followed by base64url of the zlib-compressed JSON.
- **Import** takes either form, refuses a newer schema with a spoken reason, and skips areas this phone doesn't have.
- **Export** carries kept values only, not this session's unkept tweaks.
- **Android** should read and write the same shape (C0).

## Other files touched (outside A11y/Customise/)

- **A11yPreferences:**
  - the multiplier and migration;
  - pitch, pause, per-tool verbosity, chosen voice, trial voice, fewer tips;
  - `effectiveVerbosity`, which is the open tool's override, else the main one.
- **Announcer:** pitch and the pause after each line (`postUtteranceDelay`).
- **AppVoice:** uses the chosen or trial voice, and `installedVoices()` is no longer private. The download notice is skipped once the user has chosen a voice.
- **VoiceCoach:** `fewerGaps` (60 s, 180 s), and `Environment.fewerTips`.
- **TextReader and MailTool:** `verbosity` became `effectiveVerbosity` (one-word hunks).
- **VoiceControl:** the hook, plus `changeRate` and `setVerbosity`.
- **CameraView:** one line, `MakeItYourOwnEntry()` in the settings panel.
- **CameraAccessApp:** `MakeItYourOwn.start()`.

## The onboarding gap (notes/a11y-onboarding.md:69)

Closed. Detail level, speech rate and earcons on/off are all on the Make it your own page, reachable from Settings. The earcon toggle there only flips `A11yPreferences.earconsEnabled`; it isn't recorded for undo because sounds belong to the sounds area (another agent).

## Tests

- **New:** `CameraAccessTests/CustomiseCoreTests.swift`, 33 tests in three classes:
  - `CustomiseCoreTests` (23): rate scale and migration, including an older build in between; keep that and the launch revert; screen versus voice; undo and coalescing; lock; what's my setup; presets; resets; reset everything with yes and no; profiles; save, list and delete; learned suggestions; export and import round trip; refusals; per-tool verbosity; snapshots; tips pacing; descriptions.
  - `SettingsGrammarTests` (8): phrases for every area, app commands left alone, the voice trial, the trial ending, the core phrases, share and paste by voice, numbers in words.
  - `SettingsVoiceHookTests` (2): settings replies first, the wake word taken off, unclaimed words still parsed, a waiting question answered first.
- **Results (Xcode 27.2, a fresh iPhone 17 iOS 27 simulator, 2026-11-20):**
  - Both schemes build (CameraAccess and SpeakUp).
  - New tests: 33 passed, 0 failed.
  - Full `CameraAccessTests`: 538 tests; 535 passed and 3 failed on the first run.
  - `A11yPreferencesTests.testSpeechRateIsClamped` was a real catch: an old-key value written after the new key existed was ignored. Now fixed: the old key wins when the two disagree. Passes on rerun.
  - `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay` is the known failure.
  - `ImportReadingTests.testABlankPictureEndsOnItsNotice` also fails on the untouched base commit (b70329f) on this simulator: Vision waits minutes on a linguistic-data asset. It isn't from this change.
  - So: 536 passed, 2 failed, both already failing before this change.
  - A serial rerun of the voice, preferences, coach, import and new suites ran 84 tests with 1 failure (the blank picture one).
  - UI tests weren't run.

## Not done

- **J5 leftovers:**
  - "sounds on/off" by voice (the sounds agent's area);
  - recording hands-free and glasses display changes for undo;
  - updating `settingsOpened` and the settings help line.
- **Profiles:** no automatic triggers (by tool, time, motion). When added, they must be announced and must not override a manual choice made this session.
- **Descriptions:** stored only, until Look closer exists on iOS.
- **Voice choice:** covers the on-phone voices only, not the OpenAI voice ("coral" is still fixed).
- **Sharing:** no helper view beyond the screen itself, and no backup with bookmarks (C7).
- **Not tried yet:** on a real iPhone, or with VoiceOver on the new sheet.
