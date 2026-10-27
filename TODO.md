# TODO

- [ ] Pair HSTN with the Meta AI app and turn on Developer Mode
- [ ] Register an app in the Wearables Developer Center and get the application ID
- [x] Build and run sdks/meta-wearables-dat-android/samples/CameraAccess against the Mock Device Kit (2026-10-21, emulator `HSTN_Mock_API34`; see notes/baseline-android-mock.md)
- [ ] Get an Android 12+ (API 31+) phone for real-HSTN testing. The USB Galaxy S7 is Android 8.0 and can't install the sample
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
- [ ] Book-reader resolution experiment: ~20 book pages through the mock at stream LOW/MEDIUM/HIGH, in-stream capturePhoto, and standalone photo LARGE/FULL, ML Kit OCR, CER per setting (notes/book-reader.md > Experiment)
- [ ] Book-reader demo: page-turn detection, spread split, header/page-number removal, pipelined capture during TTS, fold-as-bookmark
- [ ] Look-closer demo with "can't tell" behaviour and on-device face blur before upload
- [ ] Low-vision magnifier view on the phone
- [ ] Offline eval harness: Mock Device Kit `setCameraFeed`/`setCapturedImage` + VizWiz/TextVQA subset, replay mode for CI
- [ ] TalkBack pass + WCAG 2.2 AA check of the companion UI
- [ ] Mention the accessibility focus in README once the first demo runs
