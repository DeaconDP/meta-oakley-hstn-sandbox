# TODO

- [ ] Pair HSTN with the Meta AI app and turn on Developer Mode
- [ ] Register an app in the Wearables Developer Center and get the application ID
- [x] Build and run sdks/meta-wearables-dat-android/samples/CameraAccess against the Mock Device Kit (2026-10-21, emulator `HSTN_Mock_API34`; see notes/baseline-android-mock.md)
- [ ] Get an Android 12+ (API 31+) phone for real-HSTN testing. The USB Galaxy S7 is Android 8.0 and can't install the sample. (2026-11-06: a Galaxy A26, SM-A266B, Android 16, is on wireless adb and runs the Mock Device Kit tests; Meta AI isn't installed on it yet)
- [ ] Run CameraAccess against the real HSTN (needs both items above)
- [x] Step-2 benchmark in android-native on the mock (2026-10-22, notes/bench-android-native.md)
- [ ] Re-run `tracks/android-native/bench.sh` on a real phone + HSTN and confirm `route=a2dp`
- [x] Check which DAT 1.0 capabilities HSTN actually exposes (2026-10-22, docs-level; see notes/hstn-capabilities.md. Real-hardware confirmation still open)
- [x] Decide whether the iOS track matters (2026-10-22: yes. The Mac and the iPhone 13 Pro Max are ready, and the iPhone is a usable real-HSTN test phone; see tracks/ios-native/READINESS.md)
- [ ] Step-2 benchmark in ios-native on the Simulator mock (copy the iOS CameraAccess sample, port the BenchClock/TTS timing)
- [ ] Run CameraAccess / the iOS bench on the iPhone 13 Pro Max against the real HSTN (needs pairing + Developer Mode)
- [ ] Step-2 benchmark in flutter on the mock (install Flutter SDK first; see tracks/flutter/FEASIBILITY.md)

## Accessibility showcase (ROADMAP steps 4–8)
- [x] Research: SDK→BLV mapping, prior art, perception stack (2026-10-22; notes/a11y-*.md)
- [ ] Add a trigger→first-spoken-word metric (stream-frame grab → Claude Haiku 5.5 → streamed TTS) to HstnBench and the scorecard
- [ ] Verify Anthropic retention / ZDR terms for image inputs from official docs (notes/a11y-perception-stack.md > Privacy)
- [ ] Audio UX layer: earcons, verbosity levels, speech rate, barge-in, clause-chunked TTS queue, `USAGE_ASSISTANCE_ACCESSIBILITY` on Android
- [ ] Session narrator demo (doff/fold/battery/thermal announcements + session rebuild), tested with Mock Device Kit
- [ ] Read-aloud demo: ML Kit text recognition + framing guidance + uncertainty flags
- [x] Book-reader resolution experiment, synthetic pages + ML Kit on the emulator (2026-10-28, experiments/book-reader-resolution/results.md): GA works half a page at a time with crop + 2x upscale; full page needs Experimental FULL
- [ ] Book-reader: crop to the page + 2x upscale before ML Kit in `MlKitOcr` (the experiment's best prep)
- [ ] Book-reader: repeat the resolution check with real HSTN photos of real books
- [x] Book-reader demo, first build on the mock (2026-10-27, notes/book-reader-android.md): page-turn detection, spread split, header/page-number removal, pipelined capture during TTS, bookmark
- [ ] Book-reader on a real phone + HSTN: OCR time per page (16-19 s on the emulator), TTS over A2DP, page-turn signal
- [x] Book-reader voice-first: "Open Book Reader" launches with no taps, conversational on-device voice control, spoken replies, glasses mic with phone fallback (2026-11-03, notes/book-reader-android.md > Voice control)
- [x] Book-reader pitfalls spoken and recovered from: Bluetooth, not linked, disconnect/fold/reconnect, doff, battery, heat, update, covered/dark/no page/glare/obstructed, slow OCR (2026-11-03, notes/book-reader-android.md > Pitfalls)
- [ ] Pitfalls on real HSTN: metadata values, ImageCheck thresholds on real photos, fold → reconnect
- [ ] Voice on real HSTN: on-glasses speech alongside the stream + A2DP voice, echo from the open-ear speakers, restart after each capture; phone-recognizer fallback on a real phone (restart beeps); screen-off mic (FGS `microphone` type?)
- [ ] "Hey Meta, start Book Reader" voice invocation (Experimental; needs Developer Center approval)
- [ ] Look-closer demo with "can't tell" behaviour and on-device face blur before upload
- [ ] Low-vision magnifier view on the phone
- [x] Shared tools layer: lift connect/narrate, voice, pitfalls and the idle nudge out of BookReaderViewModel; open a tool by launcher, deep link or voice; latest stream frame for continuous tools (2026-11-06, notes/tools-layer.md: ToolHub, global grammar + switching by voice, five tools registered with stubs, ask-about-the-text seam, PageCamera.frames (preview copy, decoder fallback), ToolTestKit; book-reader hyphen failure on the A26 fixed)
- [x] Mail reader (sender, recipient, subject, amount and deadline; read all; abstain on unsure amounts) (2026-11-06, notes/mail-reader.md: on-device rules for sender/recipient/kind/date/subject/amount/deadline/references, envelopes, multi-page, read it all by sentence, money rule with per-character confidence and a missing-digit box check; JVM 124/0, MailToolTest 3/3 on the A26 mock)
- [x] Watch for text (continuous OCR, fuzzy words / exact numbers, earcon + left/ahead/right) (2026-11-06, notes/watch-for-text.md: two-of-four-frame confirmation, gone/reappear, near misses, alive tick, covered/dark/slow spoken; ML Kit 61-64 ms per 480x864 frame on the A26. Real HSTN not tried)
- [x] Labels and barcodes (on-device barcode, label read-out, Open Food Facts on request, no medicine doses) (2026-11-06, notes/labels-and-barcodes.md: ML Kit barcode search at 2 fps with geiger ticks, lookup by barcode number only, OCR quick jumps for dates/ingredients/cooking/allergens, medicine name and date only; on the mock, not yet on real HSTN)
- [x] Ask about the text (2026-11-06, notes/ask-about-the-text.md: on-device, no cloud needed: bundled WordNet 3.0 definitions with inflections, British/American spellings, "did you mean" from the text and "spell it"; who-is mentions, recap (survives a restart, kept with the bookmark), find + "next"; question barge-in, then "carry on". Claude Haiku 5.5 optional for open questions, only with an API key in local.properties; untested live)
- [x] Light and colour (brightness tone, colour naming with hedging) (2026-11-06, notes/light-and-colour.md: log-pitch probe tone with smoothing, relative levels, blink detection, OKLab colour naming with white balance, two-colour split and hedging)
- [x] Home voice menu: the camera screen is usable by voice with no tool open (normal icon, after closing a tool): connects and listens by itself, "read my mail" / "main menu" / "what can I say" / "close the app" (2026-11-12, notes/tools-layer.md > Home voice menu; JVM 284/0; `HomeVoiceMenuTest` written but not yet run on the A26)
- [x] Run `HomeVoiceMenuTest`, `ToolsTest`, `VoiceFirstLaunchTest`, `SetupVoiceTest`, `RegistrationButtonTest` after the home voice menu change (2026-11-16, emulator `HSTN_Mock_API34`, the A26 wasn't reachable: 9/9 after fixing `ToolHub.isSpeakingAside`, a flag cleared by the first finished aside while the next was still queued, so "Connecting…" ending made the welcome look finished and "read my mail" was dropped as echo; JVM 301/0. `VoiceFirstLaunchTest` was flaky once before the fix)
- [ ] Repeat those five on the A26
- [ ] Voice: end the session / unregister by voice, with a spoken confirmation for unregistering
- [ ] Offline eval harness: Mock Device Kit `setCameraFeed`/`setCapturedImage` + VizWiz/TextVQA subset, replay mode for CI
- [ ] TalkBack pass + WCAG 2.2 AA check of the companion UI
- [ ] Accessible onboarding and launch: spoken handoffs around the Meta AI registration and permission flows, speaker and camera check, practice-based tutorial, launch status line, spoken recovery messages, and App Intents / Back Tap / Magic Tap triggers (notes/a11y-onboarding.md)
  - [x] Android: voice setup before registration (spoken welcome on every launch, connect/help/repeat/open settings/quit by voice, spoken handoff to Meta AI and "not connected yet" on return, gentle reminders), mic + Nearby devices asked at launch with a spoken sentence first, permanent refusals explained instead of re-asked, snackbar errors spoken unless TalkBack is on (2026-11-12, notes/a11y-onboarding.md > Voice setup; JVM 297/0; SetupVoiceTest written, not yet run on a phone)
  - [ ] Run SetupVoiceTest and RegistrationButtonTest on the A26; try voice setup with the real Meta AI app (registration screens under TalkBack, return focus)
  - [x] iOS: spoken tips. After a quiet spell, the app says what to say next for the current screen. Gaps are 8 s, 30 s, 1 min and 2 min, then it stops, and the tips fade as the user learns them. There's an off switch in settings (2026-11-16, notes/a11y-onboarding.md > Spoken tips; unit tests 179/0 on the iOS 27 simulator; not yet tried on the iPhone)
- [ ] Real HSTN: check Meta AI registration and permission screens under VoiceOver, plus the open questions in notes/a11y-onboarding.md
- [ ] Mention the accessibility focus in README once the first demo runs

## Make it your own (notes/customisation-roadmap.md)
- [ ] C0: one settings schema shared by both platforms (rate on one 0.5–3× scale, per-tool overrides); migrate the existing Android prefs and the iOS `A11yPreferences` keys; merge the book rate into "main rate + book override"
- [ ] C0: one audio bus per platform (Android single AudioTrack mixer; iOS `AVSpeechSynthesizer.write` into the shared engine); check earcons still play within 100 ms
- [ ] C0: settings grammar: slower/faster, shorter/more detail, "keep that", "undo", "what's my setup", "reset speech", "lock settings"
- [ ] Fix the gap in notes/a11y-onboarding.md:69: iOS detail level and rate aren't in Settings; earcons can't be reached
- [ ] C1: speech presets (Brisk/Normal/Gentle), voice choice by voice with samples, per-tool verbosity, earcon on/off/volume/earcons-only, Android settings screen
- [ ] C2: balance, which ear for which sound, mono-aware cues (iOS `isMonoAudioEnabled`), Clear speech preset (DynamicsProcessing / AVAudioUnitEQ), conversation mode
- [ ] C3: aliases + macros by voice with conflict check, home-menu show/hide/reorder, wake word choice, tip pacing Fewer/Normal/Off
- [ ] C4 (Experimental): glasses controls map for `Capture`/`Select`/`Nav`, "what do my buttons do?", `LaunchApp` into a tool; find out whether Meta's press-and-hold shortcut can launch a DAT app
- [ ] C5: profiles (Home / Out and about / Reading), switch by voice, optional announced triggers, learned suggestions
- [ ] C6: detail dial + description preferences passed to the model
- [ ] C7: export/import setup code, helper view, backup with the bookmarks
- [ ] Real HSTN: per-temple stereo, OS mono/balance over A2DP, capture-button events, `KEY_PARAM_PAN` support

- [ ] iOS hands-free: `DATGlassesDisplayMockTests.testTheCardRendersOnTheMockDisplay` fails every run ("The display didn't start", 50–73 s) on a fresh iOS 27 simulator (2026-11-18; the other 228 unit tests pass)

## Voice from start to finish (notes/voice-journey-ios.md)
- [x] J1 iOS: end the session by voice ("goodbye", "end session", "close the app"): mic off first, goodbye, tool, reader, camera and ticks off, glasses session ended after the goodbye; Start again button, mic button or coming back starts again with a spoken line (2026-11-20, notes/voice-journey-ios.md > J1; unit tests 533 run, 2 failed and both fixed or rerun green; not tried on a real iPhone)
- [ ] J1 follow-up: Android's "close in the menu ends the session" rule on iOS, or decide against it; real-iPhone and glasses check of the goodbye
- [ ] J2 iOS: "switch to <tool>" phrases; "read a photo" / "read a file" open Import
- [ ] J3 iOS: check notes/a11y-onboarding.md:72 against the code; spoken welcome and "Use my voice" button without VoiceOver; spoken pre-prompt before mic, speech and camera alerts; camera asked at setup when "phone" is chosen
- [ ] J4 iOS: Import by voice; spoken "tap the mic to answer" in toolbox mode; error alerts always spoken; spoken Meta AI handoff and return; find out about "read my latest photo" with PhotoKit
- [ ] J5 iOS: natural voice, VoiceOver voice, sounds and tips by voice; "undo" / "put it back"; "what's my setup" (with C0/C1)
- [ ] J6 iOS: widget extension with a `ControlWidget` (Action button, Control Center, Lock Screen); spoken help on Back Tap and the Action button; "Hey Meta, start SpeakUp" in the Beta build
- [ ] J7 iOS: one `--voice-inject` UI test from launch to end session; real-iPhone runs with VoiceOver, with Voice Control (check "Tap Allow" on permission alerts) and with neither; blind testers

## Everyday value (notes/value-strategy.md)
- [x] V0 Android: phone camera mode (2026-11-19, notes/phone-camera.md): `PhoneCamera` (CameraX 1.5.3) behind a DAT-free `PageCamera`, glasses-only parts moved to `GlassesLink`, `CameraSourceSelector` switches at runtime, `cameraSource` AUTO/PHONE/GLASSES with a spoken fallback after the 20 s link wait, frame-difference `motion` for page turns, first-run "Use my phone's camera", Bluetooth only asked for glasses, phone pitfalls (permission, camera in use, too dark), torch and camera switch by voice. JVM 350/0. **Instrumentation not run** (emulator overloaded, adb killed by Unity's adb)
- [x] V0 iOS: phone camera mode (2026-11-19, notes/phone-camera-ios.md): `PhoneFrameSource` + `CameraSourceRouter`, setup leads with "Use my iPhone's camera", camera card with preview and torch, voice phrases, phone pitfalls. Unit tests 258 passed, 1 failed (the known display mock test). Not tried on a real iPhone
- [ ] V0: run `PhoneCameraTest` and the six launch/tool suites (`HomeVoiceMenuTest`, `ToolsTest`, `VoiceFirstLaunchTest`, `SetupVoiceTest`, `RegistrationButtonTest`, `HandsFreeModeTest`) on a healthy emulator or the A26; measure capture and frame timings
- [ ] V0: real-iPhone pass: camera start, preview, photo resolution, rotation, focus, torch, permission prompt, interruptions, VoiceOver and large text on the camera card
- [ ] V0: decide whether a spoken camera switch is saved (iOS saves it, Android keeps it for the run; the customisation rule says "keep that" saves) and whether AUTO switches back when glasses connect (iOS does, Android doesn't); make both match
- [ ] V0: OCR quality at 30 cm and the darkness threshold on real phones; re-run `experiments/book-reader-resolution` on phone frames
- [ ] V0: tools' own lines still say "glasses" in places; reword for the phone (Android ToolHub only rewrites connect/ready/lost/back)
- [x] V0 iOS: haptics for framing; big-text mirror of what's read; iOS dark warning before reading; plus "read me the next step" (2026-11-20, notes/phone-reading-ios.md). Unit 562/0, ReadAloud 2/2, audits 15/15, BigText 1/1. Not tried on a real iPhone
- [ ] V0 iOS: feel the framing haptics and tune the EV dark thresholds on a real iPhone, with BLV testers
- [ ] V0: store builds without the DAT SDK: ~~iOS second target~~ (done 2026-11-20, `SpeakUp` scheme, notes/phone-camera-ios.md); Android product flavour
- [ ] V0: TalkBack and VoiceOver walk-through of the new camera switch and setup buttons, ideally with blind and low-vision testers
- [x] V0/V4 iOS (2026-11-20, notes/tools-home-ios.md, notes/reach-ios.md): tools home with Read text, Mail, Labels, Watch, Ask and Light; Siri and Shortcuts per tool; photos and PDFs from the share sheet, Files and the in-app button, read through TextReader with next/previous/repeat/stop. Unit 525/0, UI 41 passed, 1 skipped, 0 failed. Not tried on a real iPhone
- [ ] V0 iOS: port the book reader
- [ ] V4 iOS: real-iPhone pass: Siri phrases, Action Button, share sheet, Open in from Files, PhotosPicker, document picker, App Group provisioning
- [ ] V1: "deal with this letter": deadline reminder, "what's due this week", letters log + export, plain-English explain (text only, optional Haiku), explain in my language
- [ ] V2: food check (expiry vs today, my allergens, cooking steps); recipe/manual "next step"
- [ ] V3: carer mode: consented, per-item, revocable sharing of letter summaries and the medication log
- [ ] V4: Quick Settings tile, widget, share target for images/PDFs; iOS Action Button / App Intents / Back Tap; job-first store copy and keywords
- [ ] Make on-device speech the default; check OpenAI TTS shutdown date (reported 2027-01-06) and replacement price
- [ ] Check whether the Play Store accepts the Android app with DAT linked
- [ ] Business: list grants (Meta AI Glasses Impact Grants, Microsoft AI for Accessibility, Innovate UK), contact BVA / Vision Ireland / ACB about a glasses Beta, sound out one UK bank or energy firm about sponsoring "understand your letter"

## Beyond reading (notes/use-cases.md)
- [ ] U1: Reminders tool: "remind me in 20 minutes / at 6 to …", "what reminders do I have", done/snooze/repeat; spoken on the glasses when `donState` says worn, otherwise a phone notification
- [ ] U1: Notes and "what was I doing?" (tool-action log + spoken notes, no frames)
- [ ] U1: Medication log ("I took it" / "did I take my evening pill?"), never says a dose
- [ ] U1: Routine checklists by voice ("leaving the house"), can call the Light tool
- [ ] U1: Labels: expiry check against today, allergen check against the user's list, abstain when cut off
- [ ] U1: Mail: scam-sign rules (urgent payment, gift cards, "final notice", bank details asked for)
- [ ] U1: Check whether a TalkBack/VoiceOver-read phone notification reaches the glasses over A2DP when SpeakUp isn't running
- [ ] U2: "Where am I" tool (GPS + reverse geocode + nearest junction); carve out the book reader's "where am I"
- [ ] U2: Markers and "take me back" (clock-face bearing and distance on request)
- [ ] U2: "Is this my bus?" (GTFS-realtime due time + watch-for-text confirmation); rideshare plate check
- [ ] U3: "What did they say?" tool: rolling 60 s in-memory transcript on the phone mic, addressed commands in caption mode, numbers digit by digit with a hedge
- [ ] U3: Name-called alert; sound recognition with MediaPipe YAMNet (phone mic GA, glasses PCM behind a flag)
- [ ] U4: Display spike on the mock (`META_RAYBAN_DISPLAY`, DAM enabled): status card, large-print text pages; find out whether camera stream + display run in one session
- [ ] U6: Head-height obstacle demo (Experimental), scored on misses, false alarms and latency
- [ ] Add the "Awareness, not safety" first-use line and the reserved attention earcon to the audio UX layer
