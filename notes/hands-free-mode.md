# Hands-free mode

Decided 2026-11-18. This replaces "voice-first from launch" in `ROADMAP.md` > Ground rules.

**By default, SpeakUp is a toolbox:** a touch app that shows what the DAT SDK and our tools can do on the glasses. **Hands-free mode is optional:** when it's on, the whole app can be used by voice alone, and no screen is needed. The phone screen can be off or locked, and the glasses may or may not have a display.

Both platforms (android-native, ios-native) build the same behaviour, described below.

## 1. Two modes

| | Toolbox (default) | Hands-free (opt-in) |
|---|---|---|
| Driven by | Taps. Screen readers (TalkBack/VoiceOver) work as usual | Voice. Taps still work |
| Mic | Off until the user taps the mic button, which listens for one command (push to talk) | Always listening while the app is in use: glasses speech first, then the phone's on-device recogniser |
| Speech | Tools speak their results (they're audio tools). No start-up narration and no idle reminders | Narrates start-up, connection, each screen change, errors and recovery. Idle reminders say what to say next |
| Dialogs | Normal | Never needed. A missing permission or setup step is explained aloud, together with what to do or the fallback. A step that truly needs a tap says so once, clearly |
| Screen | Required | Optional. The phone screen mirrors the state. A glasses display (Ray-Ban Display) shows a compact card when present |

The mode is one persisted setting (`handsFree: Bool`), which defaults to false.

**Exception, for BLV users:** on first run, if TalkBack or VoiceOver is running, hands-free starts **on**. The app says once: "Hands-free is on. Say 'hands-free off' for touch only."

## 2. Turning it on and off

- **Toggle**: a large, labelled switch on the home screen and in settings.
- **Voice**: "hands-free on", "start hands-free", "voice mode" (works with the toolbox's push to talk), and "hands-free off", "touch mode", "stop listening for good" (in hands-free mode).
- **Launch**: these open straight into hands-free mode and switch it on.
  - Android: the deep link `speakup://handsfree`, a launcher shortcut "Hands-free", and the intent extra `handsfree=true`.
  - iOS: an App Intent / App Shortcut "Start hands-free in SpeakUp" (Siri), and the URL `speakup://handsfree`.
- Each switch plays an earcon and is announced in both modes.

## 3. What hands-free covers

Everything a tap can do, a phrase can do. That covers at least:

- **Navigation**: "main menu", "what tools are there" / "list tools", "open <tool>" (plus the existing tool phrases), "back", "close", "close the app", "where am I" (current screen or tool, and connection state).
- **Help**: "help" / "what can I say" lists what works on the current screen, in short groups.
- **Connection**: "connect", "disconnect", "status" (glasses, stream, battery).
- **Settings**: "faster" / "slower", "short/normal/detailed answers", "glasses display on/off", "hands-free off".
- **Tools**: each tool's own grammar (unchanged).
- **Speech control**: "stop", "carry on", "say that again", and barge-in, all as today.

The toolbox's push to talk uses the same grammar, so a sighted user can try any command with one tap.

## 4. Display is optional

Spoken output is the source of truth. Displays mirror it and never carry information that wasn't spoken (unless the user asked for something longer, such as a full page of text).

**Phone screen.** Always mirrors the state. In hands-free mode it keeps working with the screen locked as far as the platform allows. The listening and narration loop must not depend on any UI being visible.

**Glasses display (`mwdat-display`, GA in DAT 1.0.1).** Used only when the connected device reports display support (`supportsDisplay`) and the user hasn't said "glasses display off". The card it shows:

- the tool or screen name;
- one line of state ("Listening", "Reading page 3", "Glasses disconnected");
- the last thing heard (shortened);
- up to three hint phrases ("Say: read · next · main menu").

Each `sendContent` replaces the whole screen, so updates are throttled (at most about 2 per second) and only sent when something changed. Display buttons, where present, map to the same commands as voice. Display errors are logged and spoken once, and never break the audio path. Testing uses the mock display (`MockDisplayKit`, `GlassesModel.META_RAYBAN_DISPLAY`).

HSTN has no display. The sink does nothing there.

## 5. Shape in code

- One mode store per app, observable, persisted. All voice auto-start and narration paths check it.
- A `HandsFreeSurface`-style output fan-out: speech (always), phone UI state (always), glasses display (when available). Tools publish a small card state and never talk to the display API themselves.
- The grammar for mode switching, navigation and help lives with the global grammar and is pure and unit-tested.
