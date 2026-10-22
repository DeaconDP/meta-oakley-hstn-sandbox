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

## Ground rules (apply to every phase)

- **Audio-first UX.** Every action plays an earcon within 100 ms. Silence is never how a failure is reported. Users can set verbosity (short / normal / detailed) and speech rate, and can cut speech off at any time. App audio has to work alongside TalkBack/VoiceOver; on Android it is tagged as accessibility audio. (notes/a11y-prior-art.md > 3, notes/a11y-perception-stack.md > TTS)
- **Say how sure it is.** If the model isn't confident, it says "can't tell" and asks for a better frame instead of guessing. It refuses outright on medication doses and on money it can't verify.
- **Privacy.** The cloud is called only on an explicit trigger, never continuously. Faces are blurred on the phone before upload, and no frames are stored. No face recognition and no identifying people (BIPA, GDPR Article 9, EU AI Act Article 5).
- **Not a mobility aid.** Anything involving obstacles or direction is presented as orientation help, never as a replacement for a cane or guide dog.
- **Companion phone UI meets WCAG 2.2 AA** and is fully usable with TalkBack and VoiceOver.
- **Production path stays separate.** Ship-ready features use only GA APIs: the camera stream, in-stream photo, device state, and OS Bluetooth audio. Experimental APIs (inputs, speech, voice invocation, Motion, in-stream mic) go behind a flag in dev/beta builds.

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
   - Accessible phone UI: large trigger buttons, settings, a WCAG 2.2 AA pass, and TalkBack/VoiceOver tests.
5. **Showcase demos, GA-only (shippable)**
   - **Read it aloud (word for word)**: on-device OCR with spoken framing guidance ("move left", "text cut off on the right"), next/previous sentence, and uncertain words flagged. Refuses on doses and money it can't verify.
   - **Look closer**: on-demand description from a cloud model, Claude Haiku 5.5 by default. Sonnet 5.5 is used for a "detailed look" that captures a photo after a spoken "hold still". It says "can't tell" instead of guessing.
   - **Low-vision magnifier**: the glasses camera full-screen on the phone with zoom, high-contrast and invert filters, and freeze frame.
6. **Hands-free and spatial demos, experimental (dev/beta only)**
   - Trigger layer: capture-button short press = look, hold = read. "Hey Meta, start {app}" opens straight into a mode.
   - Voice Q&A about the scene: the glasses' own speech recognition plus the current frame. This keeps audio on A2DP; the Bluetooth hands-free mic would force mono.
   - **Watch for X**: an on-device detector keeps looking for a named object (door, cup, bus number) and plays an earcon when it appears.
   - **Object finder**: earcon pitch follows the object's horizontal offset, and the glasses' gyro keeps it stable between frames. Orientation help only.
7. **Evaluation**
   - Offline harness: feed the Mock Device Kit recorded video and photos (`setCameraFeed` / `setCapturedImage`) plus VizWiz / TextVQA / ORBIT samples resized to the HSTN stream sizes. Score accuracy, correct "can't tell" answers, OCR error rate, latency and cost. CI replays recorded model responses; a nightly job runs against the live model. (notes/a11y-perception-stack.md > Offline evaluation harness)
   - Real-hardware pass: answer the open questions in notes/a11y-sdk-mapping.md > Open questions (A2DP route, screen-locked streaming, magnetometer, how the capture button maps).
   - Co-design sessions with BLV participants, paid and with accessible consent, recruited via ACB / NFB / Braille Institute / Carroll Center. Measure task success, number of turns, SUS, NASA-TLX and trust, and count wrong answers separately from declined ones. (notes/a11y-prior-art.md > 5)
8. **Publish the showcase**: README demo section with audio/video captures, a write-up of results, and the ship-ready checklist before tagging a release.

## Deferred
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
