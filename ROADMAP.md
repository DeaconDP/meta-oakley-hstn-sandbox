# Roadmap

**Goal (set 2026-10-22):** show what the DAT SDK can do on Oakley Meta HSTN, with the main focus on accessibility for blind and low-vision (BLV) people. Research behind this plan:

- notes/a11y-sdk-mapping.md: which DAT capabilities enable which BLV features, what's GA vs experimental, and the constraints.
- notes/a11y-prior-art.md: existing products, what BLV users report, audio UX, ethics, evaluation.
- notes/a11y-perception-stack.md: on-device vs cloud models, latency budget, TTS, evaluation harness.

**Positioning.** Don't rebuild what Meta AI, Be My Eyes and Aira already do on the glasses: generic "describe the scene" and "call a human". Meta AI's 2025 "Detailed responses" setting already covers describing; Be My Eyes and Aira already run hands-free human calls. Showcase the gaps users report instead:

- word-for-word reading instead of summaries
- declining to answer instead of guessing
- adjustable verbosity and instant interruption
- watching for a named thing over time
- direction cues that follow head movement
- bystander privacy by default

(notes/a11y-prior-art.md > 1b, > Implications.)

**Strategy update (2026-11-18): from accessibility to everyday value.** Accessibility stays the quality bar, but SpeakUp now aims to be useful to as many people as possible, with or without glasses. Full reasoning: notes/value-strategy.md.

- **Phones first, glasses as the upgrade.** About 9M Meta glasses exist; phones number in the billions. Meta hasn't opened publishing for glasses apps, and the App Store rejects iOS apps that link DAT (docs `build-integration-ios` > Prerequisites). A phone-only build ships to both stores now; the glasses build stays in Meta's Beta channel.
- **Lead with jobs, not conditions:** "deal with your post", "no reading glasses needed", "hands full while cooking". The audiences behind them: presbyopia (~1.8bn), low literacy, second-language readers, older adults on many medicines, carers, ADHD, hearing loss, allergies, and blind and low-vision users as the core.
- **Sell what nobody else does.** Scene description, one-off OCR and translation are free elsewhere. Our edge: every word read honestly, letters turned into "what do I do and by when", continuous "watch for", reminders that follow on, a log you can trust, hands-free voice, offline and private.
- **Free core, sponsored and paid extras.** The reading and safety core stays free and offline. An optional Plus tier near cost (cloud reading, family sharing, multi-device). Sponsors with a duty to vulnerable customers (banks, energy firms, councils) for "understand your letter". Never take away something that was free.

## Ground rules (apply to every phase)

- **Hands-free mode (changed 2026-11-18).** By default SpeakUp is a touch toolbox for the SDK and our tools, with a push-to-talk mic. Voice-only use is an opt-in **hands-free mode**: switched on by toggle, by voice, by `speakup://handsfree` or a launcher shortcut / Siri shortcut, and on first run when TalkBack/VoiceOver is running. In hands-free mode the rule below applies in full, no screen is needed, and Ray-Ban Display glasses show an optional card that mirrors the speech. (notes/hands-free-mode.md)
- **Voice-first, both ways, in hands-free mode.** (Decided 2026-11-03, scoped to hands-free 2026-11-18.) A blind user can't find buttons on a screen, so every feature is fully usable by voice alone. They open it by voice ("Hey Google, open Book Reader"; later "Hey Meta, start …"), it connects with no taps or dialogs and narrates each step, and they control it conversationally with natural phrasing ("hang on", "say that again", "a bit faster", "where am I", "help"). Every response is spoken, and the user can talk over it at any time. The phone screen mirrors the state for sighted helpers, low-vision users and TalkBack users, but it is never the only way to do something. Understanding runs on-device (no cloud). Mic: the glasses' own speech recognition when available, otherwise the phone's on-device recogniser. The Bluetooth hands-free mic isn't used, because it would drop all output to mono. (notes/book-reader-android.md > Voice control)
- **Audio-first UX.** Every action plays an earcon within 100 ms. Silence is never how a failure is reported. Users can set verbosity (short / normal / detailed) and speech rate, and can cut speech off at any time. App audio has to work alongside TalkBack/VoiceOver; on Android it is tagged as accessibility audio. (notes/a11y-prior-art.md > 3, notes/a11y-perception-stack.md > TTS)
- **Say how sure it is.** If the model isn't confident, it says "can't tell" and asks for a better frame instead of guessing. It refuses outright on medication doses and on money it can't verify, and abstains on expiry dates and allergens it can't read in full. Medication reminders never state or change a dose.
- **Privacy.** The cloud is called only on an explicit trigger, never continuously. Faces are blurred on the phone before upload, and no frames are stored. No face recognition and no identifying people (BIPA, GDPR Article 9, EU AI Act Article 5).
- **Awareness, not safety.** (Widened 2026-11-18 from "Not a mobility aid".) Navigation, alerts and anything about obstacles, traffic or sounds are presented as orientation and awareness help, never as a mobility aid, a safety device, or a replacement for a cane, guide dog or O&M training. We never say an area or crossing is safe, never give "all clear" messages, and never detect pedestrian signals or say when to cross. First use and "help" say once that silence doesn't mean there's no hazard.
- **Alert budget.** Outdoors, callouts and alerts are short, rate-limited, interruptible, and dropped when stale (over 2 s old). One "attention" earcon is reserved for alerts. Speech the user asked for is never queued behind an ambient alert.
- **Ephemeral listening.** Transcripts, sound detections and location history stay in memory on the phone for a few minutes at most, and are never uploaded or saved, unless the user saves a note or a marker.
- **Companion phone UI meets WCAG 2.2 AA** and is fully usable with TalkBack and VoiceOver.
- **Production path stays separate.** Ship-ready features use only GA APIs: the camera stream, in-stream photo, device state, and OS Bluetooth audio. Experimental APIs (inputs, voice invocation, Motion, in-stream mic) go behind a flag in dev/beta builds. **Exception: on-glasses speech** is used by default wherever the build channel allows it, because voice control is the default. Where it's unavailable (production builds, no permission, no recogniser), the app falls back to the GA path, Android's on-device recogniser on the phone mic, so voice works in every build.

## Phases

1. **Baseline**: run the official CameraAccess sample on Android against the Mock Device Kit, then on the real HSTN.
   - Mock: done 2026-10-21 (notes/baseline-android-mock.md).
   - Real HSTN: blocked on an Android 12+ phone and Developer Mode pairing.
2. **Benchmark in each track**: build the same benchmark task (notes/sdk-comparison.md) in each track.
   - android-native on mock: done 2026-10-22 (tracks/android-native/HstnBench, notes/bench-android-native.md). Still needs a real-HSTN run to confirm TTS reaches the glasses speakers over A2DP.
   - Feasibility checked 2026-10-22, all go: ios-native ready now (tracks/ios-native/READINESS.md), flutter ~1.5 days (tracks/flutter/FEASIBILITY.md), unity-bridge ~4 days mock-only (tracks/unity-bridge/FEASIBILITY.md).
   - Order: ios-native first (it also enables real-HSTN testing on the iPhone 13 Pro Max), then flutter. unity-bridge is deferred.
   - **New metric:** trigger → first spoken word, target ≤ 1.5 s, using the latest stream frame rather than `capturePhoto` (capturePhoto took ~3.9 s on the mock). It goes in the scorecard next to the existing metrics. (notes/a11y-perception-stack.md > Latency budget)
3. **Pick a winner**: fill in the scorecard and commit to one track. The ground rules above count as criteria: TalkBack/VoiceOver coexistence, an on-device OCR/vision path, and background operation with the screen locked.
4. **Shared accessibility core** (on the chosen track, android-native until step 3 decides)
   - Audio UX layer: earcon set, verbosity levels, speech rate, interrupt/barge-in, a queue that splits streamed model text into clauses for TTS, and screen-reader coexistence.
   - Session narrator (demo 4 in notes/a11y-sdk-mapping.md): speaks "glasses removed, paused", "folded, session ended", battery thresholds and thermal step-down. It also rebuilds the session when the hinges reopen. GA only.
   - Frame pipeline: keeps the stream warm and grabs the sharpest recent frame, with optional face blurring on the phone.
   - Voice layer, shared by every demo: mic selection with fallback, an on-device command grammar, an echo guard (the mic hears our own speech), barge-in on partial results, and spoken start-up narration. The first version is in the book reader (`bookreader/VoiceControl.kt`, `book/VoiceCommands.kt`); lift it out when the second demo needs it.
   - Accessible phone UI: large trigger buttons, settings, a WCAG 2.2 AA pass, and TalkBack/VoiceOver tests.
   - Onboarding and launch: first run with the screen reader on, spoken handoffs to and from Meta AI, a hardware check, launching without the screen, and spoken recovery messages. (notes/a11y-onboarding.md)
5. **Showcase demos, GA-only (shippable)**
   - **Read it aloud (word for word)**: on-device OCR with spoken framing guidance ("move left", "text cut off on the right"), next/previous sentence, and uncertain words flagged. Refuses on doses and money it can't verify.
   - **Book reader** (extends Read it aloud): reads a printed book page by page. It detects page turns, splits two-page spreads, drops headers and page numbers, and captures the next page while the current one is spoken. A resolution experiment comes first: the GA in-stream photo (960x1440 on the mock) may be too low-res for a full page of book print, and FULL 12 MP photo is Experimental. (notes/book-reader.md)
   - **Look closer**: on-demand description from a cloud model, Claude Haiku 5.5 by default. Sonnet 5.5 is used for a "detailed look" that captures a photo after a spoken "hold still". It says "can't tell" instead of guessing.
   - **Low-vision magnifier**: the glasses camera full-screen on the phone with zoom, high-contrast and invert filters, and freeze frame.
   - **Everyday tools** (added 2026-11-06). Each one reuses the book reader's OCR, image checks, voice layer and spoken pitfalls, and opens by voice on its own ("Hey Google, open Mail Reader") or from any other tool ("read my mail").
     - **Mail reader**: "what is this letter?" gives the sender, who it's for, what it's about, and any amount or deadline, then "read it all" reads every word. It sorts bills, bank, official, personal and adverts by fixed rules on the phone. It refuses to say an amount whose digits it isn't sure of.
     - **Watch for text**: "tell me when you see 42" (a bus number, platform, room number or shop name). It runs OCR on the stream continuously, matches loosely for words and exactly for numbers, plays an earcon, then says where the text is: "42, on your right". It keeps watching until told to stop. Orientation help only.
     - **Labels and barcodes**: on-device barcode scanning, plus reading the label word for word ("best before", cooking instructions). A product lookup (Open Food Facts) happens only when the user asks. Medicine gives the name only, never doses.
     - **Ask about the text**: questions about what was just read ("what does *ephemeral* mean?", "who's Mr. Bennet?", "what happened last time?"). Only the OCR text goes to Claude (Haiku 5.5), never an image, and only when asked. Answers are short and spoken, and it says when the text doesn't say.
     - **Light and colour**: a light probe whose tone rises with brightness ("is the light on?"), and "what colour is this?" naming the colour in the middle of the view. It hedges in dim or tinted light.
     - Shared foundation done 2026-11-06 (notes/tools-layer.md): `tools/ToolHub` (voice, pitfalls, reminders, switching by voice), global grammar, all five tools registered (launcher, deep link, extra, camera-screen button, voice), the ask seam (RecentText + AskAboutText stub), stream frames for continuous tools, and a test kit for the mock.
   - **Later everyday tools**, not started: a book library (identify by ISBN or cover, a bookmark per book, "remember this" quotes), a large-print phone view that follows the speech, braille display output via TalkBack, export to text/EPUB, appliance displays (seven-segment digits need their own model), banknotes (dedicated classifier, strict abstention), QR/NaviLens at a distance, and finding the user's own objects (ORBIT-style).
6. **Hands-free and spatial demos, experimental (dev/beta only)**
   - Trigger layer: capture-button short press = look, hold = read. "Hey Meta, start {app}" opens straight into a mode (this is the glasses-side twin of the "Open Book Reader" launcher entry; it needs Developer Center approval).
   - Voice Q&A about the scene: the glasses' own speech recognition plus the current frame. This keeps audio on A2DP; the Bluetooth hands-free mic would force mono.
   - **Watch for X**: an on-device detector keeps looking for a named object (door, cup, bus number) and plays an earcon when it appears.
   - **Object finder**: earcon pitch follows the object's horizontal offset, and the glasses' gyro keeps it stable between frames. Orientation help only.
7. **Evaluation**
   - Offline harness: feed the Mock Device Kit recorded video and photos (`setCameraFeed` / `setCapturedImage`) plus VizWiz / TextVQA / ORBIT samples resized to the HSTN stream sizes. Score accuracy, correct "can't tell" answers, OCR error rate, latency and cost. CI replays recorded model responses; a nightly job runs against the live model. (notes/a11y-perception-stack.md > Offline evaluation harness)
   - Real-hardware pass: answer the open questions in notes/a11y-sdk-mapping.md > Open questions (A2DP route, screen-locked streaming, magnetometer, how the capture button maps).
   - Co-design sessions with BLV participants, paid and with accessible consent, recruited via ACB / NFB / Braille Institute / Carroll Center. Measure task success, number of turns, SUS, NASA-TLX and trust, and count wrong answers separately from declined ones. (notes/a11y-prior-art.md > 5)
8. **Publish the showcase**: README demo section with audio/video captures, a write-up of results, and the ship-ready checklist before tagging a release.

## Make it your own (cross-cutting, added 2026-11-18)

Deep customisation, prompted by Meta's announcements of hearing enhancement, audio balance and mono audio, customisable controls, and detailed responses. Every setting can be changed by voice in the moment, and is announced, undoable and lockable. Full plan: notes/customisation-roadmap.md.

- **C0 Foundation:** one settings schema for both platforms, one audio bus per platform, and a settings grammar ("slower", "keep that", "undo", "what's my setup").
- **C1 Your voice:** speech presets, voice choice, per-tool verbosity, earcon options, and a settings screen on Android.
- **C2 Your ears:** balance, which ear for which sound, mono-aware cues, the "Clear speech" preset (for our own voice only, never sold as hearing help), and a conversation mode.
- **C3 Your words:** aliases, macros, home-menu order, wake word, and tip pacing.
- **C4 Your buttons (Experimental):** glasses `Inputs` mapped to SpeakUp actions, and "Hey Meta, start SpeakUp mail". Tap and tap-and-hold on the temple belong to Meta and can't be remapped.
- **C5 Your profiles:** Home, Out and about, and Reading. Switch by voice, with automatic triggers optional and announced.
- **C6 Your descriptions:** a detail dial and description preferences. The "can't tell" answer and the refusals stay on.
- **C7 Share and carry:** export and import a setup, and a helper view.

## Everyday value (added 2026-11-18, comes before U2–U6)

Plan: notes/value-strategy.md > 6.

- **V0 Glasses optional:** every tool runs on the phone's own camera, mic, speaker and screen. Android: `PhoneCamera : PageCamera` with CameraX, chosen by a setting; bypass the registration gate, make Bluetooth optional, skip glasses health and reconnect narration; a motion signal for book page turns; re-tune for phone optics (about 1–2 weeks). iOS: `PhoneFrameSource : ReadFrameSource`, and a **store build without the DAT SDK**. Switch cameras by voice mid-task ("use the phone"). Big-text mirror of what's read. **Built 2026-11-19 on both platforms** (notes/phone-camera.md, notes/phone-camera-ios.md); not yet run on a real phone, and the store builds without DAT are still to do.
- **V1 Letters first:** grow the mail reader into "deal with this letter": who, what, how much, by when, scam signs, then a reminder before the deadline, "what's due this week", plain-English explain and "explain in my language", a letters log with export.
- **V2 Daily triggers:** U1 reminders and medication log, food check (expiry against today, your allergens, cooking steps), "read me the next step" for recipes and manuals.
- **V3 Carer mode:** with the user's consent, share letter summaries and the medication log with a helper, asynchronously; "ask a helper" hand-off.
- **V4 Reach:** one-tap and one-word entry (Quick Settings tile, widget, share sheet for photos, screenshots and PDFs; iOS Action Button, App Intents, Back Tap), more languages, store copy that leads with jobs.
- **Built on iOS 2026-11-20 (V0, V4):** a tools home with six tools on the phone camera, a store build without DAT, Siri and Shortcuts for every tool, and photos and PDFs from the share sheet, Files or the in-app button, read like a camera page. All unit and UI tests pass on the Simulator; not yet on a real iPhone (notes/tools-home-ios.md, notes/reach-ios.md).
- **V5 Glasses as premium:** the same tools hands-free once Meta opens publishing; meanwhile a Beta with blind glasses owners from Meta's programmes (BVA, VA Blind Rehab, Vision Ireland, ACB).
- **Business track:** apply for grants, pilot one UK letter sponsor (bank or energy firm), talk to Meta's accessibility team about the curated catalogue.

## Beyond reading: new use-cases (added 2026-11-18)

Glasses are good for two things: **hands-free** (camera, mic and speakers at head height while the hands are busy) and **heads-up** (a glance at a lens, display glasses only). HSTN covers the first; Meta Ray-Ban Display adds the second. SpeakUp stays audio-first on both, and a display mirrors the audio. Full catalogue, prior art and what Meta already covers: notes/use-cases.md.

- **U1 Reminders and memory (GA):** time reminders spoken on the glasses when worn, "what reminders do I have", notes and "what was I doing?", medication log ("did I take my evening pill?", never a dose), routine checklists ("leaving the house"). Ships with the static awareness checks: expiry dates and allergens in Labels, scam signs in Mail.
- **U2 Orientation (GA):** "where am I", markers and "take me back", "is this my bus?" (transit due time plus watch-for-text confirmation), rideshare plate check. Soundscape-style callouts afterwards; head-relative panning behind the Motion flag.
- **U3 Listening help (GA on the phone mic, glasses mic Experimental):** "what did they say?" replay of the last 60 s, name-called alert, sound recognition (alarm, doorbell, siren, kettle) with YAMNet, transcript to a braille display for deaf-blind users.
- **U4 Display mirror (Meta Ray-Ban Display, `mwdat-display` is GA, needs DAM):** glanceable status, large-print OCR text paced by the user, summary cards for labels, mail and reminders, a contrast-boosted still. First test whether the camera stream and display run in one session.
- **U5 Everyday and sport:** kitchen coach ("is it browned?", step tracking), step-by-step coach from a manual, one-command hand-off to a human helper, spoken workout stats, posture cues, guided-run audio.
- **U6 Research flags (Experimental, never production):** head-height obstacle demo measured on misses and false alarms, IMU form coaching, camera-based "where did I put my keys?".
- **Not building:** live captions, translation, walking navigation and the viewfinder on Display (Meta ships them); crossing help, vehicle and kerb warnings (awareness rule, and not technically reliable); emotion coaching and person-triggered reminders (faces and identity).

## Deferred
- 2026-11-18: Approaching-vehicle and step/kerb warnings. A 1.5 s pipeline at 10 m/s means 15 m travelled, the camera can't see sideways or behind, and it sees the ground poorly. Conflicts with "Awareness, not safety". `notes/use-cases.md` > Awareness alerts
- 2026-11-18: Live captions, translation and walking navigation in the Display lens. Meta already ships them. Revisit only for something Meta lacks (braille output, phone-media captions). `notes/use-cases.md` > 2
- 2026-11-18: Glasses web apps. They get no camera and no mic, and nothing documented links them to a DAT phone app. `notes/use-cases.md` > 1
- 2026-11-18: Live sound amplification as a hearing-enhancement equivalent. The glasses→phone→A2DP round trip is likely over 300 ms against about 10–20 ms for hearing aids, and it falls under hearing-device regulation. `notes/customisation-roadmap.md`
- 2026-10-21: Real-HSTN baseline run. The only phone available is a Galaxy S7 (API 26), and the sample's minSdk is 31. `TODO.md:6`
- ~~2026-10-21: Didn't check whether `GlassesModel` has an Oakley HSTN entry.~~ Resolved 2026-10-22: `OAKLEY_META_HSTN` exists in both SDKs (notes/hstn-capabilities.md).
- 2026-10-22: Real-HSTN android-native benchmark and A2DP route check. Blocked on the same Android 12+ phone. `TODO.md`
- 2026-10-22: Unity bridge build deferred. It can't beat android-native on the benchmark, so it's only worth ~4 days if step 4 needs 3D/networked content. `tracks/unity-bridge/FEASIBILITY.md`
- 2026-10-22: Unanswered HSTN questions (action button / Neural Band, magnetometer, real-world stream res/fps over BT, whether firmware accepts experimental features). Needs real hardware. `notes/hstn-capabilities.md`
- 2026-10-22: `~/.ssh/config` has the wrong user for macbook-pro. Not changed, since it's outside the repo. `tracks/ios-native/READINESS.md`
- 2026-10-22: Generic "describe the scene" and human-call demos dropped; Meta AI, Be My Eyes and Aira already do this on the glasses. `notes/a11y-prior-art.md:26`
- 2026-10-22: Face recognition / identifying people out of scope (BIPA, GDPR Article 9, EU AI Act Article 5). Person-presence detection only. `notes/a11y-prior-art.md:75`
- 2026-10-22: Head-drop / fall-alert prototype (demo 8) deferred. It looks like a safety claim, and Motion is experimental. `notes/a11y-sdk-mapping.md:45`
- 2026-10-22: Compass heading on the glasses. The magnetometer is likely unavailable on V128 firmware, so use pitch from gravity and the phone compass for heading until real hardware shows otherwise. `notes/a11y-sdk-mapping.md:58`
- 2026-10-22: Offline on-device description model (Gemini Nano / Apple Foundation Models). Limited devices and still beta, so the cloud model is the default for now. `notes/a11y-perception-stack.md:86`
- 2026-10-22: Anthropic data-retention / ZDR terms for bystander images are unverified (press-only sources). Check official terms before any cloud upload leaves dev. `notes/a11y-perception-stack.md:76`
