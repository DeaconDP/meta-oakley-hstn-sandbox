# Make it your own: Android (HstnBench)

2026-11-20. The Android side of notes/customisation-roadmap.md: one settings model, settings by voice, a settings screen, your ears, your words, profiles, sharing, and (Experimental) the glasses buttons. Code is in `tracks/android-native/HstnBench/app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/` (paths below are relative to it). iOS is being built in parallel to the same JSON schema; the field list below is the contract.

## What was built

| Milestone | Status on Android | Where |
|---|---|---|
| C0 settings model + migration | Done | `tools/settings/Setup.kt`, `SettingsStore.kt`, `SettingsPrefs.kt`, `SetupJson.kt` |
| C0 settings grammar | Done | `tools/settings/SettingsGrammar.kt`, `SettingsVoice.kt`, routing in `tools/ToolHub.kt` |
| C0/C2 one audio bus | Built, **off by default** (Experimental switch on the screen) | `tools/AudioBus.kt`, bus path in `tools/ToolSpeaker.kt` |
| C1 presets, pitch, pauses, voices, verbosity, sounds | Done (verbosity: partly, see "What's left") | `SettingsVoice.kt`, `ToolSpeaker.kt`, `Earcons.kt` |
| C1 settings screen | Done | `ui/CustomiseScreen.kt`, tune button on the camera screen |
| C2 balance, ear routing, mono, clear speech, conversation mode | Done | `tools/settings/AudioMath.kt`, `ToolSpeaker.kt`, `Earcons.kt`, `ToneSynth.kt`, `ToolHub.kt` |
| C3 aliases, routines, conflict check, menu, address word, tip pacing | Done | `tools/settings/Shortcuts.kt`, `ToolHub.kt` |
| C5 profiles + learned suggestions | Done (no automatic triggers) | `SettingsStore.kt` |
| C7 export/import, code, share, paste | Done | `SettingsStore.kt`, `SetupJson.kt`, `CustomiseScreen.kt` |
| C4 glasses controls (Experimental) | Wired to DAT Inputs (`mwdat-inputs` 1.0.1); untested on hardware or the mock | `tools/GlassesControls.kt` |
| C6 descriptions | Stored, exported and on the screen for parity; no Android tool uses them yet | `Setup.kt` (Descriptions) |

### How a change flows

- **Two copies**: `current` (what the app uses now) and `saved` (what survives a restart). A **voice tweak** ("slower", "shorter", "try another voice", "move it left a bit", "fewer tips") changes only `current`; the first one in a session ends "Say keep that to keep it." **"Keep that"** saves every unkept tweak, into the active profile too. Deliberate changes are saved at once: shortcuts, routines, menu, address word, glasses controls, resets, profile switches/saves, imports, and **everything on the settings screen**.
- **Undo** reverses the last change of either kind, including a keep, a reset, a profile switch and an import (journal of 30, this session). **Lock** refuses every change except "unlock settings", and survives a restart.
- **Every change speaks its new value** ("1.3 times speed.", "Balance 10 percent to the left.", "Mail: short replies."). Changes on the screen are spoken too while voice is running (helper view).
- **Learned suggestion**: the third tweak of the same kind (across sessions, until kept) asks "You've said slower 3 times. Make this your default for home? Say yes or no." Nothing changes without "yes"; "no" stops that question for good.
- **Order of grammars** in `ToolHub.onUtterance`: echo guard → conversation mode (only "carry on" gets through) → the user's address word dropped → **shortcut rewrite** (alias = one command, routine = several in turn) → settings first only while trying voices or answering a yes/no → the tool's grammar → **settings grammar** → global grammar. In the home menu: settings grammar, then `parseHome`. `SettingsGrammarTest.settingsPhrasesDontClashWithOtherGrammars` checks that no settings phrase is claimed by the global, book, mail, watch, labels or light grammars, so the order never changes a meaning.
- **Speed**: one main rate, plus a per-tool override (the book's old separate rate became `speech.tools.book.rate`). "Faster" in a tool changes that tool's override if it has one, otherwise the main rate. "Same speed everywhere" drops the overrides. The book screen's rate buttons and slider change the same value (saved).

## Phrases

All English, normalised by `Phrases` (fillers dropped; "right", "now" and "ok" kept for these rules).

| Area | Say |
|---|---|
| Keep, undo, setup | "keep that", "keep it", "make that the default", "undo", "put it back", "change it back", "what's my setup", "what have I changed", "read my settings" |
| Reset | "reset speech / sounds / ears / balance / words / shortcuts / controls / tips / descriptions", "reset everything" (each one undoable) |
| Lock | "lock settings", "unlock settings" |
| Speed | (global, unchanged) "faster", "a bit slower", "much faster", "1.5 times", "normal speed"; "same speed everywhere", "use my main speed for the book" |
| Detail | "shorter", "less detail", "keep it short", "more detail", "normal detail"; per tool: "make mail shorter", "keep the book detailed", "labels normal" |
| Presets | "brisk speech", "be gentle", "normal speech", "use brisk" |
| Voice | "higher pitch", "deeper voice", "normal pitch", "longer pauses", "shorter pauses", "no pauses", "clear speech", "turn off clear speech" |
| Choosing a voice | "try another voice" (each reply is spoken in the new voice: "Voice 2 of 5, United Kingdom voice 2. This is how I sound…"), then "next", "go back", "keep this one", "never mind"; "what voices are there", "default voice" |
| Sounds | "turn off the beeps", "sounds on", "louder beeps", "quieter sounds", "only the beeps" / "beeps only" (sounds instead of short replies), "words again", "tell me what the sounds mean", "stop saying the sounds" |
| Ears | "move it left a bit", "move it to the right", "more in my left ear", "centre the sound", "speech in my left ear", "beeps in my right ear", "direction cues in my left ear", "everything in both ears", "I use mono", "I use stereo" |
| Conversation | "someone's talking to me", "I'm talking to someone", "conversation mode" → the tool pauses, one line ("OK, I'll keep quiet. Say carry on when you're done."), then silence (earcons still play) until "carry on", "I'm back", "conversation over" |
| Shortcuts | "when I say post, open the mail reader"; "when I say morning post, read my mail and then read it all" (a routine, read back: "When you say morning post, I'll read my mail, then read it all."); "forget the shortcut post"; "what are my shortcuts" |
| Menu | "put labels first", "move mail to the end", "hide light and colour", "show light on the menu", "reset the menu", "what's on my menu" |
| Address | "call yourself Sam" (then "Sam, read my mail" works), "forget your name" |
| Tips | "fewer tips", "no more tips", "normal tips" |
| Profiles | "switch to out and about", "use the reading profile", "home profile", "save this as kitchen", "which profile am I on", "list my profiles"; answering a suggestion: "yes" / "no" |
| Glasses controls | "what do my buttons do", "turn on glasses controls", "when I hold the capture button, read my mail", "when I swipe forward, faster", "when I tap, stop" |
| Screen, sharing | "open settings", "settings", "share my setup" |

Refused, with a spoken reason: a shortcut phrase that already means something ("stop already means the pause command. Pick another word."), a target nothing understands, a shortcut pointing at another shortcut, more than 50 shortcuts, hiding every tool, an address word that is a command.

## The JSON schema (version 1)

Top level: `{"schema":1,"areas":{…},"profiles":{…},"activeProfile":"home"}`. Readers ignore unknown areas and fields and use the default for anything missing, so a sparse document (a share code) and a full one read the same way. On the phone the stored document also has `"device":{"locked","learn","declined","migratedFrom"}`, which export leaves out.

| Area | Field | Type, range | Default |
|---|---|---|---|
| speech | `preset` | `"brisk"`, `"normal"`, `"gentle"` | `"normal"` |
| | `rate` | number, 0.5–3 multiplier of the engine's normal speed, one decimal | 1.0 |
| | `pitch` | number, 0.5–2 multiplier | 1.0 |
| | `pauseMs` | integer, 0–1500, extra silence after each sentence of tool content | 0 |
| | `verbosity` | `"short"`, `"normal"`, `"detailed"` | `"normal"` |
| | `voice` | string or null: the platform's voice id (Android `Voice.name`); a voice id from the other platform is ignored | null |
| | `locale` | BCP-47 string or null (null = device language, falling back to en-US) | null |
| | `tools` | object keyed by tool id (`book`, `mail`, `watch`, `labels`, `light`); each may have `rate`, `verbosity`, and for `book` `pageNumbers` (bool) and `autoTurn` (bool) | `{}` |
| sounds | `earcons` | bool | true |
| | `volume` | number 0–1 | 0.8 |
| | `earconsOnly` | bool: familiar short replies ("Paused.", "Main menu.") become just the earcon | false |
| | `speakEarcons` | bool: say what a sound means instead of playing it | false |
| | `watchTickSeconds` | integer 0–600, 0 = off | 10 |
| ears | `balance` | number −1 (left) … 1 (right) | 0 |
| | `speech`, `earcons`, `cues` | `"both"`, `"left"`, `"right"` | `"both"` |
| | `mono` | bool ("I use mono"; iOS can also read the system setting) | false |
| | `clearSpeech` | bool | false |
| words | `aliases` | object phrase → command phrase (keys normalised: lower case, no punctuation or fillers) | `{}` |
| | `macros` | object phrase → array of 2–6 command phrases | `{}` |
| | `menuOrder` | array of tool ids | `["book","mail","labels","watch","light"]` |
| | `menuHidden` | array of tool ids | `[]` |
| | `address` | string or null | null |
| controls | `enabled` | bool | false |
| | `captureShort`, `captureHold`, `captureDouble`, `select`, `navUp`, `navDown`, `navLeft`, `navRight`, `action` | command phrase, `""` = nothing | `"say that again"`, `"carry on"`, `"main menu"`, `"stop"`, `"faster"`, `"slower"`, `""`, `""`, `""` |
| tips | `pacing` | `"fewer"`, `"normal"`, `"off"` | `"normal"` |
| descriptions | `detail` | `"short"`, `"normal"`, `"detailed"` | `"normal"` |
| | `textFirst`, `colours` | bool | true, true |
| | `directions` | `"leftRight"`, `"clock"` | `"leftRight"` |

- **Profiles** hold only the `speech`, `sounds`, `ears`, `tips` and `descriptions` areas, each with only the fields that differ from the defaults. Words and controls are yours in every profile. Starters: `home` (`{}`), `out and about` (`speech: {preset: brisk, rate: 1.4, verbosity: short}`, `sounds: {earconsOnly: true}`, `tips: {pacing: fewer}`), `reading` (`speech: {pauseMs: 250, tools: {book: {verbosity: detailed}}}`, `tips: {pacing: fewer}`). Profile names are lower case.
- **Floats** are written with a decimal point (`1.0`), integers without.
- **Share code**: `"SU1."` + base64url (no padding) of raw DEFLATE (no zlib header) of the sparse document: only fields that differ from the defaults, and only profiles that differ from the starters. One changed setting gives a code well under 120 characters. Import accepts a code (spaces and line breaks ignored), a full document, or a bare areas object. `schema` above 1 is refused ("from a newer SpeakUp").
- Tests pin the field names and order (`SettingsStoreTest.theJsonSchemaFieldsAreStable`).

## Migration map

Done once, the first time the store loads with no document (`SettingsPrefs.oldPrefs`). Old keys stay but are no longer read.

| Old | New |
|---|---|
| `tools` / `speech_rate` | `speech.rate` |
| `book_reader` / `speech_rate` | `speech.tools.book.rate`, only if it differs from the main rate (a book rate alone keeps the main rate at 1.0) |
| `book_reader` / `read_furniture` | `speech.tools.book.pageNumbers` (only stored when true) |
| `book_reader` / `auto_turn` | `speech.tools.book.autoTurn` (only stored when false) |
| `tools` / `watch_tick_seconds` | `sounds.watchTickSeconds` |

The bookmark and recap (`book_reader` / `bookmark`, `ask_memory`) and the setup-flow prefs stay where they were. Storage is one SharedPreferences file `speakup_settings`, key `setup_json` (DataStore would add a dependency and an async hop for a few-kilobyte document that ToolSpeaker needs synchronously at start-up). The audio bus switch is device-only (`audio_bus`). Instrumented tests clear `speakup_settings` and call `SettingsPrefs.resetForTests()` in their set-up.

## Audio design

**Default path (no bus)**, used unless the Experimental switch is on:
- Speech: `TextToSpeech` as before, plus `KEY_PARAM_PAN` (balance + which ear, −1…1) and `KEY_PARAM_SESSION_ID` (our own audio session). Clear speech attaches `DynamicsProcessing` to that session: pre-EQ (−3 dB at 250 Hz, +3 dB at 2 kHz, +5 dB at 4 kHz, +2 dB at 8 kHz), a 3:1 compressor from −30 dB, +6 dB post-gain, limiter at −2 dB; and the rate is capped at 1×. Whether the installed engine honours the pan and session parameters is engine-specific and unverified (roadmap "needs real hardware").
- Earcons: `ToneGenerator` while centred (no change in latency from before). When panned (balance, or earcons in one ear) the same earcon is played from PCM (`AudioMath.EARCON_NOTES`, same lengths) on a small static stereo `AudioTrack`; volume rebuilds the `ToneGenerator`.
- Tones and direction cues: `ToneSynth` now plays stereo PCM with the earcon ear and balance. **Watch for text** plays a short cue on the side the text was seen (left/ahead/right), or for "I use mono" a pitch (440 Hz left, 660 ahead, 880 right); the spoken "on your right" is always kept.
- Balance law (`AudioMath.gains`): the near side stays at full level and only the far side is turned down, so centred sounds are exactly as loud as before.

**The audio bus** (`AudioBus`, switch "One audio output" under Experimental, off by default): one low-latency streaming stereo `AudioTrack` at 24 kHz; a mixer thread writes 5 ms blocks (120 frames); speech comes from `synthesizeToFile` with `onBeginSynthesis`/`onAudioAvailable` streaming PCM into the bus (resampled from the engine's rate, `AudioMath.resample`), utterances strictly in order; earcons and tones mix on top; clear speech is `DynamicsProcessing` on the bus session; the track pauses after 2 s idle. Added latency for an earcon: one block plus the track buffer, `AudioMath.busLatencyMs` = about 25 ms with a 480-frame buffer, logged at start-up (`AudioBus` log line) and per earcon (`bus_earcon_ms=`). **Why it's off by default**: speech can only start once the engine hands over its first chunk (engine-dependent, never measured here), stop/echo-guard timing moves from the engine's callbacks to the bus's, and neither path's latency has been measured on the A26 or over A2DP to HSTN. Balance, routing and mono work without it, so nothing in C2 depends on turning it on.

**Latency numbers**: none measured on a device in this pass (no API 31+ phone or emulator reachable from this PC; the attached phone is the Galaxy S7, Android 8, which can't install the app). The figures above are the design budget. To measure: switch the bus on, open any tool, `adb logcat -s AudioBus` and read `bus_earcon_ms` and the start-up latency line.

## Glasses controls (Experimental)

`GlassesControls` adds DAT Inputs (`mwdat-inputs` 1.0.1, the sample BirdSpotter uses the same API) when the stream is up and controls are on: sources `CAPTOUCH`, `CAPTURE_BUTTON`, `ACTION_BUTTON`, back not consumed. Capture short/hold/double, Select, Nav up/down/left/right and the action button map to the controls keys; the mapped phrase runs as if spoken (so a shortcut or routine works on a button). An Inputs capability that goes INACTIVE after ACTIVE (a photo can do that) is removed and attached again. It needs Inputs enabled for the app in Wearables Developer Center (dev and beta channels only). "What do my buttons do?" reads the map and says that touch-and-hold on the temple belongs to Meta. Not yet exercised on the mock (`glasses.services.input.capture(...)`) or hardware.

## Settings screen

`ui/CustomiseScreen.kt`, from the tune button at the top of the camera screen ("Make it your own: settings") or by saying "open settings". Sections: status and Undo / Keep changes / What's my setup / Lock; Profiles; Speech (preset, speed, the book's own speed, pitch, pause, detail and per-tool detail, page numbers, auto-turn, voice list); Sounds; Ears (balance, three ear choices, mono, clear speech, conversation mode); Words (shortcuts with forget, add shortcut, menu order up/hide, address word); Tips; Descriptions (with a line saying "how sure" and the refusals always stay on); Glasses controls; Share and carry (share sheet with code + full JSON, copy code, paste, import); Start again (reset per area and everything, all undoable); Experimental (audio bus). Every control is ≥ 56 dp, labelled, reports its value in words (`stateDescription`), headings are headings, choices are radio groups and switches whole-row toggles, Paper on Night/Dusk. Changes are saved and spoken. Not yet checked with TalkBack on a device.

## Not offered, on purpose

No option switches off "can't tell", the medicine and money refusals or face blur; imported fields with names like that are dropped (`SettingsStoreTest.importIsTolerantAndRefusesWhatItCantUse`). Clear speech is described only as SpeakUp's own voice being clearer, never as hearing help. No user-designed earcons.

## Tests

JVM (`./gradlew testDebugUnitTest` in `tracks/android-native/HstnBench`, on this Windows PC with `sdk.dir` in `local.properties`): **341 tests, 0 failures** (301 before this work, 40 new):
- `SettingsStoreTest` (14): migration without loss, book rate = main rate isn't an override, defaults and starters, session-only tweaks and keep, undo across keep/reset, per-area reset, lock (survives restart, blocks undo/reset/switch/import), profiles (switch, kept tweak into the profile, save, undo, words shared), learned suggestion (asks at 3, never applies, "no" stops it), export/import round trip by JSON and code, tolerant import (bad text, newer schema, unknown and safety-sounding fields ignored, bare areas object), schema field names, "what's my setup" differences only, clear speech caps the rate.
- `SettingsGrammarTest` (7): 70 example phrases, shortcut comma handling, context words (voice trial, yes/no, conversation mode hears only "carry on"), profile names (and "start reading" stays the book's), room chatter, no clashes with the other grammars, the global speed phrases stay global.
- `ShortcutsAndVoiceTest` (13): alias add and rewrite, split without a comma, routine build and read-back, conflict/unknown/nested refusals, forget/list, every change speaks its value + the one-time keep hint, the book's own speed, trying voices (next/back/keep/cancel), locked replies, the learned question waiting for yes, shortcuts/menu/buttons/conversation by speech, pan/balance/mono/cue maths, mixing, clipping, earcon PCM, bus latency budget.
- `SettingsExtrasTest` (6): first-sentence trimming for short replies, a one-change code under 120 characters that imports with starters intact, TTS PCM decoding and resampling, the command catalogue, tip pacing gaps, menu normalisation.

Also built: `assembleDebug` and `assembleDebugAndroidTest`. Instrumented tests were **not run**: no API 31+ device or emulator is reachable from this PC (adb sees only the Galaxy S7, SM-G930F, Android 8.0). The instrumented tests were updated to clear the new settings file.

## What's left

- Run the instrumented suite on the A26 (BookReaderTest checks the rate change by voice, which now goes through the store) and add a `CustomiseTest`: "slower", "keep that", restart, "undo", "what's my setup", a shortcut, the screen under TalkBack.
- Measure on a device: earcon latency with and without the bus (`bus_earcon_ms`), first-word delay of bus speech, whether the engine honours `KEY_PARAM_PAN` and `KEY_PARAM_SESSION_ID`, and stereo per temple on HSTN.
- Verbosity is applied by ToolHub to welcomes and silence reminders (first sentence only when short) and exposed as `hub.verbosity()`; the tools' own content (mail summaries, label read-outs) doesn't use it yet.
- Glasses controls: exercise on the mock (`glasses.services.input`) and with Developer Center approval; "Hey Meta, start SpeakUp mail" (LaunchApp) not done.
- Profiles: automatic triggers (by tool, time, walking) and "stop switching for now" not done; learned suggestions cover speed, detail, pitch and sound volume tweaks.
- C6 description preferences have no consumer on Android.
- The listening check for clear speech ("which is clearer, A or B?") not done.
- Hiding a tool hides it from the spoken menu only; the camera screen's tool buttons are unchanged.
- English only: settings grammar, replies and the screen's labels.
