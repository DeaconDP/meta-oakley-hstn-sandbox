# Make it your own: customisation roadmap

Written 2026-11-18, after Meta announced four new glasses features: hearing enhancement, detailed responses, audio balance and mono audio, and customisable controls. Three research passes fed this note: what the DAT SDK allows, what both apps let users change today, and BLV prior art on customisation.

**Idea.** SpeakUp should feel like *your* assistant: your voice, your speed, your words, your ears, your buttons. Every change has to be possible by voice, in the moment, without sight, and without the user getting lost in settings.

## How Meta's four features map to SpeakUp

| Meta feature | What a DAT app can do | SpeakUp's version | Status |
|---|---|---|---|
| Hearing enhancement | Live amplification **isn't workable**. Glasses→phone→A2DP is very likely over 300 ms, while hearing aids need about 10–20 ms. The HFP mic is beamformed at the wearer and forces mono. | **Clear speech**: SpeakUp's *own* voice gets slower, louder, compressed and treble-boosted. A **conversation mode** quiets SpeakUp while Meta's hearing feature runs. Never say "hearing aid", "hearing loss", "amplify" or "FDA". | GA |
| Detailed responses | GA in-stream photo (960x1440 on the mock). FULL 12 MP is Experimental. | A **detail dial** plus **description preferences** ("always mention text", "skip colours"). | GA, with FULL in dev/beta |
| Audio balance and mono | A2DP is stereo. We can pan our own audio (Android: scale samples in an `AudioTrack`; iOS: `AVAudioPlayerNode.pan`). We can read iOS `isMonoAudioEnabled`, but not Android's balance or mono. | In-app **balance**, **which ear for which sound**, and spatial cues that turn off with mono and fall back to pitch. | GA. Per-temple stereo needs hardware to confirm |
| Customisable controls | `Inputs` (Experimental): `Capture(SHORT_PRESS/HOLD/DOUBLE_PRESS)`, `Select`, `Nav`, `Drag`. Tap and tap-and-hold are **reserved** (pause and stop), so Meta's temple press-and-hold launcher **can't be copied**. `LaunchApp` voice invocation is Experimental. | **Glasses controls** page that maps events to SpeakUp actions *within our session*, plus "Hey Meta, start SpeakUp mail". | Experimental |

## Where we are today

- **There is no central settings model on Android.** Six settings live in three SharedPreferences files, most of them voice-only, and there is no settings screen. The shared rate and the book rate are separate, which repeats the iOS "two rates" confusion.
- **iOS has `A11yPreferences.shared`,** a good hook. But verbosity and earcons can't be reached at all, and the speech rate can only be changed by voice. `notes/a11y-onboarding.md:69` says detail level and rate "stay in Settings", and they don't.
- **Rate scales don't match.** Android uses a multiplier from 0.5 to 3×; iOS uses the AVSpeech rate. Portable profiles need one scale.
- **Audio isn't routed through one place:**
  - Android has 4 outputs: TTS, ToneGenerator, and two AudioTracks.
  - iOS has 3: AVSpeech sits outside the shared engine, and the cloud player has its own engine.
  - Balance and EQ need one bus.
- **Many values are hardcoded:**
  - voice: Android `Locale.US`, iOS a fixed British voice, OpenAI "coral"
  - earcon set and volume
  - tip and nudge timings
  - wake words and phrase tables
  - home-menu order
  - confidence thresholds

  Details: the audit in the research pass, summarised in the Foundation tasks below.

## Design rules for customisation

These come from VoiceOver Activities, TalkBack Custom verbosity, NVDA profiles and JAWS temporary-vs-permanent changes.

1. **Change it in the moment.** "Slower" applies now, for this session. "Keep that" saves it. Every change speaks the new value.
2. **Presets first, then tweaks.** Start from about three named presets, then change any single setting. Say the difference: "Normal, but faster."
3. **"What's my setup?"** Speak only what differs from the defaults.
4. **Undo the last change, and reset one area at a time** (speech, sounds, words, controls). Never offer a single reset with no undo.
5. **Lock settings,** so an accidental "slower" can't stick. This addresses the VoiceOver rotor "phone keeps going super slow" complaint.
6. **One place for each setting.** A per-tool override is shown as an override of the main setting, not as a second copy.
7. **Defaults must be good without any changes,** because beginners rarely customise. Spoken tips bring options up gradually.
8. **Automatic switching is always announced** and can always be overridden. Copy NVDA's "temporarily disable triggers".
9. **Suggest a change, never apply it silently.** For example: "You've said 'shorter' three times. Make short the default?"
10. **The screen mirrors the settings for helpers,** who can also share a setup with a code.

## Milestones

Each milestone ships on Android first and then on iOS, unless marked. Everything is voice-reachable, mirrored on screen, GA only, unless marked Experimental.

### C0. Foundation (prerequisite)
- One **settings schema**, a versioned JSON shape shared by both platforms:
  - speech: rate on one 0.5 to 3× scale, voice, pitch, verbosity
  - sounds
  - ears
  - words
  - controls
  - tools
  - profiles

  Storage is DataStore on Android, and `A11yPreferences` extended on iOS. Per-tool overrides are layered on top.
- Migrate the existing keys: the tools and book rates, page numbers, auto-turn, watch tick, and the iOS keys. Merge the book rate into "main rate + book override".
- **One audio bus:**
  - Android: TTS through `synthesizeToFile` or streaming into a single `AudioTrack` mixer, along with the earcons and tones.
  - iOS: `AVSpeechSynthesizer.write` into the shared `AVAudioEngine`, with the cloud player on the same engine.
  - This is the hook for balance, EQ and ear routing. Check the latency hit against the ≤ 100 ms earcon rule.
- A **settings grammar** in the global grammar: "slower/faster", "shorter/more detail", "keep that", "undo", "what's my setup", "reset speech", "lock settings".

### C1. Your voice (GA)
- Speech presets: **Brisk**, **Normal** and **Gentle**, then individual tweaks to rate, pitch, pause length and verbosity.
- **Voice choice** by voice: "try another voice", "go back", "keep this one". It lists the installed voices and plays a sample of each. On iOS it also covers the OpenAI voice.
- Verbosity per tool: for example, mail short while the book stays detailed.
- **Sounds:**
  - earcons on/off
  - earcon volume
  - an **"earcons only"** mode for familiar actions
  - an optional "speak instead of earcon" mode while learning

  Users don't need to design their own sounds; the research says it isn't valued.
- Settings screen on Android, plus iOS rows for verbosity, rate and earcons, which closes the parity gaps.

### C2. Your ears (GA)
- **Balance**: a left/right slider and "move it left a bit".
- **Ear routing per kind of sound**: speech in one ear, earcons and alerts in the other, or everything in both.
- **Mono-aware:**
  - On iOS, read `isMonoAudioEnabled` and the change notification.
  - On Android, there's a manual "I use mono" switch.
  - When mono is on, the left/right cues (Watch for text) fall back to spoken directions or a pitch cue.
- **Clear speech** preset: slower, louder, compressed and treble-boosted TTS, using Android `DynamicsProcessing` and iOS `AVAudioUnitEQ`.
  - An optional **listening check** ("which is clearer, A or B?") tunes it.
  - It's framed only as "speech clarity for SpeakUp's voice", never as hearing correction.
- **Conversation mode**: "someone's talking to me" pauses speech and switches to earcons only until "carry on". This works alongside Meta's hearing enhancement.

### C3. Your words (GA)
- **Aliases**: "when I say 'post', open the mail reader". The alias is added to the grammar. A rewrite step before parsing goes in `ToolHub.onUtterance` on Android and merges into `phraseLookup` on iOS.
- **Macros**: "when I say 'morning post', open mail and read it all". A macro is a short, ordered list of existing commands, built by voice and read back.
- **Conflict check**: an alias that clashes with a built-in command is refused, with a spoken reason.
- **Home menu**: show, hide or reorder tools by voice ("put labels first", "hide light and colour").
- **Wake and address word** choice, which replaces the fixed "reader".
- **Your timing**: tip and nudge pacing as Fewer / Normal / Off, not raw seconds.

### C4. Your buttons (Experimental, dev/beta)
- **Glasses controls**: map `Capture` short, hold and double press, `Select` (double tap) and `Nav` swipes to SpeakUp actions such as repeat, stop, read, a favourite tool or a macro. Default map: short = look, hold = read (already in phase 6).
- **"What do my buttons do?"** reads the mapping back. A spoken warning explains that tap-and-hold on the temple belongs to Meta and ends the session.
- **"Hey Meta, start SpeakUp mail"** opens straight into a tool, using `LaunchApp` (needs Developer Center approval).
- Open question: can Meta's own *customisable press-and-hold* launch a third-party DAT app? If it can, that's the GA route.
- On the phone, Siri phrases, App Shortcuts, Back Tap and Magic Tap can be bound to tools and macros (overlaps with the onboarding item).

### C5. Your profiles (GA, auto-switching later)
- Named **profiles** bundle the speech, ears, sounds, words and controls settings, plus per-tool overrides. Starters: **Home**, **Out and about** (terse, earcons first, orientation-only language) and **Reading**.
- Switch by voice ("switch to out and about"); a manual choice always wins.
- Then, as an option: **automatic triggers** by tool, time, or walking vs still (phone motion; glasses Motion is Experimental). Every switch is announced, and "stop switching for now" pauses them.
- **Learned suggestions**: repeated tweaks prompt "make this the default for Reading?", and nothing changes without a yes.

### C6. Your descriptions (GA, with FULL in dev/beta)
- **Detail dial** for Look closer: short, normal, detailed, plus a "max detail" option using a FULL photo in dev/beta.
- **Description preferences** stored in the profile:
  - always read any text first
  - mention colours or skip them
  - count people without describing them (privacy rules unchanged)
  - units
  - left/right or clock-face directions
- These preferences are passed to the model. "Say how sure" and the refusal rules can't be switched off.

### C7. Share and carry (GA)
- **Export and import** a setup as a short code or a file. It works on both platforms through the C0 schema.
- **Helper view**: a sighted helper sees and edits the setup on the phone screen, and every change is spoken to the user.
- A setup **backup** goes with the bookmark and recap data.

## Sequencing

C0, then C1 and C2 together (C2 needs the audio bus from C0), then C3, then C5, then C6 and C7. C4 can start whenever there's a dev/beta build and real hardware; it doesn't block the rest.

## Needs real hardware
- Does HSTN deliver true stereo to each temple? This decides whether ear routing is meaningful.
- Do the OS mono and balance settings apply over A2DP to HSTN?
- Which capture-button events HSTN sends, and whether it has an `ACTION` button.
- Is `KEY_PARAM_PAN` honoured by the installed Android TTS engine?
- In-stream mic latency end to end. This is only to confirm that live boost stays off the roadmap.

## Not doing
- Real-time sound amplification or anything sold as hearing help: latency and regulation rule it out.
- Users designing their own earcons: little value, and it adds load.
- Copying Meta's temple press-and-hold launcher: that gesture is reserved.
- Options that switch off "can't tell", the medicine and money refusals, or face blur.
