# iOS: Your ears and Sounds (Make it your own C0 bus, C1 Sounds, C2 Your ears)

Built 2026-11-20 on the `SettingsArea` contract (`A11y/Customise/SettingsArea.swift`). Code: `A11y/Customise/Ears/` and `A11y/Customise/Sounds/`. Tests: `CameraAccessTests/EarsAndSoundsTests.swift`.

The framing everywhere is **speech clarity for SpeakUp's voice**. It's never a hearing aid, never hearing loss, and nothing is amplified. It only changes SpeakUp's own sounds.

## What was built

### Sounds (`SoundsArea`, area ID `sounds`)
- **Earcons on/off.** The value still lives in `A11yPreferences.earconsEnabled` (`a11y.earconsEnabled`), because every player and the reading code read it. The Sounds area is now the one place that changes it. Existing choices carry over without a migration step.
- **Earcon volume** and **voice volume** move in 20 % steps.
  - Voice never goes below 40 %, so you can always hear how to turn it back up.
  - Voice volume covers the app's own voice and the natural (OpenAI) voice.
  - On the old speech path it's set through `AVSpeechUtterance.volume`. On the bus it's set through the speech node.
- **Earcons only.** A *status* line that comes with an earcon plays just the earcon. Replies, descriptions and reading are always spoken. With earcons off, the words stay.
- **Say it instead of beeping** (learning mode). The earcon's meaning is spoken in its place: Ready, Connected, Disconnected, Finished, Problem, Not sure, Heads up.
  - Listening, heard, capturing and working stay as tones. Speaking those would talk over the mic, or loop as the listener restarts.
  - A test checks that none of the meaning words is a voice command.

### Your ears (`EarsArea`, area ID `ears`, spoken name "your ears")
- **Balance** runs from -1 to 1 in 20 % steps, by slider or by voice.
- **Which ear for which sound.** Speech, sounds (earcons) and alerts can each go to the left ear, the right ear or both.
  - Alerts are error, attention, uncertain and disconnected (`Earcon.soundKind`).
  - A one-ear route overrides the balance.
- **Mono-aware.**
  - The app reads `UIAccessibility.isMonoAudioEnabled` live, through `monoAudioStatusDidChangeNotification`. A change is announced while the app runs, but only when it changes what you hear.
  - "I use mono" switches mono on in the app too.
  - With mono on, every pan is 0, because a hard-panned sound would just lose level when the channels are summed.
- **Watch for text side cue** (`WatchSideCue`, one line added in `WatchTool`). The sighting's attention earcon is panned ±0.85 towards the side the text is on.
  - With mono on, or with alerts routed to one ear, it switches to a pitch cue instead: ×0.8 for left, ×1.25 for right.
  - "On your left" is always spoken as well.
- **Clear speech** (`SpeechShapingChain`) is a dynamics processor followed by `AVAudioUnitEQ`:
  - dynamics: threshold -22 dB, headroom 6 dB, attack 2 ms, release 80 ms
  - EQ: a 140 Hz high-pass, a high shelf at 2.5 kHz (+6 dB by default, 0–12 dB), and +6 dB make-up gain
  - speaking rate ×0.88
- **Listening check** ("check clear speech"). The same sentence is played as A, then as B, and the user answers A, B or same. `ClarityLadder` searches up and down the 0/3/6/9/12 dB scale, for at most four rounds. The result is recorded as an undoable change.
- **Conversation mode** ("someone's talking to me"). Speech stops, and until the user ends it:
  - Lines that come with an earcon play just the earcon. Everything else is held back.
  - It's announced both ways. If anything was held back, the end line says "Say repeat to hear it".
  - It isn't a saved setting, and it still works while settings are locked.

Every change goes through the area: `SettingsChanges.record` runs first, and the change is refused while `SettingsChanges.isLocked()` returns true ("Settings are locked. Say unlock settings to change them."). Both areas register with `SettingsAreas` and `SettingsVoice` in `AudioCustomisation.install()`, which `CameraAccessApp.init` calls.

Screen: `SoundsSettingsSection` and `EarsSettingsSection` are embedded in the camera screen's settings panel for now (two lines in `CameraView`). They're ready for the core's Settings screen to embed.

## Voice phrases

Phrases are matched as the whole utterance, after the wake word and polite filler are removed (`AudioPhrases.words`). A test checks that no phrase parses as a `VoiceCommand` on any screen, and that none of them is one of the core's phrases.

| Area | Phrases (main ones) |
|---|---|
| Sounds | earcons off / on, sounds off / on, beeps off / on; quieter sounds, louder sounds; louder voice, quieter voice, louder, quieter, speak louder; earcons only, sounds only, just beeps; earcons only off, words and sounds; say it instead of beeping, say what the sounds mean; beep again, back to beeps |
| Balance | move it left a bit, move it right a bit, more to the left, balance right; centre the sound, center the sound, sound in the middle |
| Routing | `[put] <speech/voice, sounds/earcons/beeps, alerts/warnings, everything> [and ...] in/to [my/the] left/right/both [ear(s)/side]` |
| Mono | I use mono, mono on / off, stereo |
| Clear speech | clear speech (on / off), clearer speech, speak more clearly, normal voice; check clear speech, clarity check |
| During the check | A / B / first / second, same / no difference, again / play them again, cancel / stop the check |
| Conversation | someone's talking to me, I'm talking to someone, conversation mode; conversation over, I'm done talking, talk again; **carry on** (only while it's on) |

**For the core agent:** "carry on" is also `VoiceCommand.continueOn`. To end conversation mode with "carry on", `SettingsVoice.route` must run before `VoiceCommandParser`, at least while `ConversationMode.shared.isActive` is true. "Conversation over" works in either order. The same goes for "again", "repeat" and "stop" during the listening check, which this grammar only claims while `ClarityCheck.shared.isRunning` is true.

## Storage

| Key | What |
|---|---|
| `customise.ears` | EarsArea snapshot JSON: balance, speechRoute, earconRoute, alertRoute, userMono, clearSpeech, trebleGainDB |
| `customise.sounds` | SoundsArea snapshot JSON: earconVolume, speechVolume, earconsOnly, sayInsteadOfBeeping. Its earconsOn field is written but ignored |
| `a11y.earconsEnabled` | earcons on/off (unchanged key) |
| `ears.speechBus` | optional kill switch for the speech bus: `off`, `whenShaped` (default) or `always` |

Snapshots are encoded with sorted keys, so the same values always give the same bytes. Unknown or missing fields keep their defaults.

## The audio bus (C0)

```
earconNode, tickNode ----------------------------------------> main mixer   (A11yAudioSession's engine)
speechNode -> pan mixer -> dynamics -> EQ (SpeechShapingChain) -> main mixer
cloud node -> pan mixer -> dynamics -> EQ (its own chain)      -> main mixer (CloudVoicePlayer's engine)
```

- **App voice.** In bus mode, `SpeechBusSpeaker` renders with `AVSpeechSynthesizer.write(_:toBufferCallback:)`.
  - Buffers go to `AudioBus` on A11yAudioSession's serial queue. They're converted to 22.05 kHz mono float and scheduled as they arrive.
  - The line ends once synthesis has finished and every buffer has been played back (`.dataPlayedBack`). This keeps the Announcer's one-line-at-a-time queue, `onStart` timing, and the echo and barge-in rules intact.
  - If the engine stops (a route change or an interruption), the line is cut rather than left hanging.
- **When the bus is used.** By default (`whenShaped`) the bus is used only when the settings need it: a speech pan (balance or a speech ear route, without mono) or Clear speech. Otherwise the old `speak()` path runs, with volume set through the utterance.
  - If the bus fails before any audio (the engine doesn't start, or there's no buffer within 2.5 s), the line is spoken the old way and the bus is switched off for the rest of the run.
  - VoiceOver announcements (the VoiceOver-voice mode) are never routed, because they can't be.
- **Earcons.** Pan and volume are set on `earconNode` and `tickNode` before each play.
- **Natural voice.** `CloudVoicePlayer` keeps its own engine but uses the same `SpeechShapingChain`, so pan, volume and Clear speech apply to it too. **Not moved onto the shared engine, on purpose:** it's main-actor code with its own restart-on-route-change logic. Driving the queue-confined earcon engine from it risks starting a player on a stopped engine, which is an `AVAudioEngine` exception (a crash). The user-facing result is the same.
- **Not routed:** ToolTonePlayer (the light probe and the geiger ticks). It's an instrument with its own engine, so the ear settings don't move it.

### Latency (iOS 27 simulator, MacBook Pro)

These come from `AudioBusLatencyTests`, run on its own on the simulator.

| | Measured |
|---|---|
| Earcon, `EarconPlayer.play` → scheduled and playing | 14.6–17.4 ms cold (session activation and engine start), 0.02–0.05 ms warm |
| Output latency (session output latency + IO buffer) | 10.1 ms |
| **Earcon, trigger to sound** | **about 25–28 ms cold, about 10 ms warm**, within the 100 ms rule |
| Direct speech, `speak()` → `didStart` | 24–28 ms |
| Bus speech, speak → first buffer → node playing, **first use** of the synthesizer | 595–615 ms |
| Bus speech, warm | 3.5–4.6 ms (+10 ms output) |

The cold cost is the first `write()` loading the voice. `SpeechBusSpeaker.prewarm` renders one silent word, 2 s after the settings first need the bus, so in practice users get the warm figure. Warm, the bus is no slower than the direct path. A real iPhone and the A2DP route to the glasses still need measuring; Bluetooth adds its own delay to both paths alike.

## Needs real hardware
- **Per-temple stereo on HSTN.** Does A2DP to the glasses really deliver left and right to separate temples? If it doesn't, ear routing and panned cues can't be heard. The pitch fallback still works, and "I use mono" is the escape.
- **Whether iOS Mono Audio and Balance apply over A2DP to HSTN.** We read the mono flag either way. iOS's own balance slider can't be read, so it stacks with ours.
- **Clear speech EQ on the glasses' small speakers.** The 2.5 kHz shelf and 140 Hz cut were chosen for small drivers. The listening check exists so each user can tune it.
- **Bus first-word latency** on a real iPhone, cold and warm.
- Earcon pan audibility through open-ear speakers, and whether ±0.85 is enough.

## Not done
- **Android.** Another agent has it.
- **Per-tool overrides** for ears and sounds.
- **Profiles and export.** They come with the core, and both areas already snapshot and restore.
- **Moving CloudVoicePlayer onto the shared engine** (see above).
- **Panning the ToolTonePlayer tones.**
