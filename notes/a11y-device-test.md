# Device test: HSTN Reader on iPhone + real HSTN

Written 2026-10-30. The checklist for the first real-hardware run (ROADMAP step 7, "Real-hardware pass") and for a sighted developer's own VoiceOver and Zoom walkthrough before any BLV participant sees the app. It answers the open questions in notes/a11y-onboarding.md and notes/a11y-sdk-mapping.md > Open questions. Write the results under each item with the date.

## 0. Before you start
- iPhone 13 Pro Max, current iOS. HSTN paired in the Meta AI app, Developer Mode on (TODO.md).
- Install from Xcode with the `CameraAccess` scheme, Debug. Delete any earlier install so first-run setup shows.
- Note the firmware version of the glasses and the Meta AI app version.
- Have a printed page, a medicine box, a banknote and a dim room available.

## 1. Walkthrough with VoiceOver and Screen Curtain
Turn on VoiceOver, then Screen Curtain (three-finger triple-tap). Don't look at the screen. For each step, note where you got lost, anything silent, anything spoken twice, and any control with a wrong or missing label.

- [ ] **Welcome:** the first thing heard makes sense. "Guided setup" and "Skip" are both reachable.
- [ ] **Learn the sounds:** each sound can be told apart from the others through the glasses speakers. Note any pair that sounds the same.
- [ ] **Speaker test:** with the glasses on, the screen says the output is "glasses", and the test phrase plays in the glasses, not the phone. Then turn Bluetooth off and repeat: the screen says "phone speaker" and the "No" fixes make sense.
- [ ] **Detail level:** the three samples sound clearly different. With VoiceOver on, speech follows VoiceOver's rate.
- [ ] **Safety and privacy:** they're read once and not repeated on the next launch.
- [ ] **Connect → Meta AI:**
  - Write down exactly what VoiceOver reads on Meta AI's confirm screen.
  - Write down the real label of the button to press (update `SpokenMessage.beforeMetaAIHandoff` if it isn't "Connect").
  - When you're back in the app, note where focus lands and whether the chime and "Connected to …" play.
- [ ] **Cancel path:** start again, press Back or Cancel in Meta AI, return. You should hear "Connection wasn't finished…" within about 5 s, and Try again should work.
- [ ] **Camera permission:**
  - The explanation plays before the switch to Meta AI. Write down the labels of Meta AI's permission screen.
  - Choose "Allow once" and note when it expires (per session or per app launch). This answers open question 4 in notes/a11y-onboarding.md.
- [ ] **Camera screen:**
  - The status line plays once on arrival.
  - Magic Tap starts the session, then the preview, then takes a photo.
  - "Status" and "Repeat last" work from the actions rotor.
  - Escape closes the photo preview.
- [ ] **Glasses state:** while the app is open, take the glasses off ("removed, paused"), fold them ("folded, session ended"), then unfold them and put them back on. Note any line that's missing, late or doubled.
- [ ] **Recording:** start, stop, then start again quickly. The second video must have audio from the glasses mic. This checks the session fix.
- [ ] **Speech order:** take a photo just after "Camera on" begins. "Photo captured." mustn't overlap another line, and the line after it mustn't be cut off.

## 2. Launch without the screen
- [ ] Set up Back Tap (Settings > Accessibility > Touch > Back Tap > Double Tap) → the "Look with HSTN Reader" shortcut. With the phone locked and in a pocket, double-tap the back. Note what's heard and whether the phone has to be unlocked.
- [ ] Say "Hey Siri, HSTN Reader status" with the phone locked. Note whether the answer is heard in the glasses, and whether Siri hears you through the glasses mics or only through the phone. This answers open question 2.
- [ ] "Hey Siri, look with HSTN Reader" on a cold launch (force-quit the app first): the status line must be correct, not "not connected", within 2 s. If the glasses take longer than 2 s to report, note how long.
- [ ] With the screen locked and the app in the background during a session: do frames keep coming (hvc1) or does the session end? This answers open question 3.

## 3. Low vision: Zoom and large text
- [ ] Zoom on at 5×, plus Settings > Accessibility > Display & Text Size > Larger Text at the largest size. Every screen of setup and the camera screen should be readable without text cut off or overlapping. Note anything you have to pan sideways to read.
- [ ] Turn on Increase Contrast, Bold Text, Smart Invert, Reduce Motion and Reduce Transparency together. Check that nothing becomes unreadable and that the camera preview isn't inverted.

## 4. Audio and latency
- [ ] Measure from tap to the start of the sound in the glasses (film it with the phone's screen and the glasses in shot, or by ear with a stopwatch app). The target is under 100 ms plus the Bluetooth delay. Write down the Bluetooth delay separately if you can hear it.
- [ ] Play music on the glasses, take a photo, and note whether the music ducks and then comes back within about 2 s.
- [ ] Run `tracks/ios-native/bench.sh` against the real glasses if the bench can target a device, and record `route=` (it should be `a2dp`).

## 5. Read it aloud
Only once the demo is built (ROADMAP step 5).
- [ ] Printed page at arm's length: read word for word, and note the time to the first word.
- [ ] Page shifted to the right (the camera is on the left): framing guidance names the right direction.
- [ ] Medicine box and banknote: unclear numbers are refused, not guessed.
- [ ] Dim room: you're told it's too dark instead of hearing nothing.

## Results
(Date, iOS version, firmware, Meta AI app version, then findings per item. Turn each problem into a TODO.md item.)
