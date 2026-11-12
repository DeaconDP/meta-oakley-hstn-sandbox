# Launch, onboarding and setup for blind and low-vision users

Written 2026-10-30. Covers the path from "I have the glasses and the app" to "I can use it every day without sighted help". It applies the ROADMAP ground rules (audio-first, say how sure it is, privacy, not a mobility aid, WCAG 2.2 AA) to the first-run and every-run experience, which the demos in ROADMAP steps 5–6 assume already works.

**Core problem.** The DAT setup is a chain of handoffs: pair in Meta AI, turn on Developer Mode, register in our app, get sent to Meta AI to confirm, come back, get sent to Meta AI *again* to grant camera access, come back. Each handoff swaps apps, changes the VoiceOver focus, and loses context. Users already report that Meta's own setup tours don't work with screen readers (notes/a11y-prior-art.md > 2, "Availability / setup"). If we copy the CameraAccess sample's flow as is, a blind user will most likely get lost at the second handoff.

## The journey, stage by stage

| # | Stage | Whose UI | Main risk for BLV users | What we do |
|---|---|---|---|---|
| 0 | Pair HSTN with Meta AI, turn on Developer Mode | Meta | Setup tours don't work with screen readers. Developer Mode is a hidden toggle. Only one third-party app can be registered at a time in Developer Mode (notes/a11y-sdk-mapping.md > Distribution) | A plain-text "Before you start" guide (README and in-app) that names each control the way VoiceOver reads it. **Verify those labels on the real Meta AI app.** Be honest that this step may need sighted help once. In co-design sessions, a facilitator does it beforehand |
| 1 | Install | TestFlight / beta channel | Usually fine. TestFlight works with VoiceOver | Invite email gives the app's spoken name and one line on what to do first |
| 2 | First launch | Ours | The sample's `HomeScreenView` (see below) | A welcome screen that speaks first, asks at most one question, and explains the coming app switch *before* it happens |
| 3 | Registration (`startRegistration` → Meta AI → `handleUrl`) | Meta, then ours | User arrives in Meta AI without knowing what to press. On return there's no feedback. If they cancel or get lost, the app sits on "Connecting…" forever | Before: "You'll switch to the Meta AI app. Choose **Connect** (verify label). You'll come back here and hear a chime." After: earcon plus "Connected to Oakley Meta HSTN." A timeout and a cancel path that say what happened and offer a retry. Handle registration started from inside Meta AI with `handleUrl(_:onRegistrationRequest:)` so we can explain before continuing |
| 4 | Camera permission (Meta AI deeplink) | Meta, then ours | A second app switch. "Allow once" means another round trip every session | Ask during onboarding, not in the middle of the first real task. Explain the choice: "Allow always means you won't be sent to Meta AI each time." Report the result in speech. The phone's microphone and speech recognition (iOS dialogs) are asked for in the Voice control step, with the reason spoken first; see "Voice control" below. The wearable microphone (Meta AI) is asked for only from a settings button |
| 5 | Hardware check | Ours | User can't tell whether audio comes from the glasses or the phone, or whether the camera can see | **Speaker test**: phrase plus tone, then "Did you hear that in the glasses?" (Yes / No / Replay). This checks the A2DP route (open question 1 in notes/a11y-sdk-mapping.md). **Camera test**: grab a frame and say "camera sees clearly", "very dark", or "looks blocked". **Framing tip**: the camera is on the left side, so hold text a little to your right at about an arm's length |
| 6 | Learn by doing | Ours | Visual tours, long lectures, and disclaimer spam | Practice, not a tour. Play each earcon with its meaning. Practice the trigger and the interrupt once each. Pick a verbosity level by hearing short / normal / detailed versions of the same answer. Hear the one-time disclaimer (not a mobility aid, can be wrong) and the privacy line (what leaves the phone, and when). Users can skip any step, pick up where they left off, and replay it from Settings |
| 7 | Every launch after that | Ours (+ Siri / Meta) | Finding the app on the screen, unlocking, and working out what state it's in | One spoken status line on launch: either "Ready" or the single blocker and how to fix it (see Launch below) |
| 8 | Recovery | Ours, Meta | Errors only show up in a visual alert ("Something went wrong") | Each DAT error gets a spoken sentence with one next step (see Recovery) |

## What the CameraAccess sample does today (ios-native track)

These are the things to change when HstnBench turns into the showcase app. Nothing has been changed yet.

- `Views/HomeScreenView.swift`: the icon images aren't marked decorative, so VoiceOver reads asset names. Text is `.gray` 14 pt on white, about 3.3:1, which fails the AA 4.5:1 minimum for body text. Fixed `.system(size:)` fonts ignore Dynamic Type. The "Connecting…" change isn't announced.
- `ViewModels/WearablesViewModel.swift`: `connectGlasses()` has no timeout, so `.registering` can stick forever if the user backs out of Meta AI. Errors go only to `showError`.
- `CameraAccessApp.swift`: a generic `.alert("Something went wrong")`. VoiceOver reads it, but it gives no next step, and there's no earcon.
- `Views/RegistrationView.swift`: return from Meta AI is handled silently. This is the place to play the "back, connected" earcon and announcement.
- No `accessibilityLabel`, `accessibilityHint` or `accessibilityAction` anywhere in the app (grep finds none).

## Voice setup (android-native, 2026-11-12)

A user reported being forced onto the on-screen buttons before the app was connected. Everything before the camera screen now works by voice. Code in `setup/` under the HstnBench sources; strings in `res/values/strings_setup_voice.xml`.

- **Permissions at launch** (`MainActivity.checkPermissions`): Nearby devices (`BLUETOOTH_CONNECT`) and the microphone (`RECORD_AUDIO`) are asked for together, after a spoken sentence ("Android will ask two things… Choose Allow both times."; one-permission versions too). A refusal isn't asked again on each `onStart` in the same run, and a permission Android won't show again (asked before, no rationale) isn't asked at all: the setup screen says how to fix it in Settings instead. Refusing the mic doesn't block the DAT SDK.
- **The setup screen talks and listens on every launch**, not just voice-first ones (`SetupVoice`, an activity-scoped ViewModel; pure logic in `SetupFlow` and `SetupGrammar`). It waits 2.5 s after the permission check so an already-registered user doesn't hear it start. Welcome: "Welcome. To use your glasses, this app needs to connect to the Meta AI app once. Say connect to start, or say help." Variants say what's missing when the mic or Nearby devices is off. A tool opened by voice before setup is named first ("Mail reader needs a one-time setup first.").
- **Commands** (phone recogniser, on-device when available; the mic is off while the app speaks): *connect / set up / yes / start / register / pair / try again* → "Opening Meta AI. Approve the connection there, then come back." then `startRegistration`. *help / what can I say* → the list of commands. *repeat / say that again / pardon*. *open settings* → this app's Android settings. *quit / close the app / exit / goodbye* → "Closing…" and `moveTaskToBack`. *no / not now / don't connect* → "Okay. Say connect when you're ready…" (negation is checked first, so "don't connect" never opens Meta AI). Commands only count in utterances of up to 7 words; a short unknown phrase gets "Sorry, I didn't get that" at most every 8 s; longer chatter is ignored.
- **Quiet users** get two reminders (25 s, then 50 s later: "I'll stop reminding you now…"), then silence until they speak again.
- **Coming back from Meta AI still unconnected**: "You're back, but the app isn't connected to your glasses yet. Say connect to try again, or say help." If the app never left (Meta AI not installed, or the mock's failed registration), after 10 s: "Meta AI didn't open, or the connection didn't finish…". Returning to the app at other times: "Glasses setup. Say connect to start, or say help."
- **Handover**: once registered, the setup screen leaves the composition, and `SetupVoice.detach()` stops the recogniser and shuts its TTS down, so the registered screen's own voice mode has the mic.
- **Errors are spoken.** Snackbar errors go through `SetupVoice.announce` (TTS, accessibility audio) unless TalkBack is on (`isTouchExplorationEnabled`), in which case the snackbar is a polite live region and TalkBack reads it. The Nearby devices error now says how to fix it.
- **TalkBack fallback**: the Connect button stays, with the description "Connect my glasses. Opens the Meta AI app to approve the connection, then come back here." A visible status line shows "Listening…", "Speaking…" or "Microphone off…" and the last phrase heard.
- **Tests**: `SetupGrammarTest` (5) and `SetupFlowTest` (12) on the JVM; `SetupVoiceTest` (instrumented, mock with `initiallyRegistered = false`): welcome spoken, "help", "don't connect" doesn't register, "connect" speaks the handoff and reaches the registered screen with the setup mic released; a failed registration speaks "didn't open". Speech is injected with `SetupVoice.hear()` because the phone recogniser can't be fed audio in a test. **Not yet run on a phone** (the A26 wasn't reachable on 2026-11-12).
- **Not covered**: Meta AI's own registration screens (outside our control; open question 1 above), whether focus/TalkBack land sensibly on return, the phone recogniser's restart beeps on Samsung, and the real time from Wearables init to the registered state (the 2.5 s settle is a guess).

## Launch (every day)

The goal is to get from "I want to read this" to an answer without looking for an icon.

- **GA, shippable on iOS:**
  - An App Intent / App Shortcut ("Read this with …", "Look closer with …"), which can be run by Siri and Shortcuts, with **Back Tap** on the 13 Pro Max, or the Action Button on newer iPhones.
  - A Control Center / Lock Screen control.
  - **Magic Tap** (VoiceOver two-finger double-tap) as the main trigger inside the app.
  - Whether "Hey Siri" can be heard through the HSTN mics is **unverified**. Test it on hardware.
- **Experimental (dev/beta):** "Hey Meta, start {app}" voice invocation cold-launches the app straight into a mode. Avoid "AI" in the app name, and `sendSuccess`/`sendFailure` exactly once (notes/a11y-sdk-mapping.md). The capture button acts as a trigger.
- **The status line on launch** covers each state the app can be in:
  - "Ready."
  - "Glasses are in the case. Open the case or put them on."
  - "Glasses aren't connected. Check Bluetooth."
  - "Camera permission is off. Double-tap to fix in Meta AI."
  - "Battery 10 percent."

  It's spoken once, kept short, and repeatable on demand. It uses the device-state data the session narrator already needs (ROADMAP step 4).
- **Screen off:** blind users often keep the screen off or use Screen Curtain. Raw frames stop in the background on iOS, but `hvc1` keeps coming (notes/a11y-sdk-mapping.md > Screen off). A launch from Siri or Back Tap while locked has to work, so this is a must-test.

## Recovery messages

Every failure gets a spoken sentence, an earcon, and one action. It's never just a visual alert.

| DAT condition | Spoken message (draft) | Action |
|---|---|---|
| Registration cancelled or timed out | "Connection wasn't finished in Meta AI." | Try again |
| `deviceUpdateRequired` | "Your glasses need an update. This opens Meta AI." | `openFirmwareUpdate()` |
| DAT glasses app out of date | "Meta AI needs to update this app on your glasses. This opens Meta AI." | `openDATGlassesAppUpdate()` |
| Unregistered from the Meta AI side, or another app took the single Developer Mode slot | "This app is no longer connected to your glasses." | Reconnect |
| Camera permission revoked or "once" expired | "Camera access needs to be allowed again." | Request permission |
| Glasses taken off or folded mid-task | "Glasses removed, paused." / "Folded, session ended." | Resume automatically on re-wear (session narrator) |

## Choices to make once, with sensible defaults

- **Whose voice.** Changed 2026-11-03: the app's British woman's voice (`AppVoice`) is the default, with VoiceOver running too, because it reads through the glasses and the owner asked for it. "Use VoiceOver's voice" is the opt-out in settings; with it on, replies use `prefersAssistiveTechnologySettings = true` and status lines use `UIAccessibility` announcements (notes/a11y-perception-stack.md > TTS). VoiceOver still reads the screen itself in the user's own voice: focus changes, alerts and the onboarding text. Don't ask about this during onboarding. If no British woman's voice is installed, the app says and shows once how to download one (Settings > Accessibility > Spoken Content > Voices > English; the path still needs confirming on a real phone), since iOS can't download voices for an app.
- **Voice control.** On by default, off switch in settings. The setup step after Welcome explains the microphone and speech recognition in speech, then asks. Skipped setup and updates from older builds get the same explanation and dialogs on the main screen. A denial is spoken with the fix, and every button keeps working. Details and the audio rules are in `A11y/Voice/` and the header of `A11y/Core/A11yAudioSession.swift`.
- **Detect, don't ask.** Read `isVoiceOverRunning`, `isZoomEnabled` (via the accessibility settings APIs), the Dynamic Type size, Bold Text, Increase Contrast and Reduce Motion, and adapt to them. Only one question on the first screen: "Do you want a guided setup, or skip to the app?"
- **Low vision is its own path.** People using Zoom or large text want visual onboarding that scales: Dynamic Type up to AX5, targets of 60 pt or more, contrast of 7:1 or more in an optional high-contrast theme, no meaning carried by colour alone, `accessibilityIgnoresInvertColors` on camera previews, and the magnifier view (ROADMAP step 5) reachable from the first screen.
- **UI style.** Changed 2026-11-03: a playful, chunky style (SF Rounded, 3D buttons on a darker lip, an original vector mascot, a path of tiles, a streak and a daily goal), all in `A11y/Theme/` and `A11y/Progress/`. The look never carries meaning alone: every state is also words and shape. Bright faces take dark text, and the lip doubles as the outline, because a bright green alone is only about 2:1 on white. Lowest computed ratios, enforced by `ThemePaletteTests`: text on faces 7.80:1 light, 8.54:1 dark, 9.35:1 Increase Contrast light, 10.59:1 Increase Contrast dark; ink on page and cards at least 13.5:1, secondary ink at least 8.4:1; control boundaries at least 3.58:1 and progress fill on its track at least 3.42:1 in every variant. Main green `#63D420` with `#0B2200` text (8.82:1) and lip `#2E7D0C` (5.18:1 on white); dark `#7BE241` with the same text (10.29:1) on page `#101C24`. A missed day ends the current streak count but costs nothing else, and is never mentioned.
- **Sighted help is allowed, not assumed.** Step 0 may need it. Every step from 2 onward must be completable alone. A "hand to a helper" mode can show the Meta AI steps visually without hiding what's happening from the user.

## How to test it

- Cold install to first correct spoken answer, done with **VoiceOver and Screen Curtain on**, then with **Zoom at 5× and text at AX5**. Measure time, number of app switches, the number of times the user had to ask for help, and any point where they didn't know which app they were in.
- XCUITest `performAccessibilityAudit()` on every onboarding screen in CI.
- Drive the Mock Device Kit (`MockDeviceKitConfig(initiallyRegistered: false)`) through each recovery state and check that each one plays an earcon and speaks a message.
- Real HSTN: Meta AI's registration and permission screens under VoiceOver (labels, focus on return), the A2DP speaker test, a locked-screen launch, and whether Siri can be heard via the glasses.
- Co-design sessions (ROADMAP step 7): include a first-run session, not just task sessions. Onboarding is where users who would otherwise like the app give up on it.

## Open questions

1. How do Meta AI's registration and camera-permission screens read in VoiceOver, and where does focus land on return to our app?
2. Can "Hey Siri" be triggered through the HSTN microphones on iOS while a DAT session is idle?
3. Does a Siri / Back Tap launch while locked reach a working DAT stream without unlocking (hvc1 in the background)?
4. Does "Allow once" expire per session or per app launch? This decides how hard to push "Allow always".
